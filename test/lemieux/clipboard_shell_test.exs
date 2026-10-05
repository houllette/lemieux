defmodule Lemieux.ClipboardShellTest do
  # A native copy runs its tool through a shell. It used to be a bare "sh",
  # and `System.cmd/3` raises when that is not on PATH — in the terminal UI's
  # own process, which a copy runs in. Now the shell is found the way
  # commands find theirs, and no shell is a copy that did not happen, which
  # `Lemieux.Clipboard.copy/3` turns into its OSC 52 fallback.
  use ExUnit.Case, async: true

  alias Lemieux.Clipboard
  alias Lemieux.Environment.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    tee = System.find_executable("tee") || flunk("tee is not on PATH")
    out = Path.join(dir, "clipboard")
    %{tool: {tee, [out]}, out: out}
  end

  test "with no shell to run it, the copy is refused rather than raised", ctx do
    assert Clipboard.native_copy(ctx.tool, "text", fn -> :error end) == {:error, :no_shell}
    refute File.exists?(ctx.out)
  end

  test "a shell that will not start is refused rather than raised", ctx do
    missing = Path.join(Path.dirname(ctx.out), "no-such-shell")

    assert {:error, {:shell, :enoent}} =
             Clipboard.native_copy(ctx.tool, "text", fn -> {:ok, missing} end)
  end

  test "the shell commands use runs the tool with the text on its input", ctx do
    assert Clipboard.native_copy(ctx.tool, "copied text\n", &Local.find_bash/0) == :ok
    assert File.read!(ctx.out) == "copied text\n"
  end
end
