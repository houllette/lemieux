defmodule Lemieux.CLITasksTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.{Options, Runtime, Tasks}
  alias Lemieux.Extensions.Watches
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"native_tasks_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    # Exercise native task control independently of sandbox availability.
    # These fixed commands need explicit approval on hosts without bubblewrap.
    {:ok, options} =
      Options.parse([
        "--config",
        "none",
        "--bare",
        "--no-delegate",
        "--permission-mode",
        "full_auto",
        "--no-sandbox"
      ])

    provider =
      Scripted.new([
        Scripted.tool_call("start", "bash", %{
          "command" => "printf READY; sleep 60",
          "background" => true
        }),
        Scripted.complete("Working in the background.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: runtime,
        provider: provider,
        cwd: dir,
        store: JSONL.new(Path.join(dir, "sessions"))
      )

    %{
      runtime: runtime,
      session: session,
      id: Session.id(session),
      provider: provider,
      dir: dir,
      options: options
    }
  end

  test "an unfinished plan yields after automatic tracking and continuation runs once by default",
       ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("plan", "todo", %{
          "action" => "set",
          "tasks" => [%{"title" => "Wait for build", "status" => "in_progress"}]
        }),
        Scripted.tool_call("build", "bash", %{
          "command" => "while [ ! -f finish ]; do sleep 0.1; done; printf DONE",
          "background" => true
        }),
        Scripted.complete("Waiting."),
        Scripted.complete("Build finished.")
      ])

    {:ok, session} =
      Runtime.start_session(ctx.options,
        supervisor: ctx.runtime,
        provider: provider,
        cwd: ctx.dir,
        state_dir: nil,
        watch_options: [poll_ms: 60_000, tick_ms: 60_000],
        store: JSONL.new(Path.join(ctx.dir, "sessions"))
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Run the build in the background.")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 3
    {:ok, %{rows: [row]}} = Tasks.snapshot(session)
    assert row.watching?
    assert row.follow_up?
    File.write!(Path.join(ctx.dir, "finish"), "done")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 4
    assert {:error, :already_delivered} = Tasks.action(session, row.id, :follow_up)
  end

  test "chatty command previews keep the latest output on a UTF-8 boundary", ctx do
    output = "OLD_HEAD" <> String.duplicate("測試", 10_000) <> "LATEST_TAIL"

    {:ok, task_id} =
      Lemieux.Background.start(
        supervisor: ctx.runtime,
        session_id: ctx.id,
        owner: ctx.session,
        command: "fixture",
        cwd: ctx.dir,
        environment: Lemieux.Environment.local(),
        runner: fn _command, _opts -> {:ok, output, 0} end
      )

    assert {:ok, %{status: :exited}} =
             Lemieux.Background.await(ctx.runtime, ctx.id, task_id, 5000)

    assert {:ok, %{detail: detail, rows: [row]}} = Tasks.snapshot(ctx.session, "task:" <> task_id)
    assert row.status == "success"
    assert detail.logs =~ "LATEST_TAIL"
    refute detail.logs =~ "OLD_HEAD"
    assert String.valid?(detail.logs)
    assert byte_size(detail.logs) < 32_100
    assert Scripted.requests(ctx.provider) == []
  end

  test "hermetic CLI starts are tracked automatically and human controls spend no requests",
       ctx do
    :ok = Session.prompt(ctx.session, "Start the fixture in the background.")
    assert_receive {:lemieux, _, {:finished, :stop}}
    assert {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.session)
    assert row.running? and row.watching?
    assert row.follow_up?
    assert row.label == "printf READY; sleep 60"
    assert length(Scripted.requests(ctx.provider)) == 2
    assert :ok = Tasks.action(ctx.session, row.id, :stop)
    assert {:ok, %{rows: [stopped]}} = Tasks.snapshot(ctx.session, row.id)
    assert stopped.running?
    refute stopped.watching?
    assert :ok = Tasks.action(ctx.session, row.id, :watch)
    assert :ok = Tasks.action(ctx.session, row.id, :follow_up)
    assert {:ok, %{rows: [following]}} = Tasks.snapshot(ctx.session, row.id)
    refute following.follow_up?
    {:ok, manager} = Lemieux.CLI.Watches.resolve(%{supervisor: ctx.runtime, session_id: ctx.id})

    assert {:ok, %{"follow_up" => false}} =
             Lemieux.Extensions.Watches.register(manager, "background", row.target)

    assert :ok = Tasks.action(ctx.session, row.id, :cancel)
    assert {:ok, %{rows: [cancelled]}} = Tasks.snapshot(ctx.session, row.id)
    assert cancelled.status == "cancelled"
    refute cancelled.watching?
    assert :ok = Tasks.action(ctx.session, row.id, :clear)
    assert {:ok, %{detail: %{logs: ""}}} = Tasks.snapshot(ctx.session, row.id)
    assert length(Scripted.requests(ctx.provider)) == 2

    assert {:error, :task_unavailable} =
             Tasks.action(ctx.session, "task:another-session", :cancel)
  end

  test "an agent registration reuses the automatic observation", ctx do
    :ok = Session.prompt(ctx.session, "Start.")
    assert_receive {:lemieux, _, {:finished, :stop}}
    {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.session)
    {:ok, manager} = Lemieux.CLI.Watches.resolve(%{supervisor: ctx.runtime, session_id: ctx.id})
    assert {:ok, watch} = Watches.register(manager, "background", row.target)
    assert watch["id"] == row.watch_id
    assert length(Watches.list(manager)) == 1

    assert Enum.any?(Session.snapshot(ctx.session).entries, fn entry ->
             entry.type == :tool_result and
               get_in(entry.payload, ["structured_content", "background_watch", "id"]) ==
                 row.watch_id
           end)

    assert :ok = Tasks.action(ctx.session, row.id, :cancel)
  end

  test "disabling monitoring retains native process inspection and cancellation", ctx do
    config = Path.join(ctx.dir, "disabled-watches.json")
    File.write!(config, JSON.encode!(%{"watches" => false}))

    {:ok, options} =
      Options.parse([
        "--config",
        config,
        "--bare",
        "--no-delegate",
        "--permission-mode",
        "full_auto",
        "--no-sandbox"
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: ctx.runtime,
        provider: ctx.provider,
        cwd: ctx.dir,
        store: JSONL.new(Path.join(ctx.dir, "disabled-sessions"))
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Start.")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert {:ok, %{monitoring?: false, rows: [row]}} = Tasks.snapshot(session)
    assert row.running?
    refute row.watching?
    assert row.watch_id == nil
    assert :ok = Tasks.action(session, row.id, :cancel)
    assert :ok = Tasks.action(session, row.id, :clear)
    assert {:error, :monitoring_unavailable} = Tasks.action(session, row.id, :watch)
    assert {:error, :monitoring_unavailable} = Tasks.add(session, "github", %{}, false)
    assert length(Scripted.requests(ctx.provider)) == 2
  end

  test "volatile managers end with their session and do not appear as sessions", ctx do
    {:ok, manager} = Lemieux.CLI.Watches.resolve(%{supervisor: ctx.runtime, session_id: ctx.id})
    assert Lemieux.sessions(ctx.runtime) == [{ctx.id, ctx.session}]
    ref = Process.monitor(manager)
    GenServer.stop(ctx.session)
    assert_receive {:DOWN, ^ref, :process, ^manager, :normal}

    assert {:error, :watches_unavailable} =
             Lemieux.CLI.Watches.resolve(%{supervisor: ctx.runtime, session_id: ctx.id})

    assert Lemieux.sessions(ctx.runtime) == []
  end
end
