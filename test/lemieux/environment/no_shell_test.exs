defmodule Lemieux.Environment.NoShellTest do
  # Not async: the second test points the whole VM's PATH at an empty
  # directory, which every concurrently running command would see.
  use ExUnit.Case, async: false

  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Local.ExCmd

  test "Windows is told to install Git Bash or use WSL, not shown a missing /bin/sh" do
    message = ExCmd.no_shell_message({:win32, :nt}, "C:\\Windows")

    assert message =~ "no bash was found on PATH"
    assert message =~ "Git Bash"
    assert message =~ "WSL"
    refute message =~ "/bin/sh"
  end

  test "Unix names the PATH it searched" do
    assert ExCmd.no_shell_message({:unix, :darwin}, "/nowhere") ==
             "neither bash nor sh was found on PATH (/nowhere)"
  end

  @tag :tmp_dir
  test "a command with no shell on PATH fails with the diagnostic, not a spawn error",
       %{tmp_dir: empty} do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)
    System.put_env("PATH", empty)

    assert {:error, {:command_start_failed, message}} =
             Local.run(nil, "echo hi", cwd: empty, timeout_ms: 5_000)

    assert message == ExCmd.no_shell_message(:os.type(), empty)
  end
end
