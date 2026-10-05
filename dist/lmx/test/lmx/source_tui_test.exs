defmodule Lmx.SourceTUITest do
  use ExUnit.Case, async: true

  test "the bundled source host starts in the checkout workspace" do
    parent = self()

    # A configure that does nothing: the real one replaces this VM's log
    # handlers with a file in the state directory (`Lemieux.CLI.Logs`).
    assert :ok =
             Mix.Tasks.Lmx.Tui.run_with(
               ["--help"],
               fn argv, opts ->
                 send(parent, {:run, argv, opts})
                 :ok
               end,
               fn -> :ok end
             )

    assert_received {:run, ["tui", "--help"], opts}
    assert opts[:cwd] == Path.expand("../..", File.cwd!())
    # Hints name the command a source checkout has.
    assert opts[:program] == "mix lmx"
  end
end
