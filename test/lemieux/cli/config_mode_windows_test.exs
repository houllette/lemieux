defmodule Lemieux.CLI.ConfigModeWindowsTest do
  # Erlang reports every writable file on Windows as 0666, so a POSIX mode
  # check there refused every configuration, the default one included.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Config

  test "Windows skips the POSIX mode check" do
    assert :ok = Config.check_mode({:win32, :nt}, 0o100666, true)
    assert :ok = Config.check_mode({:win32, :nt}, 0o100666, false)
  end

  test "Unix still refuses a group- or world-readable file that holds keys" do
    assert {:error, _} = Config.check_mode({:unix, :linux}, 0o100644, true)
    assert :ok = Config.check_mode({:unix, :linux}, 0o100600, true)
    assert {:error, _} = Config.check_mode({:unix, :darwin}, 0o100666, false)
    assert :ok = Config.check_mode({:unix, :darwin}, 0o100644, false)
  end
end
