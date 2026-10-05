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

  # A session that takes `/retry`'s call, says which process made it, and
  # never answers: the test decides when it dies.
  defp silent_session do
    test = self()

    spawn(fn ->
      receive do
        {:"$gen_call", {caller, _tag}, :retry} -> send(test, {:called, caller})
      end

      Process.sleep(:infinity)
    end)
  end

  defp supervised(state) do
    supervisor = start_supervised!(Task.Supervisor)
    {put_in(state.resume.task_supervisor, supervisor), supervisor}
  end

  defp retry(state) do
    assert {:noreply, _state} = Effects.run(state, [:retry])
    assert_receive {:called, task}
    task
  end

  test "work runs under the screen's task supervisor, and ends quietly with its session" do
    session = silent_session()
    {state, supervisor} = supervised(tui(session: session))

    {task, log} =
      with_log(fn ->
        task = retry(state)
        assert task in Task.Supervisor.children(supervisor)

        monitor = Process.monitor(task)
        Process.exit(session, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
        task
      end)

    refute log =~ inspect(task)
    refute_received {:retry_result, _result}
  end

  test "without a supervisor the work is linked to the screen" do
    session = silent_session()

    {task, log} =
      with_log(fn ->
        task = retry(tui(session: session))
        assert {:links, links} = Process.info(self(), :links)
        assert task in links

        monitor = Process.monitor(task)
        Process.exit(session, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^task, :normal}
        task
      end)

    refute log =~ inspect(task)
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
