defmodule Lemieux.Tools.WriteTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

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

  test "creates a file with the given content", %{tmp_dir: tmp_dir, ctx: ctx} do
    assert {:ok, output} = Write.run(%{"path" => "a.txt", "content" => "hello"}, ctx)

    assert File.read!(Path.join(tmp_dir, "a.txt")) == "hello"
    assert output =~ "a.txt"
  end

  test "creates missing parent directories", %{tmp_dir: tmp_dir, ctx: ctx} do
    assert {:ok, _output} = Write.run(%{"path" => "deep/er/still/a.txt", "content" => "hi"}, ctx)

    assert File.read!(Path.join(tmp_dir, "deep/er/still/a.txt")) == "hi"
  end

  test "overwrites an existing file, and says it did", %{tmp_dir: tmp_dir, ctx: ctx} do
    File.write!(Path.join(tmp_dir, "a.txt"), "old")

    assert {:ok, output} = Write.run(%{"path" => "a.txt", "content" => "new"}, ctx)

    assert File.read!(Path.join(tmp_dir, "a.txt")) == "new"
    # The model has to know it replaced something rather than created it —
    # otherwise a write meant to add a file silently destroys one.
    assert output =~ "overwrote"
  end

  test "reports how much it wrote, so a truncated write is visible", %{ctx: ctx} do
    assert {:ok, output} = Write.run(%{"path" => "a.txt", "content" => "12345"}, ctx)

    assert output =~ "5 bytes"
  end

  test "writing over a directory is an error, not a crash", %{tmp_dir: tmp_dir, ctx: ctx} do
    File.mkdir_p!(Path.join(tmp_dir, "sub"))

    assert {:error, message} = Write.run(%{"path" => "sub", "content" => "hi"}, ctx)
    assert message =~ "sub"
  end

  test "content is required, and its absence is an error the model can act on", %{ctx: ctx} do
    assert {:error, message} = Write.run(%{"path" => "a.txt"}, ctx)
    assert message =~ "content"
  end

  describe "in a session" do
    setup %{ctx: ctx} do
      runtime = :"lemieux_write_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})

      session_id = "01WRITE#{System.unique_integer([:positive])}"
      %{ctx: Map.merge(ctx, %{session: self(), supervisor: runtime, session_id: session_id})}
    end

    test "an existing file the session has not read is not replaced", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      File.write!(Path.join(tmp_dir, "a.txt"), "the user's work")

      assert {:error, message} = Write.run(%{"path" => "a.txt", "content" => "new"}, ctx)
      assert message =~ "has not been read"
      assert File.read!(Path.join(tmp_dir, "a.txt")) == "the user's work"
    end

    test "reading the file first allows replacing it", %{tmp_dir: tmp_dir, ctx: ctx} do
      File.write!(Path.join(tmp_dir, "a.txt"), "old")

      assert {:ok, _listing} = Read.run(%{"path" => "a.txt"}, ctx)
      assert {:ok, output} = Write.run(%{"path" => "a.txt", "content" => "new"}, ctx)
      assert output =~ "overwrote"
      assert File.read!(Path.join(tmp_dir, "a.txt")) == "new"
    end

    test "a file changed since it was read has to be read again", %{tmp_dir: tmp_dir, ctx: ctx} do
      File.write!(Path.join(tmp_dir, "a.txt"), "old")
      assert {:ok, _listing} = Read.run(%{"path" => "a.txt"}, ctx)
      File.write!(Path.join(tmp_dir, "a.txt"), "someone else's change")

      assert {:error, message} = Write.run(%{"path" => "a.txt", "content" => "new"}, ctx)
      assert message =~ "changed since"
      assert File.read!(Path.join(tmp_dir, "a.txt")) == "someone else's change"
    end

    test "a file the session wrote can be written again", %{ctx: ctx} do
      assert {:ok, _created} = Write.run(%{"path" => "b.txt", "content" => "one"}, ctx)
      assert {:ok, output} = Write.run(%{"path" => "b.txt", "content" => "two"}, ctx)
      assert output =~ "overwrote"
    end

    test "an absolute path and a relative one are the same file", %{tmp_dir: tmp_dir, ctx: ctx} do
      File.write!(Path.join(tmp_dir, "c.txt"), "old")
      assert {:ok, _listing} = Read.run(%{"path" => Path.join(tmp_dir, "c.txt")}, ctx)

      assert {:ok, _output} = Write.run(%{"path" => "c.txt", "content" => "new"}, ctx)
    end

    test "writing what the file already holds replaces nothing and is allowed", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      File.write!(Path.join(tmp_dir, "same.txt"), "same")

      assert {:ok, output} = Write.run(%{"path" => "same.txt", "content" => "same"}, ctx)
      assert output =~ "unchanged"
    end

    test "the record belongs to one session", %{tmp_dir: tmp_dir, ctx: ctx} do
      File.write!(Path.join(tmp_dir, "d.txt"), "old")
      assert {:ok, _listing} = Read.run(%{"path" => "d.txt"}, ctx)

      other = %{ctx | session_id: ctx.session_id <> "-other"}
      assert {:error, message} = Write.run(%{"path" => "d.txt", "content" => "new"}, other)
      assert message =~ "has not been read"
    end
  end

  test "the tool describes itself well enough to be called" do
    assert Write.name() == "write"
    assert %{"required" => required} = Write.schema()
    assert Enum.sort(required) == ["content", "path"]
  end
end
