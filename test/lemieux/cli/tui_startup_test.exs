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

    send(assert_initializing(app, id), :continue)
    task = assert_initializing(app, id)
    ref = :sys.get_state(app).user_state.resume.initial_task.ref
    handler = {__MODULE__, ref}

    # Observe the app handling this startup task's reply. The floor runner
    # reached :ready without notifying a :sys state observer about that transition.
    :ok =
      :telemetry.attach(
        handler,
        [:ex_ratatui, :runtime, :update, :stop],
        &__MODULE__.startup_reply/4,
        {owner, app, ref}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    send(task, :continue)
    assert_receive {:startup_reply, ^ref}

    # This call runs after the app has applied the update.
    ready = :sys.get_state(app).user_state
    assert ready.resume.startup_status == :ready
    assert ready.overlay == nil
    assert Enum.find(ready.terminal.boot.steps, &(&1.id == id)).status == "ok"
    assert Enum.find(ready.terminal.boot.steps, &(&1.id == :screen)).status == "ok"
    GenServer.stop(app)
    Runtime.stop_sessions(runtime)
  end

  defp assert_initializing(app, id) do
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
    task
  end

  @doc false
  @spec startup_reply(
          event :: [atom()],
          measurements :: map(),
          metadata :: map(),
          config :: tuple()
        ) ::
          :ok | {:startup_reply, reference()}
  def startup_reply(_event, _measurements, %{msg: {ref, {:ok, _, _}}}, {owner, app, ref})
      when self() == app,
      do: send(owner, {:startup_reply, ref})

  def startup_reply(_event, _measurements, _metadata, _config), do: :ok
end
