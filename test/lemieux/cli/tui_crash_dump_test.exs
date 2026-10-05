defmodule Lemieux.CLI.TUICrashDumpTest do
  # `crash_dump/2` sets `ERL_CRASH_DUMP` in this VM's OS environment, which
  # every test shares (and every command a test starts inherits), so these
  # run alone. The cases that set nothing are in `TUISourceTest`.
  use ExUnit.Case, async: false

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.TUI

  @moduletag :tmp_dir

  setup do
    previous = System.get_env("ERL_CRASH_DUMP")

    on_exit(fn ->
      if previous,
        do: System.put_env("ERL_CRASH_DUMP", previous),
        else: System.delete_env("ERL_CRASH_DUMP")
    end)

    System.delete_env("ERL_CRASH_DUMP")
    :ok
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  test "points the crash dump into a private crash directory", %{tmp_dir: dir} do
    path = TUI.crash_dump(dir, nil)

    assert path == Path.join([dir, "crash", "erl_crash.dump"])
    assert System.get_env("ERL_CRASH_DUMP") == path
    assert mode(Path.join(dir, "crash")) == 0o700
  end

  # A source run's first start can be the first thing to touch the state
  # directory; made with the umask, `~/.lmx` stayed 0755 for good, and the
  # transcripts in it were readable by every local user.
  test "a state directory it has to create comes out private, and stays so", %{tmp_dir: dir} do
    state = Path.join(dir, "fresh/.lmx")

    assert TUI.crash_dump(state, nil) == Path.join([state, "crash", "erl_crash.dump"])
    assert mode(state) == 0o700
    assert mode(Path.join(dir, "fresh")) == 0o700

    assert {:ok, _config} = Config.load_default(Path.join(state, "config.json"), "test:model")
    assert mode(state) == 0o700
  end
end
