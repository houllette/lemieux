defmodule Lemieux.CLI.Learning.StockRefinementTest do
  use ExUnit.Case, async: false
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Learning.Loop
  alias Lemieux.CLI.Learning.QualificationHost
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Contract
  alias Lemieux.JobBudget
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir
  @moduletag skip: System.get_env("LEMIEUX_TEST_CONTAINERS") != "1"
  @moduletag timeout: :timer.minutes(3)
  @guidance "\nInspect the implementation, repair the cause, and run the unchanged verification command."

  setup %{tmp_dir: dir} do
    cwd = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.write!(Path.join(cwd, "value"), "broken")
    File.write!(Path.join(cwd, "Makefile"), "test:\n\t@test \"$$(cat value)\" = fixed\n")

    {:ok, options} =
      Options.parse([
        "--model",
        "test:model",
        "--no-delegate",
        "--no-web-fetch",
        "--no-project-mcp",
        "--no-sandbox",
        "--permission-mode",
        "off"
      ])

    options = %{options | config: %Config{settings: %{}}}
    options = put_in(options.host.state_dir, Path.join(dir, "personal"))
    supervisor = :"stock_refinement_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    host = [
      cwd: cwd,
      supervisor: supervisor,
      store: JSONL.new(Path.join(dir, "sessions")),
      params: [max_tokens: 8192],
      max_requests: 16,
      max_turns: 16
    ]

    %{options: options, host: host, cwd: cwd}
  end

  test "ordinary CLI and interactive assembly probe, apply, retain and undo one bounded refinement",
       ctx do
    for interactive <- [false, true] do
      home = ctx.options.host.state_dir <> "-#{interactive}"
      options = ctx.options
      options = put_in(options.host.state_dir, home)
      File.write!(Path.join(ctx.cwd, "value"), "broken")

      training =
        Scripted.new([
          Scripted.tool_call("fail", "bash", %{"command" => "make test"}, usage: usage()),
          Scripted.complete("failure observed", usage: usage())
        ])

      {:ok, first} =
        Runtime.start_session(
          options,
          Keyword.merge(ctx.host, provider: training, interactive?: interactive)
        )

      assert {:ok, _} = Session.await(first, "Investigate the failing test", timeout: :infinity)
      GenServer.stop(first)
      assert File.read!(Path.join(ctx.cwd, "value")) == "broken"

      provider = Scripted.new(List.duplicate(&respond/1, 100))

      {:ok, second} =
        Runtime.start_session(
          options,
          Keyword.merge(ctx.host,
            provider: provider,
            interactive?: interactive,
            job_limits: [max_requests: 192],
            deadline_ms: 120_000
          )
        )

      assert {:ok, _} =
               Session.await(second, "Investigate the recurring failing test", timeout: :infinity)

      requests = Scripted.requests(provider)
      assert Enum.any?(requests, &String.contains?(&1.system, "harness proposer"))
      assert Enum.any?(requests, &String.contains?(&1.system, @guidance))
      assert File.read!(Path.join(ctx.cwd, "value")) == "fixed"
      assert {:ok, info} = Loop.inspect(home, ctx.cwd)
      assert info["last"]["action"] == "task_local_refinement"
      assert info["learning_requests"] > 0
      assert info["learning_requests"] <= 48
      assert info["last"]["phase"] == "prepared"
      assert info["last"]["refinement"]["decision"] == "proposed"
      assert info["last"]["qualification"] == "task_local_command_only"
      assert Session.budget(second).job.requests <= 192
      assert Session.snapshot(second).usage.total["input_tokens"] == length(requests) * 2

      assert {:ok, %{value: %{"complete" => true, "slots" => slots}}} =
               Session.document(second, "lmx.learning.refinement")

      assert slots >= info["learning_requests"]
      GenServer.stop(second)

      assert :ok = Loop.undo(home, ctx.cwd)
      assert {:ok, undone} = Loop.inspect(home, ctx.cwd)
      assert undone["blocked"] != []
      provider = Scripted.new([Scripted.complete("ordinary", usage: usage())])

      {:ok, third} =
        Runtime.start_session(
          options,
          Keyword.merge(ctx.host, provider: provider, interactive?: interactive)
        )

      assert {:ok, _} =
               Session.await(third, "Investigate the recurring failing test", timeout: :infinity)

      assert [request] = Scripted.requests(provider)
      refute request.system =~ @guidance
      GenServer.stop(third)
      assert Lemieux.sessions(ctx.host[:supervisor]) == []
    end
  end

  @tag capture_log: true
  test "cancelling the stop-hook experiment kills its provider and leaves a recovery intent",
       ctx do
    owner = self()

    provider =
      Scripted.new([
        Scripted.tool_call("fail", "bash", %{"command" => "make test"}, usage: usage()),
        Scripted.complete("observed", usage: usage()),
        fn _request ->
          send(owner, {:probe_running, self()})
          Process.sleep(60_000)
          Scripted.complete("late", usage: usage())
        end
      ])

    {:ok, session} =
      Runtime.start_session(
        ctx.options,
        Keyword.merge(ctx.host, provider: provider, job_limits: [max_requests: 192])
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "Investigate the failing test")
    assert_receive {:probe_running, request}
    monitor = Process.monitor(request)
    assert :ok = Session.cancel(session)
    assert_receive {:DOWN, ^monitor, :process, ^request, _reason}
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}

    assert {:ok, %{value: %{"complete" => false}}} =
             Session.document(session, "lmx.learning.refinement")

    GenServer.stop(session)
    assert length(Scripted.requests(provider)) == 3
    assert File.read!(Path.join(ctx.cwd, "value")) == "broken"
  end

  test "reopening task-local work cannot reset a job's consumed learning allocation", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("fail", "bash", %{"command" => "make test"}, usage: usage()),
        Scripted.complete("observed", usage: usage())
      ])

    {:ok, session} =
      Runtime.start_session(
        ctx.options,
        Keyword.merge(ctx.host, provider: provider, job_limits: [max_requests: 192])
      )

    ledger = Session.delegation_context(session).job_budget
    assert {:ok, lease} = JobBudget.reserve(ledger, nil, 32)
    assert :ok = JobBudget.settle(ledger, lease, nil)

    assert {:ok, _} =
             Session.put_document(session, "lmx.learning.refinement", 0, %{
               "complete" => true,
               "slots" => 32,
               "prompts" => ["prior-task"]
             })

    assert {:ok, _} = Session.await(session, "Investigate the failing test", timeout: :infinity)
    assert length(Scripted.requests(provider)) == 2
    assert Session.budget(session).job.requests == 34
    assert {:ok, info} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    assert info["last"]["reason"] == "insufficient_frozen_experiment_allowance"
    GenServer.stop(session)
  end

  test "absolute path permission rules cannot lose their meaning in a copied workspace", ctx do
    options = ctx.options

    options =
      put_in(options.config.settings["permissions"], %{
        "deny" => ["Read(" <> Path.join(ctx.cwd, "value") <> ")"]
      })

    options = put_in(options.host.permission_mode, "full_auto")

    provider =
      Scripted.new([
        Scripted.tool_call("fail", "bash", %{"command" => "make test"}, usage: usage()),
        Scripted.complete("observed", usage: usage())
      ])

    {:ok, session} =
      Runtime.start_session(
        options,
        Keyword.merge(ctx.host, provider: provider, job_limits: [max_requests: 192])
      )

    assert {:ok, _} = Session.await(session, "Investigate the failing test", timeout: :infinity)
    assert length(Scripted.requests(provider)) == 2
    assert File.read!(Path.join(ctx.cwd, "value")) == "broken"
    GenServer.stop(session)
  end

  defp respond(request) do
    turns = Enum.count(request.entries, &(&1.type == :assistant))

    cond do
      String.contains?(request.system, "harness proposer") ->
        propose(request, turns)

      String.contains?(request.system, @guidance) and turns == 0 ->
        Scripted.tool_call("repair", "bash", %{"command" => "printf fixed > value && make test"},
          usage: usage()
        )

      String.contains?(request.system, @guidance) and turns == 2 ->
        Scripted.tool_call("repair", "bash", %{"command" => "printf fixed > value && make test"},
          usage: usage()
        )

      turns == 0 ->
        Scripted.tool_call("verify", "bash", %{"command" => "make test"}, usage: usage())

      true ->
        Scripted.complete("done", usage: usage())
    end
  end

  defp propose(_request, 0),
    do:
      Scripted.tool_call("evidence", "read", %{"path" => "evidence/operator.json"},
        usage: usage()
      )

  defp propose(request, 1) do
    assert Enum.any?(request.entries, fn entry ->
             entry.type == :tool_result and
               String.contains?(entry.payload["output"] || "", "Prior scoped experience")
           end)

    profile =
      QualificationHost.baseline("test:model", "default", 2)
      |> update_in(["options", "system"], &(&1 <> @guidance))

    Scripted.tool_call(
      "profile",
      "write",
      %{"path" => "proposal/profile.json", "content" => Contract.encode!(profile)},
      usage: usage()
    )
  end

  defp propose(request, 2) do
    text = Enum.map_join(request.entries, "\n", &JSON.encode!(&1.payload))
    [id] = Regex.run(~r/ordinary-[a-f0-9]{24}/, text)

    manifest = %{
      "rationale" => "Prior captured verification motivates this bounded hypothesis.",
      "hypothesis" => "Explicit verification guidance improves the replay.",
      "targeted_cluster" => nil,
      "mechanism" => "missing_verification",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => [id],
      "predicted_at_risk" => []
    }

    Scripted.tool_call(
      "manifest",
      "write",
      %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
      usage: usage()
    )
  end

  defp propose(_request, _turn), do: Scripted.complete("proposed", usage: usage())
  defp usage, do: %{"input_tokens" => 2, "output_tokens" => 2}
end
