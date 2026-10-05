defmodule Lemieux.Checkpoint.UnsavedTest do
  # Files a command's snapshot notices but does not save — ignored ones such
  # as `.env`, anything inside an ignored directory — when a file tool also
  # changes them in the same turn. Undo used to put back the file tool's
  # capture, which held the command's version, and call that "restored".
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Conversation.Command.Undo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q"])
    put(work, ".gitignore", ".env\nconfig/local/\n")
    put(work, ".env.example", "API_KEY=changeme\n")
    put(work, "config/app.exs", "app\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])

    %{
      store: Path.join(tmp_dir, "checkpoints"),
      work: work,
      ctx: %{cwd: work, session_id: "s1", call_id: "c1"}
    }
  end

  defp git(work, args) do
    {output, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
          args,
        cd: work,
        stderr_to_stdout: true
      )

    output
  end

  defp put(work, name, contents) do
    path = Path.join(work, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp read(work, name), do: File.read(Path.join(work, name))

  # What the wrappers do around one command and one file tool call.
  defp command(store, ctx, fun) do
    :ok = Checkpoint.snapshot(store, ctx, :before, subject: "`a command`")
    fun.()
    :ok = Checkpoint.snapshot(store, ctx, :after)
  end

  defp edit(store, ctx, name, contents) do
    :ok = Checkpoint.capture(store, ctx, name, tool: "edit")
    put(ctx.cwd, name, contents)
    :ok = Checkpoint.record_after(store, ctx, name)
  end

  test "an ignored file a command created and the agent then edited is deleted",
       %{store: store, work: work, ctx: ctx} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")

    command(store, ctx, fn ->
      File.cp!(Path.join(work, ".env.example"), Path.join(work, ".env"))
    end)

    edit(store, %{ctx | call_id: "c2"}, ".env", "API_KEY=sk-live-123\n")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.deleted == [".env"]
    assert report.restored == [] and report.unrestorable == []
    assert read(work, ".env") == {:error, :enoent}
    assert Undo.note([report]) =~ "Removed again (you had created them): .env."
  end

  test "an ignored file a command rewrote before the agent edited it is named, and left",
       %{store: store, work: work, ctx: ctx} do
    put(work, ".env", "TOKEN=original\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    command(store, ctx, fn -> put(work, ".env", "TOKEN=by-the-command\n") end)
    edit(store, %{ctx | call_id: "c2"}, ".env", "TOKEN=by-the-command\nEXTRA=1\n")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.restored == [] and report.deleted == []
    assert [%{path: ".env", reason: reason}] = report.unrestorable
    assert reason =~ "a command changed it before the agent's file tool did"
    assert reason =~ "git ignores it"
    assert read(work, ".env") == {:ok, "TOKEN=by-the-command\nEXTRA=1\n"}
    # Nothing was put back, so the model is told nothing was.
    assert Undo.note([report]) == nil
  end

  test "an ignored file the agent edited and a command then rewrote goes back to before both",
       %{store: store, work: work, ctx: ctx} do
    put(work, ".env", "TOKEN=original\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    edit(store, ctx, ".env", "TOKEN=edited\n")

    command(store, %{ctx | call_id: "c2"}, fn ->
      put(work, ".env", "TOKEN=rewritten-by-the-command\n")
    end)

    assert {:ok, %{restored: [".env"], conflicts: [], unrestorable: []}} =
             Checkpoint.undo(store, "s1")

    assert read(work, ".env") == {:ok, "TOKEN=original\n"}
  end

  test "an ignored file only a command created is named, never deleted",
       %{store: store, work: work, ctx: ctx} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    command(store, ctx, fn -> put(work, ".env", "TOKEN=1\n") end)

    assert {:ok, %{deleted: [], unrestorable: [%{path: ".env", reason: reason}]}} =
             Checkpoint.undo(store, "s1")

    assert reason =~ "created while a command ran"
    assert read(work, ".env") == {:ok, "TOKEN=1\n"}
  end

  test "a file inside an ignored directory an earlier command could have changed is flagged",
       %{store: store, work: work, ctx: ctx} do
    put(work, "config/local/settings.json", "{\"port\": 4000}\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")

    command(store, ctx, fn -> put(work, "config/local/settings.json", "{\"port\": 4001}\n") end)
    edit(store, %{ctx | call_id: "c2"}, "config/local/settings.json", "{\"port\": 4002}\n")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    # Put back as the edit found it — all undo has — and said to be that.
    assert report.restored == ["config/local/settings.json"]
    assert [%{path: "config/local/settings.json", reason: reason}] = report.uncertain
    assert reason =~ "an earlier command in this turn may have changed it first"
    assert read(work, "config/local/settings.json") == {:ok, "{\"port\": 4001}\n"}

    assert Undo.describe(report) =~ "may still differ from before the turn"
    note = Undo.note([report])
    assert note =~ "though a command may have changed them before that"
    refute note =~ "Put back as they were before:"
  end

  test "an edit inside an ignored directory with no command before it is plainly restored",
       %{store: store, work: work, ctx: ctx} do
    put(work, "config/local/settings.json", "{\"port\": 4000}\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    edit(store, ctx, "config/local/settings.json", "{\"port\": 4002}\n")
    # A command after the edit cannot have changed what the edit found.
    command(store, %{ctx | call_id: "c2"}, fn -> :ok end)

    assert {:ok, %{restored: ["config/local/settings.json"], uncertain: []}} =
             Checkpoint.undo(store, "s1")

    assert read(work, "config/local/settings.json") == {:ok, "{\"port\": 4000}\n"}
  end

  test "an empty directory the person had stays when a command's file in it is deleted",
       %{store: store, work: work, ctx: ctx} do
    File.mkdir_p!(Path.join(work, "uploads"))
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")

    command(store, ctx, fn ->
      put(work, "uploads/x.txt", "x\n")
      put(work, "made/deep/y.txt", "y\n")
    end)

    assert {:ok, %{deleted: deleted}} = Checkpoint.undo(store, "s1")
    assert Enum.sort(deleted) == ["made/deep/y.txt", "uploads/x.txt"]
    assert File.dir?(Path.join(work, "uploads"))
    # A directory the command made goes with its files.
    refute File.exists?(Path.join(work, "made"))
  end

  # Linux allows any byte in a file name and git prints it as it is; JSON
  # holds only UTF-8. macOS refuses such names, so the name is put into the
  # record the way a Linux snapshot would have written it.
  test "a file name that is not UTF-8 is recorded, reported and shown",
       %{store: store, work: work, ctx: ctx} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    command(store, ctx, fn -> put(work, ".env", "TOKEN=1\n") end)

    [window] = Path.wildcard(Path.join(store, "s1/turns/1/commands/*.json"))
    {:ok, record} = Store.json(window)
    latin1 = "r" <> <<0xE9>> <> "sum" <> <<0xE9>> <> ".log"
    entry = [latin1, 10, 0, 1, "ignored"]
    record = update_in(record, ["after", "unsaved"], &[entry | &1])
    assert :ok = Store.put_json(window, record)

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert latin1 in Enum.map(report.unrestorable, & &1.path)
    assert File.regular?(Path.join(store, "s1/turns/1/undone.json"))

    line = Undo.describe(report)
    assert String.valid?(line)
    assert line =~ "r�sum�.log"
  end
end
