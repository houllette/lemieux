defmodule Lemieux.Checkpoint.PrivateGitTest do
  # Snapshots and restores run git in a directory of their own, with the
  # repository's work tree, index copy and objects handed to it
  # (`Lemieux.Checkpoint.Git`). What that directory must carry over for git
  # to read a repository as the person's own git does: a linked worktree's
  # layout, SHA-256 object names, a split index's shared part, the
  # repository's `info/exclude`, the person's own excludes file, and the
  # line-ending settings that decide what a file hashes to.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    %{tmp_dir: tmp_dir, work: work, store: Path.join(tmp_dir, "checkpoints")}
  end

  defp git(dir, args) do
    {output, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
          args,
        cd: dir,
        stderr_to_stdout: true
      )

    output
  end

  defp put(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp commit_all(dir) do
    git(dir, ["add", "-A"])
    git(dir, ["commit", "-qm", "init"])
  end

  # One command's window around `change`, then the undo of its turn.
  defp undo_command(store, cwd, change) do
    ctx = %{cwd: cwd, session_id: "s1", call_id: "c1"}
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    assert :ok = Checkpoint.snapshot(store, ctx, :before)
    change.()
    assert :ok = Checkpoint.snapshot(store, ctx, :after)
    Checkpoint.undo(store, "s1")
  end

  test "a linked worktree, whose .git is a file naming its git directory", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, "a.txt", "v0\n")
    commit_all(ctx.work)
    linked = Path.join(ctx.tmp_dir, "linked")
    git(ctx.work, ["worktree", "add", "-q", linked])
    assert File.regular?(Path.join(linked, ".git"))

    assert {:ok, %{restored: ["a.txt"], deleted: ["b.txt"]}} =
             undo_command(ctx.store, linked, fn ->
               put(linked, "a.txt", "by a command\n")
               put(linked, "b.txt", "made\n")
             end)

    assert File.read!(Path.join(linked, "a.txt")) == "v0\n"
    refute File.exists?(Path.join(linked, "b.txt"))
  end

  test "a repository with SHA-256 object names", ctx do
    case System.cmd("git", ["init", "-q", "--object-format=sha256"],
           cd: ctx.work,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        put(ctx.work, "a.txt", "v0\n")
        commit_all(ctx.work)

        assert {:ok, %{restored: ["a.txt"]}} =
                 undo_command(ctx.store, ctx.work, fn -> put(ctx.work, "a.txt", "changed\n") end)

        assert File.read!(Path.join(ctx.work, "a.txt")) == "v0\n"

      {_output, _status} ->
        # A git without SHA-256 repositories has none to snapshot either.
        :ok
    end
  end

  test "a split index, read with its shared part", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, "a.txt", "v0\n")
    commit_all(ctx.work)
    git(ctx.work, ["update-index", "--split-index"])
    assert Path.wildcard(Path.join(ctx.work, ".git/sharedindex.*")) != []

    assert {:ok, %{restored: ["a.txt"]}} =
             undo_command(ctx.store, ctx.work, fn -> put(ctx.work, "a.txt", "changed\n") end)

    assert File.read!(Path.join(ctx.work, "a.txt")) == "v0\n"
  end

  test "the repository's info/exclude and the person's excludes file are honoured", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, "tracked.txt", "v0\n")
    commit_all(ctx.work)
    put(ctx.work, ".git/info/exclude", "local.log\n")
    personal = Path.join(ctx.tmp_dir, "personal-ignore")
    File.write!(personal, "*.swp\n")
    git(ctx.work, ["config", "core.excludesFile", personal])

    {:ok, report} =
      undo_command(ctx.store, ctx.work, fn ->
        put(ctx.work, "local.log", "a log\n")
        put(ctx.work, "notes.txt.swp", "an editor's\n")
        put(ctx.work, "kept.txt", "new\n")
      end)

    # Ignored, so named and left; not ignored, so added and deleted again.
    assert report.deleted == ["kept.txt"]
    named = Enum.map(report.unrestorable, & &1.path)
    assert "local.log" in named
    assert "notes.txt.swp" in named
    assert File.exists?(Path.join(ctx.work, "local.log"))
  end

  test "a file checked out with CRLF line endings goes back byte for byte", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, ".gitattributes", "*.bat text eol=crlf\n")
    put(ctx.work, "run.bat", "echo one\r\necho two\r\n")
    commit_all(ctx.work)
    # Checked out again, as git writes it: CRLF in the work tree, LF stored.
    File.rm!(Path.join(ctx.work, "run.bat"))
    git(ctx.work, ["checkout", "--", "run.bat"])
    original = File.read!(Path.join(ctx.work, "run.bat"))
    assert original == "echo one\r\necho two\r\n"

    assert {:ok, %{restored: ["run.bat"], conflicts: []}} =
             undo_command(ctx.store, ctx.work, fn ->
               put(ctx.work, "run.bat", "echo changed\r\n")
             end)

    assert File.read!(Path.join(ctx.work, "run.bat")) == original
  end

  # Counting how far a branch is ahead of its upstream walks history, and a
  # shallow clone's stops at the commits listed in `shallow`: without the
  # list, git looked for parents that were never fetched and failed, and the
  # startup status of a `--depth 1` clone with a commit of its own read "not
  # a repository".
  test "a shallow clone's status, a commit ahead of its upstream", ctx do
    upstream = Path.join(ctx.tmp_dir, "upstream")
    File.mkdir_p!(upstream)
    git(upstream, ["init", "-q"])

    for version <- 1..3 do
      put(upstream, "a.txt", "v#{version}\n")
      commit_all(upstream)
    end

    git(ctx.tmp_dir, ["clone", "-q", "--depth", "1", "file://" <> upstream, ctx.work])
    assert File.regular?(Path.join(ctx.work, ".git/shallow"))
    put(ctx.work, "b.txt", "mine\n")
    commit_all(ctx.work)

    assert {:ok, status} = Git.status(ctx.work)
    assert status =~ ~r/\A## \S+\.\.\.origin\/\S+ \[ahead 1\]\n\z/
  end

  # `-filter` (unset) and a bare `filter` (set) name no driver, for any git,
  # so the index holds those files as they are, and undo puts them back like
  # any other. One whose attribute names a driver is still named, not
  # written: the index holds that driver's output. (Nothing defines
  # `nowhere`, so the fixture's own commits run nothing either.)
  test "a file whose filter attribute names no driver is undone like any other", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, ".gitattributes", "*.txt filter=nowhere\nunset.txt -filter\nset.txt filter\n")
    put(ctx.work, "unset.txt", "unset v0\n")
    put(ctx.work, "set.txt", "set v0\n")
    put(ctx.work, "named.txt", "named v0\n")
    commit_all(ctx.work)

    {:ok, report} =
      undo_command(ctx.store, ctx.work, fn ->
        put(ctx.work, "unset.txt", "unset by a command\n")
        put(ctx.work, "set.txt", "set by a command\n")
        put(ctx.work, "named.txt", "named by a command\n")
      end)

    assert Enum.sort(report.restored) == ["set.txt", "unset.txt"]
    assert File.read!(Path.join(ctx.work, "unset.txt")) == "unset v0\n"
    assert File.read!(Path.join(ctx.work, "set.txt")) == "set v0\n"

    assert [%{path: "named.txt", reason: reason}] = report.unrestorable
    assert reason =~ "filter"
    assert File.read!(Path.join(ctx.work, "named.txt")) == "named by a command\n"
  end

  # A driverless file is added by name, and `git add` refuses a name
  # outside a sparse checkout: one there must not fail every snapshot.
  test "a driverless file outside a sparse checkout is left as the index has it", ctx do
    git(ctx.work, ["init", "-q"])
    put(ctx.work, ".gitattributes", "*.txt filter=nowhere\nout/*.txt -filter\n")
    put(ctx.work, "in/named.txt", "named v0\n")
    put(ctx.work, "in/plain.md", "plain v0\n")
    put(ctx.work, "out/unset.txt", "unset v0\n")
    commit_all(ctx.work)
    git(ctx.work, ["sparse-checkout", "set", "in"])
    refute File.exists?(Path.join(ctx.work, "out/unset.txt"))

    assert {:ok, %{restored: ["in/plain.md"]}} =
             undo_command(ctx.store, ctx.work, fn ->
               put(ctx.work, "in/plain.md", "plain by a command\n")
             end)

    assert File.read!(Path.join(ctx.work, "in/plain.md")) == "plain v0\n"
  end
end
