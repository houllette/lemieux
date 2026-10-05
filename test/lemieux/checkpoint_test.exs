defmodule Lemieux.CheckpointTest do
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Checkpoint.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)

    %{
      store: Path.join(tmp_dir, "checkpoints"),
      work: work,
      ctx: %{
        cwd: work,
        session_id: "s1",
        call_id: "c1",
        environment: Lemieux.Environment.local()
      }
    }
  end

  defp put(work, name, contents) do
    path = Path.join(work, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp contents(work, name), do: File.read!(Path.join(work, name))

  # What a checkpoint wrapper does around one tool call: save, change, record.
  defp agent_writes(store, ctx, name, contents, call_id \\ "c1") do
    ctx = %{ctx | call_id: call_id}
    :ok = Checkpoint.capture(store, ctx, name, tool: "write")
    put(ctx.cwd, name, contents)
    :ok = Checkpoint.record_after(store, ctx, name)
  end

  defp git(work, args) do
    {output, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.com",
          "-c",
          "commit.gpgsign=false" | args
        ],
        cd: work,
        stderr_to_stdout: true
      )

    output
  end

  test "undo restores a changed file and deletes a created one", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    put(work, "a.txt", "original\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")

    agent_writes(store, ctx, "a.txt", "changed\n")
    agent_writes(store, ctx, "new/b.txt", "created\n", "c2")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.turn == 1
    assert report.restored == ["a.txt"]
    assert report.deleted == ["new/b.txt"]
    assert report.conflicts == []
    assert contents(work, "a.txt") == "original\n"
    refute File.exists?(Path.join(work, "new/b.txt"))
    # The directory the write made for it goes too.
    refute File.exists?(Path.join(work, "new"))
  end

  test "a file changed after the agent's write is a conflict, not overwritten", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    put(work, "a.txt", "original\n")
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "agent\n")
    put(work, "a.txt", "the person's own edit\n")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert [%{path: "a.txt", reason: reason}] = report.conflicts
    assert reason =~ "changed since"
    assert contents(work, "a.txt") == "the person's own edit\n"
  end

  test "force restores over a conflict", %{store: store, work: work, ctx: ctx} do
    put(work, "a.txt", "original\n")
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "agent\n")
    put(work, "a.txt", "later\n")

    assert {:ok, %{restored: ["a.txt"]}} = Checkpoint.undo(store, "s1", force: true)
    assert contents(work, "a.txt") == "original\n"
  end

  test "the earliest capture of a turn is what the file goes back to", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    put(work, "a.txt", "v0\n")
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "v1\n", "c1")
    agent_writes(store, ctx, "a.txt", "v2\n", "c2")

    assert {:ok, %{restored: ["a.txt"]}} = Checkpoint.undo(store, "s1")
    assert contents(work, "a.txt") == "v0\n"
  end

  test "turns undo newest first, and rewind undoes several", %{store: store, work: work, ctx: ctx} do
    put(work, "a.txt", "v0\n")

    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "v1\n", "c1")

    # A prompt that changed nothing does not use up a turn number.
    {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "v2\n", "c2")

    {:ok, 3} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "b.txt", "new\n", "c3")

    assert {:ok, [%{turn: 3, undone?: false}, %{turn: 2}, %{turn: 1}]} =
             Checkpoint.list(store, "s1")

    assert {:ok, %{turn: 3, deleted: ["b.txt"]}} = Checkpoint.undo(store, "s1")
    assert {:ok, [%{turn: 2}, %{turn: 1}]} = Checkpoint.rewind(store, "s1", 5)
    assert contents(work, "a.txt") == "v0\n"

    assert {:error, :nothing_to_undo} = Checkpoint.undo(store, "s1")
    assert {:error, :nothing_to_undo} = Checkpoint.rewind(store, "s1", 1)
    assert {:ok, [%{turn: 3, undone?: true} | _rest]} = Checkpoint.list(store, "s1")
  end

  test "a file too large to save is reported as unrestorable", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    put(work, "big.bin", String.duplicate("x", 100))
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.capture(store, ctx, "big.bin", max_file_bytes: 10)
    put(work, "big.bin", "small")
    :ok = Checkpoint.record_after(store, ctx, "big.bin")

    assert {:ok, %{unrestorable: [%{path: "big.bin", reason: reason}]}} =
             Checkpoint.undo(store, "s1")

    assert reason =~ "larger than 10 bytes"
    assert contents(work, "big.bin") == "small"
  end

  # The after-record is a digest at any size; one over the save limit used
  # to be "unavailable", which matched nothing, so undo called the agent's own
  # large file "changed since the agent wrote it" and kept it.
  test "a large file the agent created is deleted, not taken for somebody else's", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.capture(store, ctx, "big.bin")
    put(work, "big.bin", :binary.copy("x", 10_000_001))
    :ok = Checkpoint.record_after(store, ctx, "big.bin")

    assert {:ok, %{deleted: ["big.bin"], conflicts: []}} = Checkpoint.undo(store, "s1")
    refute File.exists?(Path.join(work, "big.bin"))
  end

  test "absolute paths inside the working directory are the same file", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    put(work, "a.txt", "v0\n")
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.capture(store, ctx, Path.join(work, "a.txt"))
    put(work, "a.txt", "v1\n")
    :ok = Checkpoint.record_after(store, ctx, "a.txt")

    assert {:ok, %{restored: ["a.txt"]}} = Checkpoint.undo(store, "s1")
    assert contents(work, "a.txt") == "v0\n"
  end

  test "paths outside the working directory and unsafe session ids are refused", %{
    store: store,
    ctx: ctx
  } do
    assert {:error, :outside_worktree} = Checkpoint.capture(store, ctx, "../escape.txt")
    assert {:error, {:invalid_session_id, "../x"}} = Checkpoint.begin_turn(store, "../x")
  end

  test "checkpoints are private files", %{store: store, work: work, ctx: ctx} do
    put(work, "secret.env", "TOKEN=1\n")
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.capture(store, ctx, "secret.env")

    [blob] = Path.wildcard(Path.join(store, "s1/blobs/*"))
    assert File.read!(blob) == "TOKEN=1\n"
    assert %File.Stat{mode: mode} = File.stat!(blob)
    assert Bitwise.band(mode, 0o077) == 0
  end

  test "forget deletes a session's checkpoints", %{store: store, work: work, ctx: ctx} do
    put(work, "a.txt", "x")
    :ok = Checkpoint.capture(store, ctx, "a.txt")
    assert File.dir?(Path.join(store, "s1"))
    assert :ok = Checkpoint.forget(store, "s1")
    refute File.exists?(Path.join(store, "s1"))
  end

  describe "git snapshots" do
    setup %{work: work} do
      git(work, ["init", "-q"])
      put(work, "tracked.txt", "v0\n")
      put(work, ".gitignore", "ignored/\n")
      git(work, ["add", "-A"])
      git(work, ["commit", "-qm", "init"])
      put(work, "staged.txt", "staged\n")
      git(work, ["add", "staged.txt"])
      :ok
    end

    test "undo reverts what a command changed and leaves the repository's own state alone", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      index = File.read!(Path.join(work, ".git/index"))
      status = git(work, ["status", "--porcelain"])
      refs = git(work, ["for-each-ref"])

      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      assert :ok = Checkpoint.snapshot(store, ctx, :before)

      # What a `bash` command might do: change a tracked file, create one,
      # delete one, and write inside an ignored directory.
      put(work, "tracked.txt", "by a command\n")
      put(work, "made.txt", "made\n")
      File.rm!(Path.join(work, "staged.txt"))
      put(work, "ignored/cache.bin", "cache")
      assert :ok = Checkpoint.snapshot(store, ctx, :after)

      assert File.read!(Path.join(work, ".git/index")) == index
      assert git(work, ["for-each-ref"]) == refs
      assert git(work, ["stash", "list"]) == ""

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert Enum.sort(report.restored) == ["staged.txt", "tracked.txt"]
      assert report.deleted == ["made.txt"]
      assert contents(work, "tracked.txt") == "v0\n"
      assert contents(work, "staged.txt") == "staged\n"
      refute File.exists?(Path.join(work, "made.txt"))
      assert contents(work, "ignored/cache.bin") == "cache"
      assert git(work, ["status", "--porcelain"]) == status
    end

    test "a file changed again after the command is a conflict", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "by a command\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)
      put(work, "tracked.txt", "by the person\n")

      assert {:ok, %{conflicts: [%{path: "tracked.txt"}], restored: []}} =
               Checkpoint.undo(store, "s1")

      assert contents(work, "tracked.txt") == "by the person\n"
    end

    test "a path a command changed before a file tool did goes back to the turn's start", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "by a command\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)
      agent_writes(store, ctx, "tracked.txt", "then by edit\n", "c2")

      assert {:ok, %{restored: ["tracked.txt"], deleted: [], conflicts: []}} =
               Checkpoint.undo(store, "s1")

      # The capture saw the command's version; the turn started at v0.
      assert contents(work, "tracked.txt") == "v0\n"
    end

    test "a file tool and then a command on one path go back without a false conflict", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      agent_writes(store, ctx, "tracked.txt", "by edit\n", "c1")
      ctx2 = %{ctx | call_id: "c2"}
      :ok = Checkpoint.snapshot(store, ctx2, :before)
      put(work, "tracked.txt", "then by a command\n")
      :ok = Checkpoint.snapshot(store, ctx2, :after)

      assert {:ok, %{restored: ["tracked.txt"], conflicts: []}} = Checkpoint.undo(store, "s1")
      assert contents(work, "tracked.txt") == "v0\n"
    end

    # The generator-then-edit pattern (phx.gen, rails g): the edited file did
    # not exist before the turn, so undo removes it rather than "restoring" the
    # generator's output.
    test "a generated file the agent then edited is deleted, with its directory", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "lib/gen.ex", "generated\n")
      put(work, "lib/gen_test.ex", "generated test\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)
      agent_writes(store, ctx, "lib/gen.ex", "generated, then edited\n", "c2")

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.restored == []
      assert Enum.sort(report.deleted) == ["lib/gen.ex", "lib/gen_test.ex"]
      assert report.conflicts == []
      refute File.exists?(Path.join(work, "lib"))
    end

    test "a file the person saves between two commands is not part of the turn", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      put(work, "other.txt", "v0\n")
      git(work, ["add", "other.txt"])
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")

      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "by the first command\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)

      # While the model thinks, the person saves their own file.
      put(work, "other.txt", "the person's edit\n")

      ctx2 = %{ctx | call_id: "c2"}
      :ok = Checkpoint.snapshot(store, ctx2, :before)
      :ok = Checkpoint.snapshot(store, ctx2, :after)

      assert {:ok, %{restored: ["tracked.txt"], conflicts: []}} = Checkpoint.undo(store, "s1")
      assert contents(work, "tracked.txt") == "v0\n"
      assert contents(work, "other.txt") == "the person's edit\n"
    end

    test "a command lmx never saw finish is reported, and the older turn is not undone", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, 1} = Checkpoint.begin_turn(store, "s1")
      agent_writes(store, ctx, "wanted.txt", "keep me\n", "c1")

      # Turn 2: lmx stopped while the command ran, so no after-tree exists.
      {:ok, 2} = Checkpoint.begin_turn(store, "s1")
      ctx2 = %{ctx | call_id: "c2"}
      :ok = Checkpoint.snapshot(store, ctx2, :before, subject: "`rm tracked.txt; sleep 120`")
      File.rm!(Path.join(work, "tracked.txt"))

      # The next prompt does not reuse the turn, so the stale before-tree
      # never stretches into it.
      assert {:ok, 3} = Checkpoint.begin_turn(store, "s1")

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.turn == 2
      assert report.restored == [] and report.deleted == []
      assert [%{subject: "`rm tracked.txt; sleep 120`", reason: reason}] = report.not_undone
      assert reason =~ "not recorded"
      assert report.next == 1

      # Nothing of turn 1 was touched by that answer; asking again undoes it.
      assert contents(work, "wanted.txt") == "keep me\n"
      assert {:ok, %{turn: 1, deleted: ["wanted.txt"]}} = Checkpoint.undo(store, "s1")
    end

    test "a watched command whose process is killed is closed by its watcher", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      parent = self()

      # What a cancelled tool task looks like from here: it took the
      # before-tree, the command changed a file, and it was killed.
      task =
        spawn(fn ->
          :ok = Checkpoint.snapshot(store, ctx, :before, watch: self())
          put(work, "tracked.txt", "by a cancelled command\n")
          send(parent, :changed)
          Process.sleep(:infinity)
        end)

      assert_receive :changed, 5_000
      Process.exit(task, :kill)

      assert {:ok, %{restored: ["tracked.txt"], not_undone: []}} = Checkpoint.undo(store, "s1")
      assert contents(work, "tracked.txt") == "v0\n"
    end

    # Turns recorded before commands had windows of their own: one
    # snapshot.json for the turn, and a captured path left to its capture.
    test "a turn recorded with one snapshot for all its commands still undoes", %{
      store: store,
      work: work
    } do
      {:ok, 1} = Checkpoint.begin_turn(store, "s1")
      {:ok, before} = Git.snapshot(work)
      put(work, "tracked.txt", "by a command\n")
      put(work, "made.txt", "made\n")
      {:ok, later} = Git.snapshot(work)

      :ok =
        Store.put_json(Path.join(store, "s1/turns/1/snapshot.json"), %{
          "before" => before.tree,
          "after" => later.tree,
          "root" => later.root,
          "prefix" => later.prefix,
          "cwd" => work
        })

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.restored == ["tracked.txt"]
      assert report.deleted == ["made.txt"]
      assert contents(work, "tracked.txt") == "v0\n"
      refute File.exists?(Path.join(work, "made.txt"))
    end

    test "a commit and a branch switch are reported and left where they are", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      git(work, ["checkout", "-q", "-b", "agent-wip"])
      put(work, "tracked.txt", "agent\n")
      git(work, ["commit", "-qam", "wip"])
      :ok = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.restored == ["tracked.txt"]
      assert contents(work, "tracked.txt") == "v0\n"
      assert [%{subject: "HEAD", reason: reason}] = report.not_undone
      assert reason =~ ~r/moved from \S+ \([0-9a-f]{7}\) to agent-wip \([0-9a-f]{7}\)/
      assert reason =~ "git reflog"
      assert String.trim(git(work, ["rev-parse", "--abbrev-ref", "HEAD"])) == "agent-wip"
    end

    test "ignored and large untracked files a command changed are named, not restored", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      put(work, ".gitignore", "ignored/\n.env\n")
      git(work, ["add", ".gitignore"])
      put(work, ".env", "TOKEN=1\n")
      put(work, "huge.dat", String.duplicate("z", 2_000))

      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      opts = [max_untracked_bytes: 1_000]
      :ok = Checkpoint.snapshot(store, ctx, :before, opts)
      put(work, ".env", "TOKEN=2\nEXTRA=1\n")
      File.rm!(Path.join(work, "huge.dat"))
      :ok = Checkpoint.snapshot(store, ctx, :after, opts)

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.restored == []
      reasons = Map.new(report.unrestorable, &{&1.path, &1.reason})
      assert reasons[".env"] =~ "changed while a command ran; git ignores it"

      assert reasons["huge.dat"] =~
               "deleted while a command ran; an untracked file over 1,000 bytes"

      assert contents(work, ".env") == "TOKEN=2\nEXTRA=1\n"
    end

    test "a mode a command changed is put back", %{store: store, work: work, ctx: ctx} do
      File.chmod!(Path.join(work, "tracked.txt"), 0o644)
      git(work, ["add", "tracked.txt"])
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      File.chmod!(Path.join(work, "tracked.txt"), 0o755)
      :ok = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, %{restored: ["tracked.txt"]}} = Checkpoint.undo(store, "s1")
      assert Bitwise.band(File.stat!(Path.join(work, "tracked.txt")).mode, 0o111) == 0
    end

    test "an ignored directory a command deleted is named", %{store: store, work: work, ctx: ctx} do
      put(work, "ignored/cache.bin", "cache")
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      File.rm_rf!(Path.join(work, "ignored"))
      :ok = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, %{unrestorable: [%{path: "ignored/", reason: reason}]}} =
               Checkpoint.undo(store, "s1")

      assert reason =~ "deleted while a command ran; git ignores it"
    end

    test "a working directory the repository ignores is noted, not snapshotted", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      put(work, "ignored/scratch/notes.txt", "keep me\n")
      ctx = %{ctx | cwd: Path.join(work, "ignored/scratch")}
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")

      assert {:error, :ignored_working_directory} =
               Checkpoint.snapshot(store, ctx, :before, subject: "`rm notes.txt`")

      assert {:ok, %{not_undone: [%{subject: "`rm notes.txt`", reason: reason}]}} =
               Checkpoint.undo(store, "s1")

      assert reason =~ "its git repository ignores"
    end

    test "a change outside the working directory is named, not restored", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      sub = Path.join(work, "sub")
      put(work, "sub/inner.txt", "inner\n")
      git(work, ["add", "sub/inner.txt"])
      ctx = %{ctx | cwd: sub}

      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "from inside sub\n")
      put(work, "sub/inner.txt", "changed\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.restored == ["inner.txt"]
      assert [%{path: "../tracked.txt", reason: reason}] = report.unrestorable
      assert reason =~ "outside the working directory"
      assert contents(work, "tracked.txt") == "from inside sub\n"
    end

    test "an undo can be taken back, and the turn undone again", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "by a command\n")
      put(work, "made.txt", "made\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, %{restored: ["tracked.txt"], deleted: ["made.txt"]}} =
               Checkpoint.undo(store, "s1")

      assert {:ok, %{action: :redo, restored: restored, conflicts: []}} =
               Checkpoint.redo(store, "s1")

      assert Enum.sort(restored) == ["made.txt", "tracked.txt"]
      assert contents(work, "tracked.txt") == "by a command\n"
      assert contents(work, "made.txt") == "made\n"
      assert {:error, :nothing_to_redo} = Checkpoint.redo(store, "s1")

      assert {:ok, %{turn: 1, restored: ["tracked.txt"]}} = Checkpoint.undo(store, "s1")
      assert contents(work, "tracked.txt") == "v0\n"
    end

    test "redo leaves a file changed since the undo alone", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before)
      put(work, "tracked.txt", "by a command\n")
      :ok = Checkpoint.snapshot(store, ctx, :after)
      assert {:ok, _report} = Checkpoint.undo(store, "s1")
      put(work, "tracked.txt", "the person's newer edit\n")

      assert {:ok, %{restored: [], conflicts: [%{path: "tracked.txt", reason: reason}]}} =
               Checkpoint.redo(store, "s1")

      assert reason =~ "changed since the undo"
      assert contents(work, "tracked.txt") == "the person's newer edit\n"
    end

    test "a large untracked file a command shrank says why it cannot go back", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      put(work, "data.csv", String.duplicate("z", 2_000))
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      opts = [max_untracked_bytes: 1_000]
      :ok = Checkpoint.snapshot(store, ctx, :before, opts)
      put(work, "data.csv", "small now\n")
      :ok = Checkpoint.snapshot(store, ctx, :after, opts)

      assert {:ok, %{restored: [], unrestorable: [%{path: "data.csv", reason: reason}]}} =
               Checkpoint.undo(store, "s1")

      assert reason ==
               "its contents before the command were not saved: an untracked file over " <>
                 "1,000 bytes, which undo does not save"

      assert contents(work, "data.csv") == "small now\n"
    end

    test "large untracked files are left out of the snapshot", %{
      store: store,
      work: work,
      ctx: ctx
    } do
      put(work, "huge.dat", String.duplicate("z", 2_000))
      {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
      :ok = Checkpoint.snapshot(store, ctx, :before, max_untracked_bytes: 1_000)
      File.rm!(Path.join(work, "huge.dat"))
      :ok = Checkpoint.snapshot(store, ctx, :after, max_untracked_bytes: 1_000)

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      refute "huge.dat" in report.restored
      refute File.exists?(Path.join(work, "huge.dat"))
    end
  end

  describe "outside a git repository" do
    setup do
      # ExUnit's tmp_dir lives inside this repository's ignored tmp/, which git
      # would happily call a work tree; the system temporary directory is not one.
      outside =
        Path.join(System.tmp_dir!(), "lemieux-checkpoint-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      %{outside: outside}
    end

    test "a command gets no snapshot, and undo says it could not record it", %{
      store: store,
      ctx: ctx,
      outside: outside
    } do
      ctx = %{ctx | cwd: outside}
      File.write!(Path.join(outside, "notes.txt"), "keep me\n")
      {:ok, 1} = Checkpoint.begin_turn(store, "s1")

      assert :skipped = Checkpoint.snapshot(store, ctx, :before, subject: "`rm notes.txt`")
      File.rm!(Path.join(outside, "notes.txt"))
      assert :skipped = Checkpoint.snapshot(store, ctx, :after)

      assert {:ok, report} = Checkpoint.undo(store, "s1")
      assert report.turn == 1
      assert report.restored == [] and report.deleted == []
      assert [%{subject: "`rm notes.txt`", reason: reason}] = report.not_undone
      assert reason =~ "only in a git repository"
      assert report.next == nil
    end

    test "a turn that only ran unrecorded commands is not reused by the next prompt", %{
      store: store,
      ctx: ctx,
      outside: outside
    } do
      ctx = %{ctx | cwd: outside}
      {:ok, 1} = Checkpoint.begin_turn(store, "s1")
      assert :skipped = Checkpoint.snapshot(store, ctx, :before)
      assert {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    end
  end

  test "an unrecorded effect is reported with its turn", %{store: store, work: work, ctx: ctx} do
    put(work, "a.txt", "v0\n")
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, ctx, "a.txt", "v1\n")

    assert :ok =
             Checkpoint.mark_unrecorded(store, ctx, "mcp__fs__write", "an MCP server's tool")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.restored == ["a.txt"]
    assert report.not_undone == [%{subject: "mcp__fs__write", reason: "an MCP server's tool"}]
  end

  test "around/4 records what a function changed and passes its result through", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    git(work, ["init", "-q"])
    put(work, "lock.txt", "locked v0\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")

    assert :checked =
             Checkpoint.around(store, Map.delete(ctx, :call_id), fn ->
               put(work, "lock.txt", "locked v1\n")
               :checked
             end)

    assert {:ok, %{restored: ["lock.txt"]}} = Checkpoint.undo(store, "s1")
    assert contents(work, "lock.txt") == "locked v0\n"
  end

  test "a store that cannot be written says so instead of nothing to undo", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    File.mkdir_p!(store)
    File.chmod!(store, 0o555)
    on_exit(fn -> File.chmod(store, 0o755) end)

    put(work, "a.txt", "v0\n")
    assert {:error, _reason} = Checkpoint.capture(store, ctx, "a.txt")

    expanded = Path.expand(store)
    assert {:error, {:unwritable, ^expanded}} = Checkpoint.undo(store, "s1")
  end

  test "commands are named by their first line, shortened" do
    assert Checkpoint.subject("rm notes.txt") == "`rm notes.txt`"
    assert Checkpoint.subject("cat <<EOF > x\nhello\nEOF") == "`cat <<EOF > x…`"
    assert Checkpoint.subject(String.duplicate("a", 100)) == "`#{String.duplicate("a", 60)}…`"
  end
end
