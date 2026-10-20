defmodule Lemieux.NativeWatchPolicyTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.{Options, Runtime, Tasks}
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Extensions.Watches.Tool
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tools.Bash

  @moduletag :tmp_dir

  test "a background command requiring approval cannot start before that approval", %{
    tmp_dir: dir
  } do
    runtime = :"native_watch_approval_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    config = Path.join(dir, "config.json")
    File.write!(config, JSON.encode!(%{"verify" => false}))

    {:ok, options} =
      Options.parse(["--config", config, "--bare", "--no-delegate", "--no-sandbox"])

    owner = self()

    tool =
      Bash.new(
        runner: fn _, _ ->
          send(owner, {:command_started, self()})

          receive do
            :finish -> {:ok, "Finished", 0}
          after
            60_000 -> {:error, :fixture_held_too_long}
          end
        end
      )

    provider =
      Scripted.new([
        Scripted.tool_call("start", "bash", %{"command" => "held analysis", "background" => true}),
        Scripted.complete("Waiting."),
        Scripted.complete("Done."),
        Scripted.complete("Analysis fixture")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        cwd: dir,
        interactive?: true,
        store: JSONL.new(Path.join(dir, "sessions")),
        tools: [tool]
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "Run the analysis.")
    assert_receive {:lemieux, ^id, {:tool_approval, %{id: "start"}}}
    assert Lemieux.Background.list(runtime, id) == []
    refute_receive {:command_started, _}, 20
    assert :ok = Session.resolve_tool(session, "start", :allow)
    assert_receive {:command_started, worker}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{rows: [%{running?: true, watching?: true}]}} = Tasks.snapshot(session)
    send(worker, :finish)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    # The interactive host labels the session after its second exchange.
    requests = Scripted.requests(provider)
    assert length(requests) == 4
    assert List.last(requests).system =~ "Write a short session label"
  end

  defmodule Source do
    @behaviour Lemieux.Extensions.Watches.Source
    @impl true
    def validate(_state, target), do: {:ok, target}
    @impl true
    def observe(owner, _target) do
      send(owner, {:observing, self()})

      receive do
        :finish -> {:done, %{"outcome" => "success", "summary" => "Build completed"}}
      after
        60_000 -> {:error, :unavailable, "Fixture was not released"}
      end
    end
  end

  test "watch management follows session read permissions, including explicit ask and deny rules",
       %{
         tmp_dir: dir
       } do
    call = %{id: "observe", name: "watch", arguments: %{"action" => "register"}}

    context = %{
      session: self(),
      cwd: dir,
      tool_descriptor: Descriptor.to_map(Descriptor.new(Tool.new(manager: self())))
    }

    {:ok, policy} = Permissions.init(mode: :auto)
    assert Permissions.check(policy, call, context) == :allow
    {:ok, policy} = Permissions.init(mode: :auto, ask: ["watch"])
    assert {:pending, %{permission: _}} = Permissions.check(policy, call, context)
    {:ok, policy} = Permissions.init(mode: :auto, deny: ["watch"])
    assert {:deny, _} = Permissions.check(policy, call, context)
  end

  test "automatic completion preserves the existing turn allowance", %{tmp_dir: dir} do
    runtime = :"native_watch_budget_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    {:ok, options} = Options.parse(["--config", "none", "--bare", "--no-delegate"])

    provider =
      Scripted.new([
        Scripted.tool_call("observe", "watch", %{
          "action" => "register",
          "source" => "build",
          "target" => %{"run_id" => "42"}
        }),
        Scripted.complete("Waiting.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        max_turns: 2,
        state_dir: dir,
        cwd: dir,
        store: JSONL.new(Path.join(dir, "sessions")),
        watch_sources: %{"build" => {Source, self()}}
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "Watch the build.")
    assert_receive {:observing, reader}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    send(reader, :finish)
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    assert length(Scripted.requests(provider)) == 2
  end

  test "normal CLI watches continue automatically and the resumed turn cannot bypass tool boundaries",
       %{
         tmp_dir: dir
       } do
    runtime = :"native_watch_policy_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    config = Path.join(dir, "config.json")

    File.write!(
      config,
      JSON.encode!(%{
        "permissions" => %{"mode" => "auto", "deny" => ["Bash"]},
        "verify" => false
      })
    )

    {:ok, options} =
      Options.parse(["--config", config, "--bare", "--no-delegate", "--no-sandbox"])

    provider =
      Scripted.new([
        Scripted.tool_call("observe", "watch", %{
          "action" => "register",
          "source" => "build",
          "target" => %{"run_id" => "42"}
        }),
        Scripted.complete("Waiting."),
        Scripted.tool_call("outside", "bash", %{"command" => "touch forbidden"}),
        Scripted.complete("The build finished; the command remains denied.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        state_dir: dir,
        cwd: dir,
        store: JSONL.new(Path.join(dir, "sessions")),
        watch_sources: %{"build" => {Source, self()}}
      )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "Watch this build and continue when it completes.")
    assert_receive {:observing, reader}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{rows: [%{follow_up?: true}]}} = Tasks.snapshot(session)
    send(reader, :finish)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 4
    refute File.exists?(Path.join(dir, "forbidden"))

    assert Enum.any?(Session.snapshot(session).entries, fn entry ->
             entry.type == :tool_result and entry.payload["call_id"] == "outside" and
               inspect(entry.payload) =~ "denied by the permission rule"
           end)
  end
end
