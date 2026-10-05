defmodule Lemieux.CLI.HelpAnywhereTest do
  # A help flag anywhere on a command line asks for that command's manual,
  # where it got "unrecognised option --help" unless it was the first or
  # second word — except where it may be a value, or follows `--`.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Help

  defp runner do
    caller = self()
    fn argv, _opts -> send(caller, {:tui, argv}) end
  end

  test "after a command's options, it prints that command's help" do
    for argv <- [["run", "--model", "x", "--help"], ["run", "fix", "the", "bug", "-h"]] do
      output = capture_io(fn -> assert CLI.run(argv) == :ok end)
      assert output =~ "Usage:", "#{inspect(argv)} refused help"
    end

    {:ok, sessions} = Help.command("log")
    assert capture_io(fn -> CLI.run(["log", "SESSION", "--help"]) end) =~ sessions
  end

  test "after the terminal UI's options, it prints the usage and opens nothing" do
    output =
      capture_io(fn ->
        assert CLI.run(["--model", "x", "--help"], tui_runner: runner()) == :ok
      end)

    assert output =~ "Usage:"
    refute_received {:tui, _argv}
  end

  test "straight after a flag that may take it as a value, it is still a value" do
    CLI.run(["tui", "--model", "x", "--system", "-h"], tui_runner: runner())
    assert_received {:tui, ["--model", "x", "--system", "-h"]}
  end

  test "after --, it is an argument" do
    CLI.run(["tui", "--", "--help"], tui_runner: runner())
    assert_received {:tui, ["--", "--help"]}
  end
end
