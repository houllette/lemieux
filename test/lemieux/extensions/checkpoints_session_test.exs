defmodule Lemieux.Extensions.CheckpointsSessionTest do
  # Undo through a real session: the tool runs in the session's tool task,
  # and a cancel kills that task, which is what the unit tests cannot show.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Store, as: CheckpointStore
  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_checkpoints_session_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q"])
    File.write!(Path.join(work, "tracked.txt"), "v0\n")
    File.write!(Path.join(work, "notes.txt"), "notes\n")
    git(work, ["add", "-A"])
    git(work, ["commit", "-qm", "init"])

    %{
      runtime: runtime,
      store: JSONL.new(Path.join(tmp_dir, "sessions")),
      checkpoints: Path.join(tmp_dir, "checkpoints"),
      work: work
    }
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

  defp start(context, script) do
    {:ok, harness} =
      Harness.assemble(Harness.new(tools: [Tools.Write, Tools.Bash]), [
        {Checkpoints, dir: context.checkpoints, git: true}
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: Scripted.new(script),
        store: context.store,
        model: "test:model",
        subscriber: self(),
        harness: harness,
        cwd: context.work
      )

    session
  end

  defp read(context, name), do: File.read(Path.join(context.work, name))

  defp windows_closed?(context, id) do
    windows =
      Path.wildcard(Path.join([context.checkpoints, id, "turns", "*", "commands", "*.json"]))

    windows != [] and
      Enum.all?(windows, &match?({:ok, %{"after" => _tree}}, CheckpointStore.json(&1)))
  end

  defp eventually(check, attempts \\ 200) do
    cond do
      check.() -> :ok
      attempts == 0 -> flunk("the condition never held")
      true -> Process.sleep(25) && eventually(check, attempts - 1)
    end
  end

  # The verifier's terminal repro: a turn that wrote a wanted file, then a turn
  # whose command was cancelled mid-run. /undo used to undo the earlier turn
  # (deleting the wanted file) and leave the cancelled command's damage.
  test "a cancelled command's changes are undone, and the turn before it is left alone",
       context do
    write = %{"path" => "hello.txt", "content" => "hello\n"}
    command = "rm notes.txt && printf 'cancelled\\n' > tracked.txt && sleep 30"

    session =
      start(context, [
        Scripted.tool_call("t1", "write", write),
        Scripted.complete("wrote hello.txt"),
        Scripted.tool_call("t2", "bash", %{"command" => command})
      ])

    id = Session.id(session)
    :ok = Session.prompt(session, "write hello")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 10_000

    :ok = Session.prompt(session, "clean up")
    assert_receive {:lemieux, ^id, {:tool_call, %{id: "t2"}}}, 10_000
    eventually(fn -> read(context, "tracked.txt") == {:ok, "cancelled\n"} end)

    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}, 10_000

    assert {:ok, report} = Checkpoint.undo(context.checkpoints, id)
    assert report.turn == 2
    assert Enum.sort(report.restored) == ["notes.txt", "tracked.txt"]
    assert report.next == 1
    assert read(context, "notes.txt") == {:ok, "notes\n"}
    assert read(context, "tracked.txt") == {:ok, "v0\n"}
    assert read(context, "hello.txt") == {:ok, "hello\n"}
  end

  # After a cancel, a person's own fix made before the next prompt is theirs:
  # it used to fall inside the cancelled command's window and be reverted by
  # the next undo.
  test "a fix the person makes after a cancel is not undone with the next turn", context do
    command = "printf 'by the command\\n' > tracked.txt && sleep 30"

    session =
      start(context, [
        Scripted.tool_call("t1", "bash", %{"command" => command}),
        Scripted.tool_call("t2", "bash", %{"command" => "ls"}),
        Scripted.complete("listed")
      ])

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:tool_call, %{id: "t1"}}}, 10_000
    eventually(fn -> read(context, "tracked.txt") == {:ok, "by the command\n"} end)
    :ok = Session.cancel(session)
    assert_receive {:lemieux, ^id, {:finished, :cancelled}}, 10_000

    # The watcher takes the cancelled command's after-tree within moments; a
    # person's fix comes after that, as it would at human speed.
    eventually(fn -> windows_closed?(context, id) end)
    File.write!(Path.join(context.work, "tracked.txt"), "the person's fix\n")

    :ok = Session.prompt(session, "list")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 10_000

    # The newest turn ran only `ls`: nothing to put back, and it says so.
    assert {:ok, %{turn: 2, restored: [], deleted: [], next: 1}} =
             Checkpoint.undo(context.checkpoints, id)

    # The cancelled turn's file has the person's fix now: a conflict, kept.
    assert {:ok, %{turn: 1, restored: [], conflicts: [%{path: "tracked.txt"}]}} =
             Checkpoint.undo(context.checkpoints, id)

    assert read(context, "tracked.txt") == {:ok, "the person's fix\n"}
  end
end
