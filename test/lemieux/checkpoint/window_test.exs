defmodule Lemieux.Checkpoint.WindowTest do
  # Command windows across processes, turns and restarts: the watcher that
  # closes a cancelled command's window, undo waiting for it, and which
  # window an after-snapshot may close.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Undo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    git(work, ["init", "-q"])
    File.write!(Path.join(work, "tracked.txt"), "v0\n")
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

  defp windows(store, turn),
    do: Path.wildcard(Path.join(store, "s1/turns/#{turn}/commands/*.json"))

  # A tool task that took its before-tree, changed a file, and is still
  # running — as a stopped command is while its watcher snapshots it.
  defp running_command(store, ctx, work) do
    parent = self()

    task =
      spawn(fn ->
        :ok = Checkpoint.snapshot(store, ctx, :before, watch: self(), subject: "`rm tracked.txt`")
        File.rm!(Path.join(work, "tracked.txt"))
        send(parent, :changed)
        Process.sleep(:infinity)
      end)

    assert_receive :changed, 5_000
    task
  end

  test "undo waits for a stopped command's recording, and does not skip it", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    task = running_command(store, ctx, work)

    assert {:error, :still_recording} = Checkpoint.undo(store, "s1", await_ms: 100)
    refute File.exists?(Path.join(store, "s1/turns/1/undone.json"))

    {_conversation, effects} =
      Conversation.event(
        Conversation.new(model: "test:model"),
        {:undo_result, {:error, :still_recording}}
      )

    assert {:say, Undo.still_recording()} in effects

    # Once the watcher has the after-tree, the same undo goes through.
    Process.exit(task, :kill)
    assert {:ok, %{turn: 1, restored: ["tracked.txt"]}} = Checkpoint.undo(store, "s1")
    assert File.read!(Path.join(work, "tracked.txt")) == "v0\n"
  end

  test "with a runtime in the context the watcher runs under its task supervisor", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    runtime = :"lemieux_window_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    tasks = Lemieux.Supervisor.task_supervisor(runtime)

    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    task = running_command(store, Map.put(ctx, :supervisor, runtime), work)
    assert [_watcher] = Task.Supervisor.children(tasks)

    Process.exit(task, :kill)
    assert {:ok, %{restored: ["tracked.txt"]}} = Checkpoint.undo(store, "s1")
  end

  test "commands without a call id share one window, which spans them all", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    ctx = Map.delete(ctx, :call_id)
    File.write!(Path.join(work, "second.txt"), "s0\n")
    git(work, ["add", "second.txt"])
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")

    :ok = Checkpoint.snapshot(store, ctx, :before)
    File.write!(Path.join(work, "tracked.txt"), "first command\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)
    :ok = Checkpoint.snapshot(store, ctx, :before)
    File.write!(Path.join(work, "second.txt"), "second command\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)

    assert {:ok, %{restored: ["second.txt", "tracked.txt"]}} = Checkpoint.undo(store, "s1")
  end

  # A crashed run's window is still open and was watched. Under a container,
  # where every run can be the same OS process id, it looked like this VM's,
  # and undo waited for a watcher that died with it.
  test "a window another run left open is reported at once, not waited for", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.snapshot(store, ctx, :before, watch: self(), subject: "`rm tracked.txt`")
    File.rm!(Path.join(work, "tracked.txt"))

    [window] = windows(store, 1)
    {:ok, record} = Store.json(window)
    :ok = Store.put_json(window, %{record | "vm" => System.pid() <> "-an-earlier-run"})

    assert {:ok, %{restored: [], not_undone: [%{subject: "`rm tracked.txt`", reason: reason}]}} =
             Checkpoint.undo(store, "s1", await_ms: 200)

    assert reason =~ "had not finished"
  end

  test "an after-snapshot never re-closes a window an older turn already closed", %{
    store: store,
    work: work,
    ctx: ctx
  } do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    :ok = Checkpoint.snapshot(store, ctx, :before)
    File.write!(Path.join(work, "tracked.txt"), "turn 1\n")
    :ok = Checkpoint.snapshot(store, ctx, :after)
    [window] = windows(store, 1)
    {:ok, closed} = Store.json(window)

    # Turn 2 reuses the call id, and its before-snapshot never happened.
    {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    Checkpoint.mark_unrecorded(store, ctx, "`x`", "for the turn to be kept")
    File.write!(Path.join(work, "tracked.txt"), "turn 2\n")

    assert :skipped = Checkpoint.snapshot(store, ctx, :after)
    assert {:ok, ^closed} = Store.json(window)
  end
end
