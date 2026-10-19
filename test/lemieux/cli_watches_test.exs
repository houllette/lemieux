defmodule Lemieux.CLIWatchesTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Watches.Command
  alias Lemieux.CLI.Watches.GitHub
  alias Lemieux.Extensions.Watches
  alias Lemieux.Extensions.Watches.Tool
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  @target %{"repository" => "owner/repo", "run_id" => "123", "sha" => String.duplicate("a", 40)}

  defmodule Source do
    @behaviour Lemieux.Extensions.Watches.Source
    @impl true
    def validate(_state, target), do: {:ok, target}
    @impl true
    def observe(%{owner: owner}, target) do
      send(owner, {:observing, self(), target})

      receive do
        {:answer, result} -> result
      after
        60_000 -> {:error, :unavailable, "fixture held too long"}
      end
    end
  end

  defmodule Environment do
    def run(%{owner: owner, events: events}, command, opts) do
      send(owner, {:status_command, command, opts})
      {:ok, events}
    end
  end

  test "a configured deployment reader receives inert identity through the selected environment" do
    target = %{
      "run_id" => "deployment-42; touch unsafe",
      "url" => "https://example.test/deployments/42"
    }

    assert {:ok, ^target} = Command.validate(nil, target)
    response = %{"state" => "done", "outcome" => "success", "logs" => "ready"}

    state = %{
      command: "/host/status-reader",
      cwd: "/workspace",
      environment:
        {Environment,
         %{owner: self(), events: [{:data, JSON.encode!(response)}, {:exit_status, 0}]}}
    }

    assert {:done, ^response} = Command.observe(state, target)
    assert_receive {:status_command, "/host/status-reader", opts}
    assert opts[:env] == [{"LMX_WATCH_TARGET", JSON.encode!(target)}]
    assert opts[:cwd] == "/workspace"
    assert opts[:max_output_bytes] == 32_768
    assert {:error, :target_needs_run_id} = Command.validate(nil, %{})

    for {json, expected} <- [
          {%{"state" => "pending", "summary" => "running"}, {:pending, "running"}},
          {%{"state" => "retry", "retry_after_ms" => 1000},
           {:retry, 1000, "Status rate limited"}},
          {%{"state" => "error", "category" => "authentication"},
           {:error, :authentication, "Authentication failed"}},
          {%{"state" => "error", "category" => "failed"}, {:error, :failed, "Status failed"}},
          {%{"state" => "error", "category" => "unavailable"},
           {:error, :unavailable, "Status unavailable"}}
        ] do
      env =
        {Environment, %{owner: self(), events: [{:data, JSON.encode!(json)}, {:exit_status, 0}]}}

      assert Command.observe(%{state | environment: env}, target) == expected
    end

    for terminal <- [{:exit_status, 1}, {:timeout, 10_000}, {:output_limit, 32_768}] do
      env = {Environment, %{owner: self(), events: [terminal]}}

      assert {:error, :unavailable, _message} =
               Command.observe(%{state | environment: env}, target)
    end
  end

  test "GitHub requires immutable full identity and reports failures with bounded logs" do
    assert {:error, :invalid_github_target} =
             GitHub.validate(nil, %{@target | "run_id" => "123'; bad"})

    assert {:error, :invalid_github_target} = GitHub.validate(nil, %{@target | "sha" => "abc"})
    assert {:ok, @target} = GitHub.validate(nil, @target)

    run = %{
      "id" => 123,
      "head_sha" => @target["sha"],
      "repository" => %{"full_name" => "owner/repo"},
      "status" => "completed",
      "conclusion" => "failure",
      "html_url" => "https://github.com/owner/repo/actions/runs/123"
    }

    runner = fn command, _limit ->
      if command =~ "--log-failed",
        do: {:ok, "test failed"},
        else: {:ok, "HTTP/2.0 200 OK\r\n\r\n" <> JSON.encode!(run)}
    end

    assert {:done,
            %{
              "sha" => sha,
              "outcome" => "failure",
              "logs" => "test failed",
              "repository" => "owner/repo"
            }} =
             GitHub.observe(%{run: runner}, @target)

    assert sha == @target["sha"]

    stale = fn _command, _limit ->
      {:ok,
       "HTTP/2.0 200 OK\r\n\r\n" <> JSON.encode!(%{run | "head_sha" => String.duplicate("b", 40)})}
    end

    assert {:error, :failed, message} = GitHub.observe(%{run: stale}, @target)
    assert message =~ "identity"
  end

  test "GitHub respects rate limits and distinguishes denied, missing and transient status" do
    for {response, expected} <- [
          {"HTTP/2.0 429 Too Many Requests\r\nRetry-After: 17\r\n\r\n{}", {:retry, 17_000}},
          {"HTTP/2.0 401 Unauthorized\r\n\r\n{}", {:error, :authentication}},
          {"HTTP/2.0 403 Forbidden\r\n\r\n{}", {:error, :authentication}},
          {"HTTP/2.0 404 Not Found\r\n\r\n{}", {:error, :unavailable}},
          {"HTTP/2.0 503 Unavailable\r\n\r\n{}", {:retry, 30_000}}
        ] do
      result = GitHub.observe(%{run: fn _command, _limit -> {:ok, response} end}, @target)
      assert {elem(result, 0), elem(result, 1)} == expected
    end
  end

  test "a normal CLI session automatically mounts and reconnects watches without a jobs daemon",
       %{tmp_dir: dir} do
    runtime = :"cli_watch_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    {:ok, options} = Options.parse(["--config", "none", "--no-delegate", "--bare"])
    provider = Scripted.new([])

    opts = [
      supervisor: runtime,
      provider: provider,
      store: JSONL.new(Path.join(dir, "sessions")),
      state_dir: dir,
      cwd: dir,
      tools: [],
      watch_sources: %{"fake" => {Source, %{owner: self()}}}
    ]

    {:ok, prepared} = Runtime.prepare(options, opts)
    assert Enum.any?(prepared.harness.tools, &match?(%Tool{}, &1))
    assert Registry.lookup(Lemieux.Supervisor.registry(runtime), {:watches, "none"}) == []
    {:ok, session} = Runtime.start(prepared)
    id = Session.id(session)
    assert {:ok, manager} = Lemieux.CLI.Watches.resolve(%{supervisor: runtime, session_id: id})
    {:ok, watch} = Watches.register(manager, "fake", %{"run_id" => "already-started"})
    assert_receive {:observing, observer, %{"run_id" => "already-started"}}
    DynamicSupervisor.terminate_child(Lemieux.Supervisor.session_supervisor(runtime), session)
    send(observer, {:answer, {:done, %{"outcome" => "success"}}})
    {:ok, resumed} = Runtime.start(%{prepared | resume: id})
    assert Session.id(resumed) == id

    assert {:ok, same_manager} =
             Lemieux.CLI.Watches.resolve(%{supervisor: runtime, session_id: id})

    assert same_manager == manager
    assert {:ok, %{"id" => watch_id}} = Watches.get(manager, watch["id"])
    assert watch_id == watch["id"]
    assert Scripted.requests(provider) == []
  end

  test "model registration cannot grant itself continuation" do
    tool = Tool.new(manager: self(), sources: ["fake"])
    assert {:error, reason} = Tool.run(tool, %{"action" => "register", "follow_up" => true}, %{})
    assert reason =~ "notifications only"
  end

  test "watch inspection formats readable status instead of exposing journal fields" do
    watch = %{
      "id" => "watch-42",
      "source" => "background",
      "status" => "watching",
      "target" => %{"task_id" => "task-42"},
      "deadline_at" => "2026-10-19T20:00:00Z",
      "follow_up" => true,
      "delivery" => "pending",
      "attempts" => 3
    }

    text = Tool.format(watch)
    assert text =~ "watch-42"
    assert text =~ "watching"
    assert text =~ "task-42"
    assert text =~ "2026-10-19T20:00:00Z"
    assert text =~ "automatic follow-up"
    refute text =~ "attempts"
    assert Tool.format([]) == "No watches."
    assert Tool.format([watch]) =~ text

    assert Tool.format(%{watch | "target" => %{"filters" => ["build", "test"]}}) =~
             ~s(filters: ["build","test"])
  end

  test "fresh CLI preparation recovers the original watch under current authority", %{
    tmp_dir: dir
  } do
    runtime = :"cli_reopen_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    config = Path.join(dir, "config.json")

    settings = %{
      "permissions" => %{"mode" => "off"},
      "verify" => false,
      "watches" => %{"follow_up" => true}
    }

    File.write!(config, JSON.encode!(settings))
    {:ok, options} = Options.parse(["--config", config, "--no-delegate", "--bare"])
    provider = Scripted.new([])

    opts = [
      supervisor: runtime,
      provider: provider,
      store: JSONL.new(Path.join(dir, "sessions")),
      state_dir: dir,
      cwd: dir,
      watch_sources: %{"fake" => {Source, %{owner: self()}}}
    ]

    {:ok, session} = Runtime.start_session(options, opts)
    id = Session.id(session)
    {:ok, manager} = Lemieux.CLI.Watches.resolve(%{supervisor: runtime, session_id: id})
    {:ok, watch} = Watches.register(manager, "fake", %{"run_id" => "original"}, follow_up: true)
    assert_receive {:observing, first, %{"run_id" => "original"}}
    ref = Process.monitor(first)
    DynamicSupervisor.terminate_child(Lemieux.Supervisor.background_supervisor(runtime), manager)
    assert_receive {:DOWN, ^ref, :process, ^first, _reason}
    DynamicSupervisor.terminate_child(Lemieux.Supervisor.session_supervisor(runtime), session)
    File.write!(config, JSON.encode!(%{settings | "watches" => %{"follow_up" => false}}))
    {:ok, fresh} = Options.parse(["--config", config, "--no-delegate", "--bare", "--resume", id])
    assert {:ok, restored} = Runtime.start_session(fresh, opts)
    assert Session.id(restored) == id
    assert_receive {:observing, observer, %{"run_id" => "original"}}
    send(observer, {:answer, {:done, %{"outcome" => "success"}}})

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{type: :extension_state, payload: %{"namespace" => "lemieux.notification"}}}}

    {:ok, recovered} = Lemieux.CLI.Watches.resolve(%{supervisor: runtime, session_id: id})

    assert {:ok, %{"delivery" => "delivered", "continuation" => "notification_only"}} =
             Watches.get(recovered, watch["id"])

    assert Scripted.requests(provider) == []
  end

  test "the ordinary CLI plan yields to a watch and infers only after its authorized completion",
       %{tmp_dir: dir} do
    runtime = :"cli_wait_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    config = Path.join(dir, "config.json")

    File.write!(
      config,
      JSON.encode!(%{
        "permissions" => %{"mode" => "off"},
        "verify" => false,
        "watches" => %{"follow_up" => true}
      })
    )

    {:ok, options} = Options.parse(["--config", config, "--no-delegate", "--bare"])

    provider =
      Scripted.new([
        Scripted.tool_call("plan", "todo", %{
          "action" => "set",
          "tasks" => [%{"title" => "Wait for CI", "status" => "in_progress"}]
        }),
        Scripted.tool_call("monitor", "watch", %{
          "action" => "register",
          "source" => "fake",
          "target" => %{"run_id" => "42"},
          "follow_up" => true
        }),
        Scripted.complete("Waiting for CI."),
        Scripted.complete("Inspected the result.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        store: JSONL.new(Path.join(dir, "sessions")),
        state_dir: dir,
        cwd: dir,
        watch_sources: %{"fake" => {Source, %{owner: self()}}}
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Watch the existing run and inspect its completion.")
    assert_receive {:observing, observer, _target}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 3
    send(observer, {:answer, {:done, %{"outcome" => "failure"}}})
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 4
  end
end
