defmodule Lemieux.ClipboardPrivateFileTest do
  # A native copy hands the selection to its tool through a file. The file
  # was written first and narrowed to 0600 after, so for that moment, under
  # the usual umask, anyone on the machine could read what was copied from
  # the shared temporary directory. Now the file is only ever made inside a
  # directory of the copy's own, narrowed to 0700 before anything is in it.
  use ExUnit.Case, async: true

  alias Lemieux.Clipboard
  alias Lemieux.Environment.Local

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    temporary = Path.join(dir, "temporary")
    File.mkdir_p!(temporary)

    # A clipboard tool that, while it reads the selection, notes what the
    # temporary directory holds and how each entry may be read.
    tool = Path.join(dir, "fake-copy")

    File.write!(tool, """
    #!/bin/sh
    cat > "$2.copied"
    for entry in "$1"/*; do ls -ld "$entry"; ls -A "$entry"; done > "$2"
    """)

    File.chmod!(tool, 0o755)
    %{temporary: temporary, tool: tool, seen: Path.join(dir, "seen")}
  end

  test "the selection is written only inside a directory its owner alone can enter", ctx do
    assert Clipboard.native_copy(
             {ctx.tool, [ctx.temporary, ctx.seen]},
             "a token\n",
             &Local.find_bash/0,
             ctx.temporary
           ) == :ok

    assert File.read!(ctx.seen <> ".copied") == "a token\n"

    seen = File.read!(ctx.seen)
    assert seen =~ ~r/\Adrwx------/
    assert seen =~ "\nselection\n"

    # And nothing is left behind.
    assert File.ls!(ctx.temporary) == []
  end
end
