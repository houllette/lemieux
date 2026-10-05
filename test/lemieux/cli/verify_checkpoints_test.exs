defmodule Lemieux.CLI.VerifyCheckpointsTest do
  # `lmx` gives the check it runs after edits the checkpoint directory its
  # undo reads, so `/undo` takes back what the check changed with the turn's
  # edits; withholding `checkpoints` withholds that as well.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @check "printf 'rewritten by the check\\n' > tracked.txt"

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_cli_verify_checkpoints_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "tracked.txt"), "v0\n")

    for args <- [["init", "-q"], ["add", "-A"], ["commit", "-qm", "init"]] do
      {_output, 0} =
        System.cmd(
          "git",
          ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"] ++
            args,
          cd: work,
          stderr_to_stdout: true
        )
    end

    # The config file's directory is the state directory, checkpoints included.
    state = Path.join(tmp_dir, "state")
    File.mkdir_p!(state)

    %{
      runtime: runtime,
      work: work,
      state: state,
      store: JSONL.new(Path.join(tmp_dir, "sessions"))
    }
  end

  defp turn(ctx, config) do
    path = Path.join(ctx.state, "config.json")

    File.write!(
      path,
      JSON.encode!(Map.merge(%{"version" => 1, "verify" => %{"command" => @check}}, config))
    )

    File.chmod!(path, 0o600)

    {:ok, options} = Options.parse(["--config", path, "--no-delegate", "--model", "test:model"])

    provider =
      Scripted.new([
        Scripted.tool_call("w1", "write", %{"path" => "notes.txt", "content" => "hello\n"}),
        Scripted.complete("Done.")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: ctx.runtime,
        provider: provider,
        store: ctx.store,
        cwd: ctx.work
      )

    assert {:ok, %{stop_reason: :stop}} =
             Lemieux.Testing.prompt(session, "write the notes", 30_000)

    Session.id(session)
  end

  defp tracked(ctx), do: File.read!(Path.join(ctx.work, "tracked.txt"))

  test "the check is recorded with the turn, and undone with it", ctx do
    id = turn(ctx, %{})
    assert tracked(ctx) == "rewritten by the check\n"

    assert {:ok, report} = Checkpoint.undo(Path.join(ctx.state, "checkpoints"), id)
    assert report.restored == ["tracked.txt"]
    assert report.deleted == ["notes.txt"]
    assert tracked(ctx) == "v0\n"
  end

  test "withholding checkpoints withholds it too", ctx do
    turn(ctx, %{"disabled_extensions" => ["checkpoints"]})

    assert tracked(ctx) == "rewritten by the check\n"
    refute File.exists?(Path.join(ctx.state, "checkpoints"))
  end
end
