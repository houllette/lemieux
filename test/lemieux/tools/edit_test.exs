defmodule Lemieux.Tools.EditTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Edit
  alias Lemieux.Tools.Read

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{
      ctx: %{
        cwd: tmp_dir,
        session_id: "s1",
        call_id: "c1",
        environment: Lemieux.Environment.local()
      }
    }
  end

  defp write(tmp_dir, contents) do
    File.write!(Path.join(tmp_dir, "a.ex"), contents)
    "a.ex"
  end

  defp read(tmp_dir), do: File.read!(Path.join(tmp_dir, "a.ex"))

  test "replaces a unique occurrence", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "def hello, do: :world\n")

    assert {:ok, output} =
             Edit.run(%{"path" => file, "old" => ":world", "new" => ":universe"}, ctx)

    assert read(tmp_dir) == "def hello, do: :universe\n"
    assert output =~ "a.ex"
  end

  test "a non-unique old string is an error naming the count", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "a\nb\na\n")

    assert {:error, message} = Edit.run(%{"path" => file, "old" => "a", "new" => "c"}, ctx)

    assert message =~ "2 times"
    assert read(tmp_dir) == "a\nb\na\n"
  end

  test "replace_all edits every occurrence when the model means to", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "a\nb\na\n")

    assert {:ok, output} =
             Edit.run(%{"path" => file, "old" => "a", "new" => "c", "replace_all" => true}, ctx)

    assert read(tmp_dir) == "c\nb\nc\n"
    assert output =~ "2 occurrences"
  end

  test "a missing old string is an error", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "hello\n")

    assert {:error, message} = Edit.run(%{"path" => file, "old" => "goodbye", "new" => "x"}, ctx)

    assert message =~ "not found"
    assert read(tmp_dir) == "hello\n"
  end

  test "an old string equal to the new one is refused rather than pretending to work", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "hello\n")

    assert {:error, message} =
             Edit.run(%{"path" => file, "old" => "hello", "new" => "hello"}, ctx)

    assert message =~ "identical"
  end

  test "a missing file is an error, not a crash", %{ctx: ctx} do
    assert {:error, message} = Edit.run(%{"path" => "nope.ex", "old" => "a", "new" => "b"}, ctx)
    assert message =~ "no such file"
  end

  test "an empty old string is refused: it matches everywhere and nowhere", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "hello\n")

    assert {:error, message} = Edit.run(%{"path" => file, "old" => "", "new" => "x"}, ctx)
    assert message =~ "empty"
  end

  test "deleting text is an edit to the empty string", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "keep\ndrop\n")

    assert {:ok, _output} = Edit.run(%{"path" => file, "old" => "drop\n", "new" => ""}, ctx)
    assert read(tmp_dir) == "keep\n"
  end

  describe "close is not a miss" do
    test "a multi-line edit matches a CRLF file and keeps its line endings", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "one\r\ntwo\r\nthree\r\n")

      assert {:ok, _output} =
               Edit.run(%{"path" => file, "old" => "one\ntwo\n", "new" => "1\n2\n"}, ctx)

      assert read(tmp_dir) == "1\r\n2\r\nthree\r\n"
    end

    test "a byte-order mark is kept and does not stop a match at the start", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, <<0xEF, 0xBB, 0xBF>> <> "first\nsecond\n")

      assert {:ok, _output} = Edit.run(%{"path" => file, "old" => "first", "new" => "1st"}, ctx)
      assert read(tmp_dir) == <<0xEF, 0xBB, 0xBF>> <> "1st\nsecond\n"
    end

    test "line numbers copied from read are ignored", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "defmodule A do\n  def a, do: 1\nend\n")

      assert {:ok, output} =
               Edit.run(
                 %{"path" => file, "old" => "2\t  def a, do: 1", "new" => "2\t  def a, do: 2"},
                 ctx
               )

      assert read(tmp_dir) == "defmodule A do\n  def a, do: 2\nend\n"
      assert output =~ "line numbers"
    end

    test "a block copied at the wrong depth lands at the right one", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "defmodule A do\n  def a do\n    :a\n  end\nend\n")

      assert {:ok, output} =
               Edit.run(
                 %{
                   "path" => file,
                   "old" => "def a do\n  :a\nend",
                   "new" => "def a do\n  :b\nend"
                 },
                 ctx
               )

      assert read(tmp_dir) == "defmodule A do\n  def a do\n    :b\n  end\nend\n"
      assert output =~ "indentation"
    end

    test "trailing whitespace does not stop a match", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "a = 1   \nb = 2\n")

      assert {:ok, _output} =
               Edit.run(%{"path" => file, "old" => "a = 1\nb = 2", "new" => "a = 3\nb = 4"}, ctx)

      assert read(tmp_dir) == "a = 3\nb = 4\n"
    end

    test "a loose match in two places is refused rather than aimed", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "  x  =  1\n    x  =  1\n")

      assert {:error, message} =
               Edit.run(%{"path" => file, "old" => "x = 1", "new" => "x = 2"}, ctx)

      assert message =~ "2 places"
      assert read(tmp_dir) == "  x  =  1\n    x  =  1\n"
    end

    test "a miss shows the closest text", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "alpha\ndef handle(conn, params) do\n  render(conn)\nend\nomega\n")

      assert {:error, message} =
               Edit.run(
                 %{
                   "path" => file,
                   "old" => "def handle(conn, _params) do\n  render(conn)\nend",
                   "new" => "x"
                 },
                 ctx
               )

      assert message =~ "not found"
      assert message =~ "closest text is lines 2-4"
      assert message =~ "2\tdef handle(conn, params) do"
    end
  end

  test "the result shows the edited lines, numbered", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n")

    assert {:ok, output} =
             Edit.run(%{"path" => file, "old" => "line 10\n", "new" => "ten\nTEN\n"}, ctx)

    assert output =~ "8\tline 8\n9\tline 9\n10\tten\n11\tTEN\n12\tline 11\n13\tline 12"
    refute output =~ "line 13"
  end

  test "an edit to a file changed since the session read it says so", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    runtime = :"lemieux_edit_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    ctx = Map.merge(ctx, %{session: self(), supervisor: runtime})

    file = write(tmp_dir, "a\nb\n")
    assert {:ok, _read} = Read.run(%{"path" => file}, ctx)
    File.write!(Path.join(tmp_dir, file), "a\nb\nc\n")

    assert {:ok, output} = Edit.run(%{"path" => file, "old" => "b", "new" => "B"}, ctx)
    assert output =~ "changed since this session last read"

    # The edit is now what the session last saw, so the next one is quiet.
    assert {:ok, output} = Edit.run(%{"path" => file, "old" => "c", "new" => "C"}, ctx)
    refute output =~ "changed since"
  end

  test "the tool describes itself well enough to be called" do
    assert Edit.name() == "edit"
    assert %{"required" => required} = Edit.schema()
    assert Enum.sort(required) == ["new", "old", "path"]
  end
end
