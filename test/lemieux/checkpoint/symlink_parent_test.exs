defmodule Lemieux.Checkpoint.SymlinkParentTest do
  # Undo runs on this machine, outside any sandbox, over paths a command
  # recorded. A directory above one of them that was replaced with a
  # symbolic link after the command ran made undo act through the link:
  # `/undo --force` deleted a file in the directory the link pointed at,
  # outside the working tree, and reported it as the turn's file deleted
  # (found in review, 2026-10). A path through a link is left alone and said
  # so, as git itself treats it.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    outside = Path.join(tmp_dir, "outside")
    File.mkdir_p!(work)
    File.mkdir_p!(outside)
    git(work, ["init", "-q"])
    File.write!(Path.join(work, "README"), "readme\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])

    %{
      work: work,
      outside: outside,
      store: Path.join(tmp_dir, "checkpoints"),
      ctx: %{cwd: work, session_id: "s1", call_id: "c1", environment: Lemieux.Environment.local()}
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

  defp put(path, contents) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # A command creates `d/f.txt`; afterwards, outside any recorded command,
  # `d` becomes a link to a directory outside the tree holding `f.txt`.
  defp created_then_linked(ctx, outside_contents) do
    {:ok, 1} = Checkpoint.begin_turn(ctx.store, "s1")
    :ok = Checkpoint.snapshot(ctx.store, ctx.ctx, :before)
    put(Path.join(ctx.work, "d/f.txt"), "made by the command\n")
    :ok = Checkpoint.snapshot(ctx.store, ctx.ctx, :after)

    File.rm_rf!(Path.join(ctx.work, "d"))
    put(Path.join(ctx.outside, "f.txt"), outside_contents)
    File.ln_s!(ctx.outside, Path.join(ctx.work, "d"))
  end

  test "--force leaves a file reached through a replaced directory alone", ctx do
    created_then_linked(ctx, "precious, outside the repository\n")

    assert {:ok, report} = Checkpoint.undo(ctx.store, "s1", force: true)

    assert File.read!(Path.join(ctx.outside, "f.txt")) == "precious, outside the repository\n"
    refute "d/f.txt" in report.deleted
    assert [%{path: "d/f.txt", reason: reason}] = report.unrestorable
    assert reason =~ "symbolic link"
  end

  # Plain undo deleted it too when what the link reached matched what the
  # command had left.
  test "plain undo leaves it alone when the contents behind the link match", ctx do
    created_then_linked(ctx, "made by the command\n")

    assert {:ok, report} = Checkpoint.undo(ctx.store, "s1")

    assert File.read!(Path.join(ctx.outside, "f.txt")) == "made by the command\n"
    assert report.deleted == []
    assert [%{path: "d/f.txt"}] = report.unrestorable
  end

  # The file tool's delete refuses a path through a link out of the tree; the
  # empty directories its write created were then removed through the same
  # link, outside.
  test "the directories a file tool created are not removed through a link", ctx do
    {:ok, 1} = Checkpoint.begin_turn(ctx.store, "s1")
    tool = %{ctx.ctx | call_id: "w1"}
    :ok = Checkpoint.capture(ctx.store, tool, "d/sub/f.txt", tool: "write")
    put(Path.join(ctx.work, "d/sub/f.txt"), "written\n")
    :ok = Checkpoint.record_after(ctx.store, tool, "d/sub/f.txt")

    File.rm_rf!(Path.join(ctx.work, "d"))
    File.mkdir_p!(Path.join(ctx.outside, "sub"))
    File.ln_s!(ctx.outside, Path.join(ctx.work, "d"))

    assert {:ok, _report} = Checkpoint.undo(ctx.store, "s1", force: true)
    assert File.dir?(Path.join(ctx.outside, "sub"))
  end

  test "a path reached through a link reads as git reads it: not there", ctx do
    put(Path.join(ctx.outside, "f.txt"), "outside\n")
    File.ln_s!(ctx.outside, Path.join(ctx.work, "d"))

    assert {:ok, %{"d/f.txt" => nil, "README" => %{blob: blob}}} =
             Git.worktree_entries(ctx.work, ["d/f.txt", "README"])

    assert is_binary(blob)
    assert Git.beyond_link?(ctx.work, "d/f.txt")
    refute Git.beyond_link?(ctx.work, "d")
    refute Git.beyond_link?(ctx.work, "README")
  end
end
