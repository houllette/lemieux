defmodule Lemieux.Tools.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.ApplyPatch
  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

  @moduletag :tmp_dir

  # The local machine, without `rm`: deletes must go through the environment's
  # own `delete_file/3` when it has one, which this records.
  defmodule Deleting do
    @moduledoc false
    @behaviour Lemieux.Environment

    def read_file(_test, cwd, path), do: Local.read_file(nil, cwd, path)
    def list_dir(_test, cwd, path), do: Local.list_dir(nil, cwd, path)
    def write_file(_test, cwd, path, contents), do: Local.write_file(nil, cwd, path, contents)
    def run(_test, _command, _opts), do: {:error, :no_commands_here}

    def delete_file(test, cwd, path) do
      send(test, {:deleted, path})
      File.rm(Path.join(cwd, path))
    end
  end

  setup %{tmp_dir: tmp_dir} do
    %{ctx: %{cwd: tmp_dir, session_id: "s1", call_id: "c1", environment: Local}}
  end

  defp write(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp read(tmp_dir, name), do: File.read!(Path.join(tmp_dir, name))

  defp patch(body), do: "*** Begin Patch\n" <> body <> "*** End Patch\n"

  defp apply_patch(input, ctx) do
    case ApplyPatch.run(%{"input" => input}, ctx) do
      {:ok, %Result{model_text: text}} -> {:ok, text}
      {:error, message} -> {:error, message}
    end
  end

  test "updates a file from a hunk with context", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "a.py", "def greet():\n    print('hi')\n    return 1\n")

    assert {:ok, text} =
             apply_patch(
               patch("""
               *** Update File: a.py
               @@ def greet():
                    print('hi')
               -    return 1
               +    return 2
               """),
               ctx
             )

    assert text == "Success. Updated the following files:\nM a.py"
    assert read(tmp_dir, "a.py") == "def greet():\n    print('hi')\n    return 2\n"
  end

  test "adds, deletes and moves files in one patch", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "old.txt", "one\ntwo\n")
    write(tmp_dir, "gone.txt", "bye\n")

    assert {:ok, text} =
             apply_patch(
               patch("""
               *** Add File: new/hello.txt
               +hello
               +world
               *** Delete File: gone.txt
               *** Update File: old.txt
               *** Move to: moved.txt
               @@
                one
               -two
               +three
               """),
               ctx
             )

    assert text =~ "A moved.txt (moved from old.txt)"
    assert text =~ "A new/hello.txt"
    assert text =~ "D gone.txt"
    assert text =~ "D old.txt"
    assert read(tmp_dir, "new/hello.txt") == "hello\nworld\n"
    assert read(tmp_dir, "moved.txt") == "one\nthree\n"
    refute File.exists?(Path.join(tmp_dir, "gone.txt"))
    refute File.exists?(Path.join(tmp_dir, "old.txt"))
  end

  test "a hunk that does not match changes nothing and says what it looked for", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "a.txt", "alpha\nbeta\n")
    write(tmp_dir, "b.txt", "keep\n")

    assert {:error, message} =
             apply_patch(
               patch("""
               *** Update File: b.txt
               -keep
               +changed
               *** Update File: a.txt
               @@
               -gamma
               +delta
               """),
               ctx
             )

    assert message =~ "could not find the lines hunk 1 changes in a.txt"
    assert message =~ "gamma"
    assert message =~ "No files were changed."
    # The first file's hunk applied in memory, and was still not written.
    assert read(tmp_dir, "b.txt") == "keep\n"
  end

  test "whitespace differences in context still locate the lines", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "a.ex", "def a do\n  :one   \nend\n")

    assert {:ok, _text} =
             apply_patch(
               patch("""
               *** Update File: a.ex
               @@
                def a do
               -  :one
               +  :two
                end
               """),
               ctx
             )

    assert read(tmp_dir, "a.ex") == "def a do\n  :two\nend\n"
  end

  test "CRLF files keep CRLF, including added lines", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "win.txt", "one\r\ntwo\r\nthree\r\n")

    assert {:ok, _text} =
             apply_patch(
               patch("""
               *** Update File: win.txt
                one
               -two
               +2
               +2.5
                three
               """),
               ctx
             )

    assert read(tmp_dir, "win.txt") == "one\r\n2\r\n2.5\r\nthree\r\n"
  end

  test "a missing final newline stays missing and a BOM stays", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "a.txt", "\uFEFFfirst\nlast")

    assert {:ok, _text} =
             apply_patch(
               patch("""
               *** Update File: a.txt
                first
               -last
               +final
               *** End of File
               """),
               ctx
             )

    assert read(tmp_dir, "a.txt") == "\uFEFFfirst\nfinal"
  end

  test "@@ headers narrow the search in order", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "a.py", """
    class A:
        def get(self):
            return 1
    class B:
        def get(self):
            return 1
    """)

    assert {:ok, _text} =
             apply_patch(
               patch("""
               *** Update File: a.py
               @@ class B:
               @@     def get(self):
               -        return 1
               +        return 2
               """),
               ctx
             )

    assert read(tmp_dir, "a.py") =~ "class A:\n    def get(self):\n        return 1\n"
    assert read(tmp_dir, "a.py") =~ "class B:\n    def get(self):\n        return 2\n"
  end

  test "a hunk of additions goes after its header, or at the end without one", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "list.txt", "a\nb\n")

    assert {:ok, _text} =
             apply_patch(patch("*** Update File: list.txt\n@@ a\n+a2\n@@\n+z\n"), ctx)

    assert read(tmp_dir, "list.txt") == "a\na2\nb\nz\n"
  end

  test "heredoc wrappers, missing envelopes and unified headers are accepted", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "a.txt", "one\ntwo\n")

    wrapped = "apply_patch <<'EOF'\n" <> patch("*** Update File: a.txt\n-one\n+uno\n") <> "EOF\n"
    assert {:ok, _text} = apply_patch(wrapped, ctx)

    assert {:ok, _text} =
             apply_patch("*** Update File: a.txt\n@@ -2,1 +2,1 @@\n-two\n+dos\n", ctx)

    assert read(tmp_dir, "a.txt") == "uno\ndos\n"
  end

  test "adding over an existing file or changing a missing one is refused", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "here.txt", "x\n")

    assert {:error, message} = apply_patch(patch("*** Add File: here.txt\n+y\n"), ctx)
    assert message =~ "already exists"

    assert {:error, message} = apply_patch(patch("*** Delete File: nope.txt\n"), ctx)
    assert message =~ "nope.txt: no such file"

    assert {:error, message} = apply_patch(patch("*** Update File: nope.txt\n-a\n+b\n"), ctx)
    assert message =~ "no such file"
    assert read(tmp_dir, "here.txt") == "x\n"
  end

  test "paths outside the working directory are refused", %{tmp_dir: tmp_dir, ctx: ctx} do
    assert {:error, message} = apply_patch(patch("*** Add File: ../escape.txt\n+x\n"), ctx)
    assert message =~ "outside the working directory"
    refute File.exists?(Path.join(Path.dirname(tmp_dir), "escape.txt"))

    # An absolute path that names a file in the project is fine.
    write(tmp_dir, "in.txt", "a\n")

    assert {:ok, _text} =
             apply_patch(
               patch("*** Update File: #{Path.join(tmp_dir, "in.txt")}\n-a\n+b\n"),
               ctx
             )

    assert read(tmp_dir, "in.txt") == "b\n"
  end

  test "malformed patches name the problem", %{ctx: ctx} do
    assert {:error, message} = apply_patch("hello", ctx)
    assert message =~ "*** Begin Patch"

    assert {:error, message} = apply_patch(patch("*** Add File: a.txt\nno plus\n"), ctx)
    assert message =~ "every line must start with +"

    assert {:error, message} = apply_patch(patch("*** Update File: a.txt\n context only\n"), ctx)
    assert message =~ "only context lines"

    assert {:error, message} = apply_patch(patch(""), ctx)
    assert message =~ "no file operations"
  end

  test "deletes go through the environment's own delete when it has one", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "gone.txt", "x\n")
    ctx = %{ctx | environment: {Deleting, self()}}

    assert {:ok, _text} = apply_patch(patch("*** Delete File: gone.txt\n"), ctx)
    assert_received {:deleted, "gone.txt"}
    refute File.exists?(Path.join(tmp_dir, "gone.txt"))
  end

  describe "in a session that tracks what it has read" do
    setup %{ctx: ctx} do
      runtime = :"lemieux_apply_patch_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      session_id = "01PATCH#{System.unique_integer([:positive])}"
      %{ctx: Map.merge(ctx, %{session: self(), supervisor: runtime, session_id: session_id})}
    end

    test "deleting a file the session has not read is refused", %{tmp_dir: tmp_dir, ctx: ctx} do
      write(tmp_dir, "keep.txt", "the user's work\n")

      assert {:error, message} = apply_patch(patch("*** Delete File: keep.txt\n"), ctx)
      assert message =~ "has not been read in this session"
      assert read(tmp_dir, "keep.txt") == "the user's work\n"

      assert {:ok, _listing} = Read.run(%{"path" => "keep.txt"}, ctx)

      assert {:ok, "Success. Updated the following files:\nD keep.txt"} =
               apply_patch(patch("*** Delete File: keep.txt\n"), ctx)
    end

    test "deleting a file changed since it was read is refused", %{tmp_dir: tmp_dir, ctx: ctx} do
      write(tmp_dir, "a.txt", "old\n")
      assert {:ok, _listing} = Read.run(%{"path" => "a.txt"}, ctx)
      write(tmp_dir, "a.txt", "someone else's change\n")

      assert {:error, message} = apply_patch(patch("*** Delete File: a.txt\n"), ctx)
      assert message =~ "changed since"
      assert read(tmp_dir, "a.txt") == "someone else's change\n"
    end

    test "an update of a changed file proceeds and says it was stale", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      write(tmp_dir, "a.txt", "one\ntwo\n")
      assert {:ok, _listing} = Read.run(%{"path" => "a.txt"}, ctx)
      write(tmp_dir, "a.txt", "one\ntwo\nthree\n")

      assert {:ok, text} = apply_patch(patch("*** Update File: a.txt\n one\n-two\n+2\n"), ctx)
      assert text =~ "M a.txt"
      assert text =~ "Note: a.txt changed since this session last read or wrote it"
      assert read(tmp_dir, "a.txt") == "one\n2\nthree\n"
    end

    test "what a patch wrote counts as seen, so write may replace it next", %{ctx: ctx} do
      assert {:ok, _text} = apply_patch(patch("*** Add File: new.txt\n+first\n"), ctx)

      assert {:ok, output} =
               Write.run(%{"path" => "new.txt", "content" => "second\n"}, ctx)

      assert output =~ "overwrote"
    end
  end

  test "paths/1 lists every file a patch touches" do
    assert {:ok, ["a.txt", "b.txt", "c.txt", "d.txt"]} =
             ApplyPatch.paths(
               patch(
                 "*** Add File: a.txt\n+x\n*** Delete File: b.txt\n" <>
                   "*** Update File: c.txt\n*** Move to: d.txt\n-x\n+y\n"
               )
             )
  end

  test "is a write tool that runs alone" do
    refute Lemieux.Tool.read_only?(ApplyPatch)
    refute Lemieux.Tool.parallel_safe?(ApplyPatch)
    assert :ok = Lemieux.Tool.validate_all([ApplyPatch])
  end
end
