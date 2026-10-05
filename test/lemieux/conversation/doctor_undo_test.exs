defmodule Lemieux.Conversation.DoctorUndoTest do
  # What `/doctor` says `/undo` covers, and the rule behind it that the
  # terminal UI's startup notice and `lmx run` share: commands are recorded
  # only in a git work tree, and not in a directory its repository ignores.
  use ExUnit.Case, async: true

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Conversation.Doctor
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Outside every repository: the test's own directory is inside this
    # checkout, whose ignore rules would answer for it instead.
    outside =
      Path.join(System.tmp_dir!(), "lmx-doctor-undo-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, "scratch"))
    File.mkdir_p!(Path.join(repo, "lib"))
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: repo, stderr_to_stdout: true)
    File.write!(Path.join(repo, ".gitignore"), "scratch/\n")

    %{outside: outside, repo: repo, checkpoints: Path.join(tmp_dir, "checkpoints")}
  end

  describe "undo_coverage/1" do
    test "outside a git repository only the file tools are recorded", %{outside: outside} do
      assert Doctor.undo_coverage(outside) == {:file_tools, "not a git repository"}
    end

    test "in a git repository, and in a directory of it, commands are recorded too", context do
      assert Doctor.undo_coverage(context.repo) == :commands
      assert Doctor.undo_coverage(Path.join(context.repo, "lib")) == :commands
    end

    # The snapshot refuses a directory its repository ignores: nothing in it
    # ever reaches a tree, so every command's change there is invisible.
    test "a directory the repository ignores records only the file tools", %{repo: repo} do
      assert Doctor.undo_coverage(Path.join(repo, "scratch")) ==
               {:file_tools, "the git repository ignores this directory"}
    end

    test "a directory that does not exist is no repository", %{outside: outside} do
      assert Doctor.undo_coverage(Path.join(outside, "gone")) ==
               {:file_tools, "not a git repository"}
    end

    # The terminal UI asks as a sitting opens, before anything is typed:
    # `check-ignore` in a subdirectory used to run the program the
    # repository's `core.fsmonitor` names, twice (git 2.56). The hook lives
    # outside `tmp_dir`, whose name carries the test's and so whatever
    # quoting a test name holds, which a shell script would trip over.
    test "runs nothing the repository configures", context do
      log = Path.join(context.outside, "fsmonitor.log")
      hook = Path.join(context.outside, "fsmonitor.sh")
      File.write!(hook, "#!/bin/sh\necho ran >> '#{log}'\nexit 1\n")
      File.chmod!(hook, 0o755)

      {_output, 0} =
        System.cmd("git", ["-C", context.repo, "config", "core.fsmonitor", hook],
          stderr_to_stdout: true
        )

      assert Doctor.undo_coverage(Path.join(context.repo, "lib")) == :commands

      assert Doctor.undo_coverage(Path.join(context.repo, "scratch")) ==
               {:file_tools, "the git repository ignores this directory"}

      refute File.exists?(log)
    end

    # A repository on a hung mount must cost the answer, not the screen that
    # asked; past the deadline nothing is claimed either way.
    test "past its deadline the answer is unknown, and the row states the rule", context do
      assert Doctor.undo_coverage(context.outside, timeout_ms: 0) == :unknown

      assert Doctor.format(%{checkpoints: "/home/a/.lmx/checkpoints", undo: :unknown}) =~
               "file tools, and commands in a git repository · /undo, /rewind, /redo"
    end
  end

  describe "undo_notice/1" do
    test "says once what /undo covers where commands are not recorded", context do
      assert Doctor.undo_notice(context.outside) ==
               "/undo covers file-tool edits only here: not a git repository, " <>
                 "so what commands change is not recorded"

      assert Doctor.undo_notice(context.repo) == nil
    end
  end

  describe "the checkpoints row" do
    test "says what /undo covers, and names /redo" do
      covered = Doctor.format(%{checkpoints: "/home/a/.lmx/checkpoints", undo: :commands})

      assert covered =~
               "checkpoints  /home/a/.lmx/checkpoints · file tools, and commands in a git " <>
                 "repository · /undo, /rewind, /redo"

      refute covered =~ "put files back"

      only =
        Doctor.format(%{
          checkpoints: "/home/a/.lmx/checkpoints",
          undo: {:file_tools, "not a git repository"}
        })

      assert only =~ "file tools only: not a git repository · /undo, /rewind, /redo"
    end

    test "off is still off" do
      assert Doctor.format(%{checkpoints: nil}) =~
               "checkpoints  off · /undo has nothing to put back"
    end
  end

  describe "gather/1" do
    setup do
      runtime = :"lemieux_doctor_undo_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      %{runtime: runtime}
    end

    test "asks about the session's directory, where checkpoints are on", context do
      assert %{undo: {:file_tools, "not a git repository"}} =
               Doctor.gather(host(nil, checkpoints: context.checkpoints, cwd: context.outside))

      assert %{undo: :commands} =
               Doctor.gather(host(nil, checkpoints: context.checkpoints, cwd: context.repo))

      assert %{undo: nil} = Doctor.gather(host(nil, checkpoints: nil, cwd: context.outside))
    end

    # The extension's own description, which the session keeps, says whether
    # it records commands at all: without `git: true` it never does, in a
    # repository or not.
    test "a host that records only the file tools is reported as such", context do
      without_git = session(context, git: false)

      assert %{undo: {:file_tools, "this host does not record commands"}} =
               Doctor.gather(
                 host(without_git, checkpoints: context.checkpoints, cwd: context.repo)
               )

      with_git = session(context, git: true)

      assert %{undo: :commands} =
               Doctor.gather(host(with_git, checkpoints: context.checkpoints, cwd: context.repo))
    end
  end

  defp session(context, git: git) do
    {:ok, harness} =
      Harness.assemble(Harness.new(tools: [Tools.Write, Tools.Bash]), [
        {Checkpoints, dir: context.checkpoints, git: git}
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: Scripted.new([]),
        store: JSONL.new(Path.join(context.tmp_dir, "sessions-#{git}")),
        model: "test:model",
        cwd: context.repo,
        harness: harness
      )

    session
  end

  defp host(session, fields) do
    Dispatch.new(
      [
        session: session,
        say: fn acc, _text -> acc end,
        write: fn acc, _text -> acc end,
        fold: fn acc, _event -> acc end,
        run: fn acc, _work -> acc end,
        react: fn acc, _reaction -> acc end
      ] ++ fields
    )
  end
end
