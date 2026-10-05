defmodule Lemieux.Checkpoint.GitTest do
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint.Git

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q"])
    %{work: work}
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

  defp put(work, name, contents) do
    path = Path.join(work, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # Git trusts an index entry's cached stat when the entry is older than the
  # index file. These tests commit and rewrite a file within one second, then
  # act in a later one: the state in which a copied index, stamped "now",
  # made git take the rewritten file for the committed one.
  defp commit_then_rewrite_in_the_same_second(work) do
    millisecond = rem(System.os_time(:millisecond), 1000)
    if millisecond > 300, do: Process.sleep(1000 - millisecond + 5)

    put(work, "config.exs", "port: 4000\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    # In place and the same size, so inode and size match the index entry.
    put(work, "config.exs", "port: 4001\n")
    Process.sleep(1_100)
    tree
  end

  test "restore writes a file rewritten in the second its index entry was made", %{work: work} do
    tree = commit_then_rewrite_in_the_same_second(work)

    assert Git.restore(work, tree, ["config.exs"]) == {:ok, %{}}
    assert File.read!(Path.join(work, "config.exs")) == "port: 4000\n"
  end

  test "a snapshot sees a file rewritten in the second its index entry was made", %{work: work} do
    committed = commit_then_rewrite_in_the_same_second(work)

    assert {:ok, snapshot} = Git.snapshot(work)
    assert {:ok, [{:modified, "config.exs"}]} = Git.changed(work, committed, snapshot.tree)
  end

  test "restore refuses a path the tree does not have, and writes one it has", %{work: work} do
    put(work, "a.txt", "a\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    put(work, "a.txt", "changed\n")

    # A path the tree does not have cannot come out as the tree has it.
    assert {:ok, %{"missing.txt" => reason}} = Git.restore(work, tree, ["missing.txt"])
    assert reason =~ "git restore failed"
    assert Git.restore(work, tree, ["a.txt"]) == {:ok, %{}}
    assert File.read!(Path.join(work, "a.txt")) == "a\n"
  end

  test "a path is a name, never a pattern", %{work: work} do
    put(work, "a[1].txt", "bracketed\n")
    put(work, "a1.txt", "plain\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    put(work, "a[1].txt", "changed\n")
    put(work, "a1.txt", "the person's edit\n")

    assert Git.restore(work, tree, ["a[1].txt"]) == {:ok, %{}}
    assert File.read!(Path.join(work, "a[1].txt")) == "bracketed\n"
    assert File.read!(Path.join(work, "a1.txt")) == "the person's edit\n"
  end

  test "a file named check-ignore does not turn patterns back on for its batch", %{work: work} do
    put(work, "check-ignore", "named after a git command\n")
    put(work, "a[1].txt", "bracketed\n")
    put(work, "a1.txt", "plain\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    put(work, "check-ignore", "changed\n")
    put(work, "a[1].txt", "changed\n")
    put(work, "a1.txt", "the person's edit\n")

    assert Git.restore(work, tree, ["check-ignore", "a[1].txt"]) == {:ok, %{}}
    assert File.read!(Path.join(work, "a1.txt")) == "the person's edit\n"
  end

  # Paths go to git a hundred at a time. One batch failing used to mark every
  # path "git restore failed", the ones an earlier batch wrote included.
  test "a batch that fails is reported for its paths alone", %{work: work} do
    names = for n <- 1..100, do: "f#{String.pad_leading("#{n}", 3, "0")}.txt"
    Enum.each(names, &put(work, &1, "v0\n"))
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    Enum.each(names, &put(work, &1, "changed\n"))

    assert {:ok, unwritten} = Git.restore(work, tree, names ++ ["missing.txt"])
    assert Map.keys(unwritten) == ["missing.txt"]
    assert Enum.all?(names, &(File.read!(Path.join(work, &1)) == "v0\n"))
  end

  test "a snapshot names the directories git does not track, empty ones included", %{
    work: work
  } do
    put(work, "tracked.txt", "t\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    File.mkdir_p!(Path.join(work, "uploads"))
    put(work, "newdir/sub/b.txt", "b\n")

    assert {:ok, snapshot} = Git.snapshot(work)
    assert Enum.sort(snapshot.dirs) == ["newdir/", "uploads/"]
    assert snapshot.dirs_more == 0
    # The files inside an untracked directory are still added one by one.
    assert {:ok, %{"newdir/sub/b.txt" => blob}} =
             Git.blobs(work, snapshot.tree, ["newdir/sub/b.txt"])

    assert is_binary(blob)
  end

  test "a symbolic link is hashed as git stores it, not through its target", %{work: work} do
    put(work, "target.txt", "target\n")
    File.ln_s!("target.txt", Path.join(work, "link"))
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    assert {:ok, stored} = Git.blobs(work, tree, ["link", "target.txt"])
    assert {:ok, now} = Git.worktree_blobs(work, ["link", "target.txt", "absent"])
    assert now["link"] == stored["link"]
    assert now["target.txt"] == stored["target.txt"]
    assert now["link"] != now["target.txt"]
    assert now["absent"] == nil
  end

  test "a snapshot adds untracked links and notes what it leaves out", %{work: work} do
    put(work, ".gitignore", ".env\n_build/\n")
    put(work, "small.txt", "small\n")
    put(work, "big.bin", String.duplicate("b", 50))
    put(work, ".env", "TOKEN=1\n")
    put(work, "_build/x", "inside an ignored directory\n")
    File.ln_s!("small.txt", Path.join(work, "link"))

    assert {:ok, snapshot} = Git.snapshot(work, max_untracked_bytes: 20)
    assert {:ok, blobs} = Git.blobs(work, snapshot.tree, ["small.txt", "link", "big.bin", ".env"])
    assert blobs["small.txt"] && blobs["link"]
    assert blobs["big.bin"] == nil and blobs[".env"] == nil

    unsaved = Map.new(snapshot.unsaved, &{&1.path, &1.why})
    assert unsaved == %{"big.bin" => :large, ".env" => :ignored, "_build/" => :ignored}
    assert snapshot.unsaved_more == 0
  end

  test "untracked files past the limit are noted as left out", %{work: work} do
    for name <- ~w(a b c), do: put(work, "#{name}.txt", name)

    assert {:ok, snapshot} = Git.snapshot(work, max_untracked_files: 2)
    assert [%{path: "c.txt", why: :beyond_limit}] = snapshot.unsaved
  end

  # A directory git does not track at all — a dataset — counts after the new
  # files beside tracked ones, whatever their names.
  test "a bulk untracked directory does not push a new file out of the limit", %{work: work} do
    put(work, "lib/app.ex", "app\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    for name <- ~w(a b c), do: put(work, "data/#{name}.csv", name)
    put(work, "lib/zz_new.ex", "new\n")

    assert {:ok, snapshot} = Git.snapshot(work, max_untracked_files: 2)
    assert {:ok, %{"lib/zz_new.ex" => blob}} = Git.blobs(work, snapshot.tree, ["lib/zz_new.ex"])
    assert is_binary(blob)

    assert Enum.map(snapshot.unsaved, &{&1.path, &1.why}) == [
             {"data/b.csv", :beyond_limit},
             {"data/c.csv", :beyond_limit}
           ]
  end

  test "a snapshot records HEAD and a digest of the refs", %{work: work} do
    assert {:ok, %{head: %{commit: nil, branch: branch}}} = Git.snapshot(work)
    assert is_binary(branch)

    put(work, "a.txt", "a\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    assert {:ok, first} = Git.snapshot(work)
    commit = work |> git(["rev-parse", "HEAD"]) |> String.trim()
    assert first.head == %{commit: commit, branch: branch}

    git(work, ["branch", "other"])
    assert {:ok, second} = Git.snapshot(work)
    assert second.head == first.head
    assert second.refs != first.refs

    git(work, ["checkout", "-q", "--detach"])
    assert {:ok, %{head: %{commit: ^commit, branch: nil}}} = Git.snapshot(work)
  end

  test "the directories a tree contains", %{work: work} do
    put(work, "lib/deep/a.ex", "a\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    tree = work |> git(["rev-parse", "HEAD^{tree}"]) |> String.trim()

    assert {:ok, directories} = Git.directories(work, tree)
    assert MapSet.equal?(directories, MapSet.new(["lib", "lib/deep"]))
  end

  test "a directory that is not a repository is skipped" do
    outside = Path.join(System.tmp_dir!(), "lmx-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    assert :skipped = Git.snapshot(outside)
  end
end
