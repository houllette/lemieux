defmodule Lemieux.TUI.EffectsRunTest do
  # Work the screen sends off through `:run` — `/retry`, `/compact`, `/undo`
  # and the rest — is a session call made from a task. That task was a bare
  # `Task.start`: a session killed under the call crashed it, logging
  # "[error] Task … terminating" for an answer nobody was waiting for, and a
  # call that never returned kept its process after the screen and the
  # runtime were gone.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI.Effects

  # Exercise :run's ownership/exit contract without :retry's five-second call
  # deadline. The floor runner observed :noproc rather than :normal: a
  # monitor installed after work has ended cannot report its exit reason.
  # A held fixture must outlive the suite's five-second assertion window.
  defmodule HeldCall do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    alias Lemieux.Conversation.Dispatch

    @impl true
    def spec, do: %{name: "held-call", description: "held fixture call", action: :held_call}

    @impl true
    def parse(_arguments, _conversation), do: []

    @impl true
    def perform(acc, host, :held_call) do
      Dispatch.run(acc, host, fn ->
        {:held_call_result, GenServer.call(host.session, :held_call, :timer.minutes(1))}
      end)
    end
  end

  # A command whose work tells `observer` it is running, then exits when told
  # to — with the session still alive.
  defmodule GivesUp do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    alias Lemieux.Conversation.Dispatch

    @impl true
    def spec,
      do: %{name: "gives-up", description: "exits from its work", action: {:gives_up, :observer}}

    @impl true
    def parse(_arguments, _conversation), do: []

    @impl true
    def perform(acc, host, {:gives_up, observer}) do
      Dispatch.run(acc, host, fn ->
        send(observer, {:working, self()})

        receive do
          :give_up -> exit(:gave_up)
        end
      end)
    end
  end

  # A session that takes the held call and says which process made it. The
  # test decides whether it answers or dies while the call is held.
  defp silent_session do
    test = self()

    session =
      spawn(fn ->
        receive do
          {:"$gen_call", {caller, _tag} = from, :held_call} ->
            send(test, {:called, caller})

            receive do
              {:answer, value} -> GenServer.reply(from, value)
            end
        end

        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(session, :kill) end)
    session
  end

  defp supervised(state) do
    supervisor = start_supervised!(Task.Supervisor)
    {put_in(state.resume.task_supervisor, supervisor), supervisor}
  end

  defp held(state) do
    state = put_in(state.conversation.commands, [HeldCall])
    assert {:noreply, _state} = Effects.run(state, [:held_call])
    assert_receive {:called, task}
    task
  end

  defp watching(task) do
    monitor = Process.monitor(task)

    # A monitor is a signal to the target. Its reply/death comes from a
    # different process, so calling monitor before releasing the session
    # alone does not order the two signals at the task. Confirm the monitor
    # reached the held task before the session is allowed to end its work.
    assert {:monitored_by, observers} = Process.info(task, :monitored_by)
    assert self() in observers
    monitor
  end

  test "work runs under the screen's task supervisor, and ends quietly with its session" do
    session = silent_session()
    {state, supervisor} = supervised(tui(session: session))

    {task, log} =
      with_log(fn ->
        task = held(state)
        monitor = watching(task)
        assert task in Task.Supervisor.children(supervisor)
        Process.exit(session, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
        task
      end)

    refute log =~ inspect(task)
    refute_received {:held_call_result, _result}
  end

  test "without a supervisor the work is linked to the screen" do
    session = silent_session()

    {task, log} =
      with_log(fn ->
        task = held(tui(session: session))
        monitor = watching(task)
        assert {:links, links} = Process.info(self(), :links)
        assert task in links
        Process.exit(session, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
        task
      end)

    refute log =~ inspect(task)
    refute_received {:held_call_result, _result}
  end

  test "completed work delivers its answer and leaves the supervisor" do
    session = silent_session()
    {state, supervisor} = supervised(tui(session: session))
    task = held(state)
    monitor = watching(task)

    send(session, {:answer, :completed})

    assert_receive {:held_call_result, :completed}
    assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
    refute task in Task.Supervisor.children(supervisor)
    refute_receive {:held_call_result, _duplicate}, 20
  end

  test "any other exit, with the session alive, is still the task's to crash with" do
    session = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(session, :kill) end)
    {state, _supervisor} = supervised(tui(session: session, commands: [GivesUp]))

    log =
      capture_log(fn ->
        assert {:noreply, _state} = Effects.run(state, [{:gives_up, self()}])
        assert_receive {:working, task}

        monitor = Process.monitor(task)
        send(task, :give_up)
        assert_receive {:DOWN, ^monitor, :process, ^task, :gave_up}
      end)

    assert log =~ "gave_up"
  end
end
