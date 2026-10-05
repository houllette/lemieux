defmodule Lemieux.Environment.SandboxFilesTest do
  # A path the sandbox hides is hidden from the file tools as well as from
  # commands. `lmx --sandbox --config ./lmx.json` hid the config file from
  # `cat`, and `read` returned it, saved key and all.
  #
  # The sandboxes here are built by hand: the file callbacks never start the
  # sandbox's executable, so this runs on machines with neither Seatbelt nor
  # bubblewrap.
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(Path.join(work, "secrets"))
    File.write!(Path.join(work, "lmx.json"), ~s({"providers": {"openai": {"api_key": "sk-x"}}}))
    File.write!(Path.join([work, "secrets", "token.json"]), "{}")
    File.write!(Path.join(work, "notes.txt"), "visible\n")

    %{work: work, sandbox: sandbox([Path.join(work, "lmx.json"), Path.join(work, "secrets")])}
  end

  defp sandbox(hidden) do
    {Sandbox,
     %Sandbox{
       backend: :seatbelt,
       executable: "/nonexistent/sandbox-exec",
       inner: Lemieux.Environment.Local,
       shell: "/bin/sh",
       hidden: Enum.map(hidden, &Sandbox.real/1)
     }}
  end

  test "a hidden file or directory cannot be read, however it is named", ctx do
    for path <- [
          "lmx.json",
          "./lmx.json",
          "secrets/../lmx.json",
          Path.join(ctx.work, "lmx.json"),
          "secrets/token.json"
        ] do
      assert Environment.read_file(ctx.sandbox, ctx.work, path) == {:error, :eacces}, path
      assert Environment.stream_file(ctx.sandbox, ctx.work, path) == {:error, :eacces}, path
    end

    assert Environment.list_dir(ctx.sandbox, ctx.work, "secrets") == {:error, :eacces}
    assert {:ok, "visible\n"} = Environment.read_file(ctx.sandbox, ctx.work, "notes.txt")
  end

  test "nor written over, created in or deleted", ctx do
    assert Environment.write_file(ctx.sandbox, ctx.work, "lmx.json", "{}") == {:error, :eacces}

    assert Environment.write_file(ctx.sandbox, ctx.work, "secrets/new.json", "{}") ==
             {:error, :eacces}

    assert Environment.delete_file(ctx.sandbox, ctx.work, "lmx.json") == {:error, :eacces}

    assert File.read!(Path.join(ctx.work, "lmx.json")) =~ "sk-x"
    refute File.exists?(Path.join([ctx.work, "secrets", "new.json"]))
  end

  # A link is judged by where it leads, as the kernel judges a command's open.
  test "a link to a hidden file is the hidden file", ctx do
    File.ln_s!("lmx.json", Path.join(ctx.work, "innocent.txt"))

    assert Environment.read_file(ctx.sandbox, ctx.work, "innocent.txt") == {:error, :eacces}
  end

  # The directory around a hidden path is still the work, names and all — as
  # it is to `ls` inside the sandbox.
  test "the directory around a hidden path stays listable and writable", ctx do
    assert {:ok, entries} = Environment.list_dir(ctx.sandbox, ctx.work, ".")
    assert ["lmx.json", "notes.txt", "secrets"] == entries |> Enum.map(& &1.name) |> Enum.sort()

    assert {:ok, :created} = Environment.write_file(ctx.sandbox, ctx.work, "out.txt", "ok\n")
    assert :ok = Environment.delete_file(ctx.sandbox, ctx.work, "out.txt")
  end

  test "the file tools say permission denied", ctx do
    tool = %{cwd: ctx.work, session_id: "s1", call_id: "c1", environment: ctx.sandbox}

    assert {:error, "lmx.json: permission denied"} = Read.run(%{"path" => "lmx.json"}, tool)

    assert {:error, "lmx.json: permission denied"} =
             Write.run(%{"path" => "lmx.json", "content" => "{}"}, tool)
  end

  test "a sandbox hiding nothing passes every path through", ctx do
    open = sandbox([])

    assert {:ok, contents} = Environment.read_file(open, ctx.work, "lmx.json")
    assert contents =~ "sk-x"
  end

  test "within?/2 holds for a path and what is under it, and the root holds everything" do
    assert Sandbox.within?("/a/b", "/a/b")
    assert Sandbox.within?("/a/b/c", "/a/b")
    refute Sandbox.within?("/a/bc", "/a/b")
    refute Sandbox.within?("/a", "/a/b")
    assert Sandbox.within?("/a/b", "/")
    assert Sandbox.within?("/", "/")
  end
end
