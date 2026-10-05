defmodule Lemieux.Extensions.VerifyCheckpointTest do
  # The check after edits is a command the repository chose, and it changes
  # files as the model's own commands do. Given the checkpoint directory, it
  # runs inside a window of its own, so an undo of the turn takes back what
  # it changed — or, where it could not be recorded, says so. Before, an undo
  # put the model's edits back and left the check's changes unmentioned.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Extensions.Verify
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  # Rewrites a tracked file and leaves one of its own, as a formatter or a
  # fixture generator run by the check would, and passes.
  @check "printf 'rewritten by the check\\n' > tracked.txt && printf 'generated\\n' > generated.txt"

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_verify_checkpoint_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "tracked.txt"), "v0\n")
    git(work, ["init", "-q"])
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])

    %{
      runtime: runtime,
      work: work,
      store: JSONL.new(Path.join(tmp_dir, "sessions")),
      checkpoints: Path.join(tmp_dir, "checkpoints")
    }
  end

  defp git(work, args) do
    {_output, 0} =
      System.cmd(
        "git",
        ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
          args,
        cd: work,
        stderr_to_stdout: true
      )
  end

  # One turn: the model writes notes.txt, stops, and the check runs and passes.
  defp turn(ctx, verify_opts) do
    {:ok, harness} =
      Harness.assemble(Harness.new(tools: [Tools.Write, Tools.Bash]), [
        {Checkpoints, dir: ctx.checkpoints, git: true},
        {Verify, [command: @check, cwd: ctx.work] ++ verify_opts}
      ])

    provider =
      Scripted.new([
        Scripted.tool_call("w1", "write", %{"path" => "notes.txt", "content" => "hello\n"}),
        Scripted.complete("Done.")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        provider: provider,
        store: ctx.store,
        model: "test:verify",
        subscriber: self(),
        harness: harness,
        cwd: ctx.work
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "write the notes")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert {:ok, %{last: %{"status" => "passed"}}} = Verify.status(session)
    id
  end

  defp read(work, name), do: File.read(Path.join(work, name))

  test "an undo takes back what the check changed, with the edits it checked", ctx do
    id = turn(ctx, checkpoints: ctx.checkpoints)
    assert read(ctx.work, "tracked.txt") == {:ok, "rewritten by the check\n"}

    assert {:ok, report} = Checkpoint.undo(ctx.checkpoints, id)
    assert report.turn == 1
    assert report.restored == ["tracked.txt"]
    assert Enum.sort(report.deleted) == ["generated.txt", "notes.txt"]
    assert report.conflicts == []

    assert read(ctx.work, "tracked.txt") == {:ok, "v0\n"}
    assert read(ctx.work, "generated.txt") == {:error, :enoent}
    assert read(ctx.work, "notes.txt") == {:error, :enoent}
  end

  test "without the directory the check stays outside the net", ctx do
    id = turn(ctx, [])

    assert {:ok, report} = Checkpoint.undo(ctx.checkpoints, id)
    assert report.deleted == ["notes.txt"]
    assert read(ctx.work, "tracked.txt") == {:ok, "rewritten by the check\n"}
    assert read(ctx.work, "generated.txt") == {:ok, "generated\n"}
  end

  test "where the check cannot be recorded, the undo names it", ctx do
    # ExUnit's tmp_dir sits inside this repository's ignored tmp/; the system
    # temporary directory is in no repository.
    outside =
      Path.join(System.tmp_dir!(), "lmx-verify-nongit-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    id = turn(%{ctx | work: outside}, checkpoints: ctx.checkpoints)

    assert {:ok, report} = Checkpoint.undo(ctx.checkpoints, id)
    assert report.deleted == ["notes.txt"]
    assert [%{subject: subject, reason: reason}] = report.not_undone
    assert subject == "the post-edit check " <> Checkpoint.subject(@check)
    assert reason =~ "only in a git repository"
  end

  test "the directory is a path, or the option is refused" do
    assert {:ok, %Verify{checkpoints: "/state/checkpoints"}} =
             Verify.init(checkpoints: "/state/checkpoints")

    for malformed <- ["", :checkpoints, ~c"/state"] do
      assert Verify.init(checkpoints: malformed) ==
               {:error, "verify: checkpoints must be a directory path"}
    end
  end

  # As `Lemieux.Extensions.Checkpoints` expands its `:dir`: a relative path
  # given to both must name one directory to both, whatever the VM's working
  # directory is when the check runs.
  test "a relative directory is expanded when the extension is initialised" do
    assert {:ok, %Verify{checkpoints: dir}} = Verify.init(checkpoints: "state/checkpoints")
    assert dir == Path.expand("state/checkpoints")

    assert {:ok, %{dir: ^dir}} = Checkpoints.init(dir: "state/checkpoints")
  end
end
