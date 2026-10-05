defmodule Lemieux.TUI.SignalsTest do
  # Signal traps are the VM's, not the test's: set and released here one at
  # a time, never beside another test that might be relying on them. No test
  # here delivers a SIGTERM, real or notified: the VM's own handler would
  # stop the suite.
  use ExUnit.Case, async: false

  alias Lemieux.TUI.Signals

  defp handlers, do: :gen_event.which_handlers(:erl_signal_server)

  # A release happens in a process of its own, so it is waited for here.
  defp wait_for_handlers(expected, attempts \\ 100) do
    cond do
      handlers() == expected ->
        :ok

      attempts == 0 ->
        flunk("the signal handlers are still #{inspect(handlers())}")

      true ->
        Process.sleep(10)
        wait_for_handlers(expected, attempts - 1)
    end
  end

  test "a screen traps SIGTERM alone, and releases exactly what it trapped" do
    before = handlers()
    traps = Signals.trap(self())

    assert [sigterm: id] = traps
    assert [{_module, {:sigterm, ^id}}] = handlers() -- before

    assert Signals.release(traps) == :ok
    wait_for_handlers(before)
  end

  # A closed terminal hangs up the VM, and a trapped SIGHUP is one the VM no
  # longer ends on: with the screen's input poll spinning on the dead
  # terminal, nothing was left to stop it.
  test "SIGHUP is never trapped, so a closed terminal still ends the VM" do
    traps = Signals.trap(self())

    try do
      refute Keyword.has_key?(traps, :sighup)
      refute Enum.any?(handlers(), &match?({_module, {:sighup, _id}}, &1))
    after
      Signals.release(traps)
    end
  end

  test "the trap asks the screen to leave and waits for it" do
    screen =
      spawn(fn ->
        receive do
          {:terminal_signal, signal} -> exit({:left_on, signal})
        end
      end)

    ref = Process.monitor(screen)

    # What the signal server runs on a SIGTERM, run here instead.
    assert Signals.handler(screen, :sigterm).() == :ok
    assert_receive {:DOWN, ^ref, :process, ^screen, {:left_on, :sigterm}}
  end

  # The signal server runs one handler at a time, and a host's own SIGTERM
  # trap may be the one stopping the screen. A release that waited for the
  # server from the screen's `terminate/2` waited for the handler that was
  # waiting for the screen.
  test "releasing never waits for a signal server busy with another handler" do
    before = handlers()
    test = self()
    server = Process.whereis(:erl_signal_server)
    traps = Signals.trap(self())

    {:ok, busy} =
      System.trap_signal(:sigusr2, fn ->
        send(test, :handling)

        receive do
          :go_on -> :ok
        after
          2_000 -> :ok
        end
      end)

    # The VM's own handler does nothing with SIGUSR2.
    notifier = Task.async(fn -> :gen_event.sync_notify(:erl_signal_server, :sigusr2) end)
    assert_receive :handling

    try do
      {micros, :ok} = :timer.tc(fn -> Signals.release(traps) end)
      assert micros < 500_000
    after
      send(server, :go_on)
      Task.await(notifier)
      System.untrap_signal(:sigusr2, busy)
    end

    wait_for_handlers(before)
  end

  describe "wanted?/1" do
    test "only when the host asked, and only for a local terminal" do
      refute Signals.wanted?([])
      assert Signals.wanted?(trap_signals: true)
      assert Signals.wanted?(trap_signals: true, transport: :local)
      refute Signals.wanted?(trap_signals: false)
      refute Signals.wanted?(trap_signals: true, test_mode: {80, 24})
      refute Signals.wanted?(trap_signals: true, transport: :ssh)
    end
  end
end
