defmodule Lemieux.TUI.TerminalStartTest do
  # Starting the screen changes the calling process's trap_exit flag for the
  # length of the call, which is this test process's own state and nobody
  # else's, so the module is safe to run beside others.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.TUI

  # A screen whose server stops in `init/1` the way ex_ratatui's does when no
  # terminal can be claimed: `lmx` started from a pipe, a CI job, or another
  # agent's shell. A real screen cannot be made to fail like this in a test —
  # on a developer's machine it would open on their terminal instead.
  defmodule NoTerminal do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(_opts), do: {:stop, {:terminal_init_failed, "Device not configured (os error 6)"}}
  end

  defmodule Opens do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(opts), do: {:ok, opts}
  end

  describe "start_screen/2" do
    test "a screen that cannot claim a terminal is a sentence, not a dead caller" do
      # Before this was handled, the server's stop reached the caller as an
      # exit signal and killed it here, before `start_link` returned — in the
      # release, the whole VM, leaving an erl_crash.dump behind.
      assert {:error, message} = TUI.start_screen(NoTerminal, [])

      assert message =~ "needs an interactive terminal"
      assert message =~ "Device not configured (os error 6)"
      assert message =~ "lmx run PROMPT"
      assert Process.alive?(self())
    end

    test "leaves exits untrapped and no exit message behind" do
      assert {:error, _message} = TUI.start_screen(NoTerminal, [])

      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
      refute_received {:EXIT, _pid, _reason}
    end

    test "restores a caller's own trap_exit flag" do
      Process.flag(:trap_exit, true)

      assert {:error, _message} = TUI.start_screen(NoTerminal, [])

      assert Process.info(self(), :trap_exit) == {:trap_exit, true}
    end

    test "a screen that opens is returned for the caller to wait on" do
      assert {:ok, pid} = TUI.start_screen(Opens, size: {80, 24})

      assert Process.alive?(pid)
      assert Process.info(self(), :trap_exit) == {:trap_exit, false}
    end
  end

  # Without a terminal, crossterm measures by running `tput` and waiting for
  # it, and in this VM that wait can block for good (see `size/2`). `lmx`
  # started from a pipe hung there on two launches in five instead of saying
  # it needs a terminal, so without one nothing is measured at all.
  describe "size/2" do
    test "the screen is measured only where there is a terminal to ask" do
      assert TUI.size(fn -> false end, fn -> flunk("measured without a terminal") end) == nil
      assert TUI.size(fn -> true end, fn -> {120, 40} end) == {120, 40}
    end

    test "a measurement that failed is no size, not a crash" do
      assert TUI.size(fn -> true end, fn -> {:error, "No child processes (os error 10)"} end) ==
               nil
    end
  end

  describe "available/1" do
    test "the missing-dependency hint names the requirement mix.exs declares" do
      requirement =
        Mix.Project.config()
        |> Keyword.fetch!(:deps)
        |> Enum.find_value(fn
          {:ex_ratatui, requirement, _opts} -> requirement
          _dependency -> nil
        end)

      assert {:error, message} = TUI.available({:error, :bad_name})
      assert message =~ ~s({:ex_ratatui, "#{requirement}"})
    end
  end
end
