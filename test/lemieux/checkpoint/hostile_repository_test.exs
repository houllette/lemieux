defmodule Lemieux.Checkpoint.HostileRepositoryTest do
  # Checkpoints run git on this machine, outside the sandbox, in a repository
  # the agent's commands can write — `.git/config` included. Each repository
  # here is armed the way a sandboxed command could arm it: a
  # `core.fsmonitor`, a clean and a smudge filter, a `core.worktree` aimed at
  # the home directory. Every program it names leaves a marker when it runs,
  # and none may: the next snapshot, undo, redo or startup probe used to run
  # them here, unconfined (2026-10).
  use ExUnit.Case, async: true

  alias Lemieux.A2A.Server
  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Conversation.Doctor
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Extensions.Delegation
  alias Lemieux.Extensions.EnvironmentContext
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Markers and the programs that leave them live outside `tmp_dir`, whose
    # name carries the test's, and with it whatever quoting a test name
    # holds, which a shell script would trip over.
    traps =
      Path.join(System.tmp_dir!(), "lmx-hostile-#{System.unique_integer([:positive])}")

    File.mkdir_p!(traps)
    on_exit(fn -> File.rm_rf!(traps) end)

    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q"])
    put(work, "plain.md", "plain v0\n")
    put(work, "secret.txt", "secret v0\n")
    put(work, ".gitattributes", "*.txt filter=evil\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])
    # Untracked, and named by the filter attribute too.
    put(work, "scratch.txt", "scratch v0\n")

    %{
      traps: traps,
      work: work,
      store: Path.join(tmp_dir, "checkpoints"),
      ctx: %{
        cwd: work,
        session_id: "s1",
        call_id: "c1",
        environment: Lemieux.Environment.local()
      }
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

  defp read(work, name), do: File.read!(Path.join(work, name))

  # A program that leaves `marker` and then does what git expects of it:
  # `body` is the rest of the script.
  defp trap(traps, name, body) do
    script = Path.join(traps, name <> ".sh")
    File.write!(script, "#!/bin/sh\ntouch '#{Path.join(traps, name)}'\n" <> body)
    File.chmod!(script, 0o755)
    script
  end

  # What a sandboxed command can write into `.git/config` with nothing but
  # write access to the working tree. Set after the fixture's own commits,
  # which would otherwise run it themselves. The filters pass content
  # through, so nothing but the marker says they ran.
  defp arm!(%{traps: traps, work: work}) do
    git(work, ["config", "core.fsmonitor", trap(traps, "fsmonitor", "exit 1\n")])
    git(work, ["config", "filter.evil.clean", trap(traps, "clean", "exec cat\n")])
    git(work, ["config", "filter.evil.smudge", trap(traps, "smudge", "exec cat\n")])
    git(work, ["config", "filter.evil.required", "true"])
  end

  defp ran(traps),
    do: Enum.filter(~w(fsmonitor clean smudge), &File.exists?(Path.join(traps, &1)))

  # Stat data that no longer matches the index, as after any editor's save:
  # what makes a plain `git status` or `git add` re-read the file through its
  # clean filter.
  defp touch_later(work, name) do
    File.touch!(Path.join(work, name), System.os_time(:second) + 5)
  end

  # Git has run a `core.fsmonitor` that names a program since 2.16; an older
  # one never would, and the control below would fail for that reason alone.
  @fsmonitor_hook? (case System.cmd("git", ["--version"]) do
                      {version, 0} ->
                        [major, minor] =
                          Regex.run(~r/(\d+)\.(\d+)/, version, capture: :all_but_first)

                        {String.to_integer(major), String.to_integer(minor)} >= {2, 16}

                      _no_git ->
                        false
                    end)

  # The control for every `ran(traps) == []` below: the same arming, under
  # plain git, does run all three programs. Without it a fixture mistake, or a
  # git that stopped honouring one of the settings, would leave every other
  # test here green while proving nothing.
  unless @fsmonitor_hook?, do: @tag(skip: "this git does not run a core.fsmonitor program")

  test "the armed repository runs every trap under plain git", context do
    %{work: work, traps: traps} = context
    arm!(context)
    touch_later(work, "secret.txt")

    git(work, ["status", "--short"])
    git(work, ["add", "-A"])
    assert "fsmonitor" in ran(traps)
    assert "clean" in ran(traps)

    put(work, "secret.txt", "changed\n")
    git(work, ["checkout", "--", "secret.txt"])
    assert ran(traps) == ~w(fsmonitor clean smudge)
    assert read(work, "secret.txt") == "secret v0\n"
  end

  test "a whole command cycle — snapshots, undo, redo — runs nothing the repository names",
       context do
    %{store: store, work: work, ctx: ctx, traps: traps} = context
    arm!(context)
    touch_later(work, "secret.txt")

    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    assert :ok = Checkpoint.snapshot(store, ctx, :before)

    # What a `bash` command might do.
    put(work, "plain.md", "plain by a command\n")
    put(work, "made.md", "made by a command\n")
    put(work, "secret.txt", "secret by a command\n")
    put(work, "scratch.txt", "scratch by a command\n")
    assert :ok = Checkpoint.snapshot(store, ctx, :after)

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert report.restored == ["plain.md"]
    assert report.deleted == ["made.md"]
    assert read(work, "plain.md") == "plain v0\n"
    refute File.exists?(Path.join(work, "made.md"))

    # What a filter would have to produce is named, never written without it.
    unrestorable = Map.new(report.unrestorable, &{&1.path, &1.reason})
    assert unrestorable["secret.txt"] =~ "filter"
    assert unrestorable["scratch.txt"] =~ "filter"
    assert read(work, "secret.txt") == "secret by a command\n"
    assert read(work, "scratch.txt") == "scratch by a command\n"

    assert {:ok, redo} = Checkpoint.redo(store, "s1")
    assert Enum.sort(redo.restored) == ["made.md", "plain.md"]
    assert read(work, "plain.md") == "plain by a command\n"
    assert read(work, "made.md") == "made by a command\n"

    assert ran(traps) == []
  end

  # The window the post-edit check runs in (`Lemieux.Extensions.Verify`
  # with `:checkpoints`) is the same machinery.
  test "a function bracketed by around/4 is recorded and undone without running any of it",
       context do
    %{store: store, work: work, ctx: ctx, traps: traps} = context
    arm!(context)
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")

    assert :checked =
             Checkpoint.around(store, ctx, fn ->
               put(work, "plain.md", "plain by the check\n")
               :checked
             end)

    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.undo(store, "s1")
    assert read(work, "plain.md") == "plain v0\n"
    assert ran(traps) == []
  end

  test "an agent's bash call, through the extension, is undone without running any of it",
       context do
    %{work: work, store: checkpoints, traps: traps, tmp_dir: tmp_dir} = context
    arm!(context)
    runtime = :"lemieux_hostile_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, harness} =
      Harness.assemble(Harness.new(tools: [Tools.Bash]), [
        {Checkpoints, dir: checkpoints, git: true}
      ])

    command = "printf 'plain by bash\\n' > plain.md && touch secret.txt"

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider:
          Scripted.new([
            Scripted.tool_call("t1", "bash", %{"command" => command}),
            Scripted.complete("done")
          ]),
        store: JSONL.new(Path.join(tmp_dir, "sessions")),
        model: "test:model",
        subscriber: self(),
        harness: harness,
        cwd: work
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "change it")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 10_000
    assert read(work, "plain.md") == "plain by bash\n"

    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.undo(checkpoints, id)
    assert read(work, "plain.md") == "plain v0\n"
    assert ran(traps) == []
  end

  test "an fsmonitor alone is never started, and undo still restores", context do
    %{store: store, work: work, ctx: ctx, traps: traps} = context
    git(work, ["config", "core.fsmonitor", trap(traps, "fsmonitor", "exit 1\n")])

    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.snapshot(store, ctx, :before)
    put(work, "plain.md", "plain by a command\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)

    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.undo(store, "s1")
    assert read(work, "plain.md") == "plain v0\n"
    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.redo(store, "s1")
    assert read(work, "plain.md") == "plain by a command\n"
    assert ran(traps) == []
  end

  test "the repository's own index, refs and lock files are left alone", context do
    %{store: store, work: work, ctx: ctx} = context
    arm!(context)
    index = File.read!(Path.join(work, ".git/index"))

    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.snapshot(store, ctx, :before)
    put(work, "plain.md", "plain by a command\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)
    {:ok, _report} = Checkpoint.undo(store, "s1")

    assert File.read!(Path.join(work, ".git/index")) == index
    refute File.exists?(Path.join(work, ".git/index.lock"))
    # Each private directory is removed when its run ends.
    assert Path.wildcard(Path.join([store, "s1", "git", "*"])) == []
  end

  test "the startup probes run nothing the repository names", context do
    %{work: work, traps: traps} = context
    arm!(context)
    touch_later(work, "secret.txt")
    put(work, "plain.md", "plain, edited\n")

    assert Doctor.undo_coverage(work) == :commands
    {:ok, state} = EnvironmentContext.init(cwd: work, now: ~N[2026-10-04 12:00:00])
    assert ran(traps) == []

    # The tree's state is still read right: the edit, the untracked file,
    # and not the file whose stat changed while its contents did not.
    assert state.block =~ "uncommitted changes when the session started"
    assert state.block =~ " M plain.md"
    assert state.block =~ "?? scratch.txt"
    refute state.block =~ "secret.txt"

    assert {:ok, status} = Git.status(work)
    assert status =~ " M plain.md"
    assert ran(traps) == []
  end

  # A populated submodule has a git directory and a configuration of its
  # own, which a sandboxed command writes as easily — or makes, with `git
  # add` of a nested repository. `git add --update` asked each one whether
  # its work tree was dirty by running git inside it, under that
  # configuration.
  test "a submodule's own configuration runs nothing either", context do
    %{store: store, work: work, ctx: ctx, traps: traps, tmp_dir: tmp_dir} = context
    library = Path.join(tmp_dir, "library")
    File.mkdir_p!(library)
    git(library, ["init", "-q"])
    put(library, "lib.ex", "library v0\n")
    git(library, ["add", "-A"])
    git(library, ["commit", "-qm", "init"])
    git(work, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "vendor"])
    git(work, ["commit", "-qm", "vendor"])

    vendor = Path.join(work, "vendor")
    git(vendor, ["config", "core.fsmonitor", trap(traps, "fsmonitor", "exit 1\n")])
    git(vendor, ["config", "filter.evil.clean", trap(traps, "clean", "exec cat\n")])
    put(vendor, ".gitattributes", "* filter=evil\n")
    touch_later(vendor, "lib.ex")

    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.snapshot(store, ctx, :before)
    put(work, "plain.md", "plain by a command\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)

    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.undo(store, "s1")
    assert read(work, "plain.md") == "plain v0\n"
    assert ran(traps) == []

    {:ok, _state} = EnvironmentContext.init(cwd: work, now: ~N[2026-10-04 12:00:00])
    assert {:ok, _status} = Git.status(work)
    assert ran(traps) == []
  end

  # `core.worktree` in the repository's own configuration names the
  # directory git takes for the work tree. Every snapshot hands git its work
  # tree and git directory explicitly; aimed at the home directory, it would
  # add the home directory's small untracked files — credentials among them
  # — to the repository's object store, where the command that wrote the
  # setting reads them back with `git cat-file`. (The old snapshot found the
  # repository from that directory instead, and so wrote a home directory
  # kept in git, dotfiles and all, into that one's objects.) Outside every
  # repository: inside this checkout's ignored `tmp/`, the checkout's own
  # ignore rules would answer for the home directory.
  test "a work tree set to another directory is refused, and nothing of it is stored",
       %{store: store} do
    home = Path.join(System.tmp_dir!(), "lmx-hostile-home-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(home) end)
    project = Path.join(home, "project")
    File.mkdir_p!(project)
    git(project, ["init", "-q"])
    put(project, "app.ex", "app\n")
    git(project, ["add", "-A"])
    git(project, ["commit", "-qm", "init"])

    key = "-----BEGIN OPENSSH PRIVATE KEY----- #{System.unique_integer()}\n"
    put(home, ".ssh/id_ed25519", key)
    git(project, ["config", "core.worktree", home])

    ctx = %{cwd: project, session_id: "s1", call_id: "c1"}
    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    assert {:error, :foreign_work_tree} = Checkpoint.snapshot(store, ctx, :before)

    blob = :sha |> :crypto.hash("blob #{byte_size(key)}\0" <> key) |> Base.encode16(case: :lower)
    {prefix, rest} = String.split_at(blob, 2)
    refute File.exists?(Path.join([project, ".git/objects", prefix, rest]))

    assert {:ok, %{not_undone: [%{reason: reason}]}} = Checkpoint.undo(store, "s1")
    assert reason =~ "work tree"

    assert Doctor.undo_coverage(project) ==
             {:file_tools, "the git repository's work tree is set to another directory"}
  end

  # An index entry git does not know, added to `.git/index` (which a
  # sandboxed command can write), makes every git that reads the index warn
  # `ignoring ZZZZ extension` on standard error. Joined to the answer, the
  # warning made the first entry of `ls-files --stage` unreadable, and a
  # submodule sorted first went unnoticed: `add --update` then ran git in
  # it, under its own configuration.
  test "a warning git prints hides no submodule from a snapshot", context do
    %{store: store, work: work, ctx: ctx, traps: traps, tmp_dir: tmp_dir} = context
    library = Path.join(tmp_dir, "library")
    File.mkdir_p!(library)
    git(library, ["init", "-q"])
    put(library, "lib.ex", "library v0\n")
    git(library, ["add", "-A"])
    git(library, ["commit", "-qm", "init"])
    # `+` sorts before every other name here, `.gitattributes` included.
    git(work, ["-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "+vendor"])
    git(work, ["commit", "-qm", "vendor"])
    assert git(work, ["ls-files", "--stage"]) =~ ~r/\A160000 \S+ 0\t\+vendor\n/

    vendor = Path.join(work, "+vendor")
    git(vendor, ["config", "core.fsmonitor", trap(traps, "fsmonitor", "exit 1\n")])
    touch_later(vendor, "lib.ex")
    add_unknown_index_extension!(Path.join(work, ".git/index"))
    assert git(work, ["ls-files", "--stage"]) =~ "ignoring ZZZZ extension"

    {:ok, _turn} = Checkpoint.begin_turn(store, "s1")
    assert :ok = Checkpoint.snapshot(store, ctx, :before)
    put(work, "plain.md", "plain by a command\n")
    assert :ok = Checkpoint.snapshot(store, ctx, :after)

    assert ran(traps) == []

    assert {:ok, %{restored: ["plain.md"]}} = Checkpoint.undo(store, "s1")
    assert read(work, "plain.md") == "plain v0\n"
    assert {:ok, "## " <> _branch} = Git.status(work)
    assert ran(traps) == []
  end

  # Git's index file: a header, the entries, the extensions — each a
  # four-letter name and a length — and a SHA-1 of all of it. A name that
  # starts with a capital letter is one git may ignore, and says so.
  defp add_unknown_index_extension!(index) do
    body = index |> File.read!() |> binary_part(0, File.stat!(index).size - 20)
    body = body <> "ZZZZ" <> <<0::32>>
    File.write!(index, body <> :crypto.hash(:sha, body))
  end

  # A ref named `HEAD`, which a command can write as a file, makes git warn
  # `refname 'HEAD' is ambiguous` before it answers. The revision an A2A
  # task and a delegation report was the whole answer, warnings first, and
  # the startup status counted the warnings as changes.
  test "what hosts report of the repository is git's answer alone", context do
    %{work: work, traps: traps, tmp_dir: tmp_dir} = context
    head = work |> git(["rev-parse", "HEAD"]) |> String.trim()
    arm!(context)
    File.write!(Path.join(work, ".git/refs/heads/HEAD"), head <> "\n")
    # A clean tree, so that only a warning could read as a change.
    File.rm!(Path.join(work, "scratch.txt"))

    assert Git.revision(work) == {:ok, head}
    assert Git.revision(Path.join(tmp_dir, "nowhere")) == :none

    {:ok, delegation} =
      Delegation.init(cwd: work, model: "test:model", priced?: false)

    assert delegation.snapshot["revision"] == head

    {:ok, state} = EnvironmentContext.init(cwd: work, now: ~N[2026-10-04 12:00:00])
    assert state.block =~ "no uncommitted changes when the session started"
    refute state.block =~ "ambiguous"

    runtime = :"lemieux_hostile_a2a_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    server =
      start_supervised!(
        {Server,
         server_name: nil,
         supervisor: runtime,
         provider: Scripted.new([Scripted.complete("answered")]),
         model: "test:model",
         cwd: work,
         store: JSONL.new(Path.join(tmp_dir, "a2a"))}
      )

    assert {:ok, task} = Server.ask("which revision?", server: server)

    assert task.metadata["lemieux"]["source"] == %{
             "kind" => "working_tree",
             "revision" => head,
             "dirty" => false
           }

    assert ran(traps) == []
  end

  # `-c` splits what it is given at the first `=`, and a configuration
  # section's subsection may hold one: a key read from the repository with
  # one in it would reach the private directory as another key.
  test "a setting whose name -c cannot pass on as itself is not passed on", %{work: work} do
    branch = work |> git(["symbolic-ref", "--short", "HEAD"]) |> String.trim()
    git(work, ["config", "branch.#{branch}.remote", "a=b"])
    git(work, ["config", "remote.a=b.fetch", "+refs/heads/*:refs/remotes/ab/*"])
    git(work, ["config", "core.autocrlf", "false"])

    {:ok, repository} = Git.Repository.locate(work)
    settings = Git.Repository.settings(repository, :status)

    assert {"core.autocrlf", "false"} in settings
    assert {"branch.#{branch}.remote", "a=b"} in settings
    assert Enum.filter(settings, fn {key, _value} -> key =~ "=" end) == []
  end
end
