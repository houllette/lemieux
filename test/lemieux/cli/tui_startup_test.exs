defmodule Lemieux.CLI.TUIStartupTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.TUI, as: Host
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  import Lemieux.TUI.TestSupport, only: [screen: 1]

  @moduletag :tmp_dir

  defmodule HeldExtension do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def init(opts) do
      send(opts[:owner], {:initializing, self()})

      receive do
        :continue -> {:ok, opts}
      end
    end

    @impl true
    def apply(harness, _opts), do: harness
  end

  test "the real host surfaces each extension initialization and opens immediately when done", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, ".git"))
    {:ok, options} = Options.parse(["--config", "none", "--model", "test:model", "--no-delegate"])
    runtime = :"lmx_startup_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    tasks = Lemieux.Supervisor.task_supervisor(runtime)
    owner = self()
    provider = Scripted.new([])

    {:ok, app} =
      TUI.start_link(
        test_mode: {80, 24},
        name: nil,
        task_supervisor: tasks,
        start_async: fn app ->
          Host.prepare_start(
            options,
            [
              provider: provider,
              cwd: dir,
              store: JSONL.new(Path.join(dir, "sessions")),
              state_dir: dir,
              supervisor: runtime,
              extensions: [{HeldExtension, owner: owner}]
            ],
            app,
            tasks
          )
        end
      )

    id = "extension:#{inspect(HeldExtension)}"

    for _pass <- 1..2 do
      assert_receive {:initializing, task}

      assert :ok =
               LemieuxTest.Sync.state(app, fn state ->
                 Enum.any?(
                   state.user_state.terminal.boot.steps,
                   &(&1.id == id and &1.status == "busy")
                 )
               end)

      state = :sys.get_state(app).user_state
      assert state.resume.startup_status == :loading
      assert screen(state) =~ "Initialize #{inspect(HeldExtension)}"
      assert Enum.any?(state.terminal.boot.steps, &(&1.id == :screen and &1.status == "busy"))
      send(task, :continue)
    end

    assert :ok = LemieuxTest.Sync.state(app, &(&1.user_state.resume.startup_status == :ready))
    ready = :sys.get_state(app).user_state
    assert ready.overlay == nil
    assert Enum.find(ready.terminal.boot.steps, &(&1.id == id)).status == "ok"
    assert Enum.find(ready.terminal.boot.steps, &(&1.id == :screen)).status == "ok"
    GenServer.stop(app)
    Runtime.stop_sessions(runtime)
  end
end
