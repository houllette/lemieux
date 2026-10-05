defmodule Lemieux.Checkpoint.ForceTest do
  # Each test follows a hint a report printed and checks which turn, and which
  # files, it acted on. "/undo --force puts them back anyway" used to force
  # the turn *before* the one the report was about, and "/redo --force" to
  # redo an older undo over a person's edit, with nothing kept of it.
  use ExUnit.Case, async: true

  alias Lemieux.Checkpoint
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Conversation.Command.Undo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    work = Path.join(tmp_dir, "work")
    File.mkdir_p!(work)
    File.write!(Path.join(work, "a.txt"), "a0\n")
    File.write!(Path.join(work, "b.txt"), "b0\n")
    %{store: Path.join(tmp_dir, "checkpoints"), work: work}
  end

  defp ctx(work, call_id), do: %{cwd: work, session_id: "s1", call_id: call_id}

  defp agent_writes(store, work, call_id, name, contents) do
    ctx = ctx(work, call_id)
    :ok = Checkpoint.capture(store, ctx, name, tool: "write")
    File.write!(Path.join(work, name), contents)
    :ok = Checkpoint.record_after(store, ctx, name)
  end

  defp read(work, name), do: File.read!(Path.join(work, name))

  # Turn 1 writes a.txt (wanted), turn 2 writes b.txt, and the person then
  # edits b.txt: the first /undo leaves b.txt alone.
  defp two_turns_and_a_conflict(store, work) do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c1", "a.txt", "a1 wanted\n")
    {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c2", "b.txt", "b1\n")
    File.write!(Path.join(work, "b.txt"), "b2 the person's\n")

    assert {:ok, report} = Checkpoint.undo(store, "s1")
    assert %{turn: 2, restored: [], conflicts: [%{path: "b.txt"}], next: 1} = report
    report
  end

  test "--force after an undo that left a file alone puts that file back, in that turn",
       %{store: store, work: work} do
    report = two_turns_and_a_conflict(store, work)

    line = Undo.describe(report)
    assert line =~ "/undo --force puts them back anyway"
    assert line =~ "/undo again keeps them and undoes turn 1"

    assert {:ok, forced} = Checkpoint.undo(store, "s1", force: true)
    assert %{turn: 2, restored: ["b.txt"], conflicts: [], next: 1} = forced
    assert read(work, "b.txt") == "b0\n"
    # Turn 1 is untouched by the force.
    assert read(work, "a.txt") == "a1 wanted\n"

    # And nothing is left for --force to finish: the next one is turn 1.
    assert {:ok, %{turn: 1, restored: ["a.txt"]}} = Checkpoint.undo(store, "s1", force: true)
  end

  test "/undo again after a conflict keeps the file and undoes the turn before",
       %{store: store, work: work} do
    two_turns_and_a_conflict(store, work)

    assert {:ok, %{turn: 1, restored: ["a.txt"]}} = Checkpoint.undo(store, "s1")
    assert read(work, "b.txt") == "b2 the person's\n"
    assert read(work, "a.txt") == "a0\n"
  end

  test "a turn recorded since the conflict is what --force undoes",
       %{store: store, work: work} do
    two_turns_and_a_conflict(store, work)

    {:ok, 3} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c3", "c.txt", "c1\n")

    assert {:ok, %{turn: 3, deleted: ["c.txt"]}} = Checkpoint.undo(store, "s1", force: true)
    assert read(work, "b.txt") == "b2 the person's\n"
  end

  test "an undo's forced files are taken back by one redo with the rest of it",
       %{store: store, work: work} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c1", "a.txt", "a1\n")
    agent_writes(store, work, "c2", "b.txt", "b1\n")
    File.write!(Path.join(work, "b.txt"), "b2 the person's\n")

    assert {:ok, %{restored: ["a.txt"], conflicts: [%{path: "b.txt"}]}} =
             Checkpoint.undo(store, "s1")

    assert {:ok, %{restored: ["b.txt"]}} = Checkpoint.undo(store, "s1", force: true)

    assert {:ok, %{action: :redo, restored: restored}} = Checkpoint.redo(store, "s1")
    assert Enum.sort(restored) == ["a.txt", "b.txt"]
    assert read(work, "a.txt") == "a1\n"
    assert read(work, "b.txt") == "b2 the person's\n"
  end

  test "/rewind --force finishes the left-alone files, then goes on to the turn before",
       %{store: store, work: work} do
    two_turns_and_a_conflict(store, work)

    assert {:ok, [%{turn: 2, restored: ["b.txt"]}, %{turn: 1, restored: ["a.txt"]}]} =
             Checkpoint.rewind(store, "s1", 2, force: true)

    assert read(work, "a.txt") == "a0\n"
    assert read(work, "b.txt") == "b0\n"
  end

  test "a redo that put nothing back keeps its undo, and --force acts on that undo alone",
       %{store: store, work: work} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c1", "a.txt", "a1\n")
    {:ok, 2} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c2", "b.txt", "b1\n")

    {:ok, %{turn: 2}} = Checkpoint.undo(store, "s1")
    {:ok, %{turn: 1}} = Checkpoint.undo(store, "s1")
    {:ok, %{turn: 1, restored: ["a.txt"]}} = Checkpoint.redo(store, "s1")
    {:ok, %{turn: 1}} = Checkpoint.undo(store, "s1")

    File.write!(Path.join(work, "a.txt"), "a the person's\n")
    File.write!(Path.join(work, "b.txt"), "b the person's\n")

    assert {:ok, redo} = Checkpoint.redo(store, "s1")
    assert %{turn: 1, restored: [], conflicts: [%{path: "a.txt"}]} = redo
    line = Undo.describe(redo)
    assert line =~ "turn 1: nothing redone"
    assert line =~ "/redo --force puts them back anyway"
    refute line =~ "redid"

    assert {:ok, %{turn: 1, restored: ["a.txt"]}} = Checkpoint.redo(store, "s1", force: true)
    assert read(work, "a.txt") == "a1\n"
    # Turn 2's undo, older, was not the one redone.
    assert read(work, "b.txt") == "b the person's\n"

    # What the forced redo wrote over is kept in the store, not lost. Record
    # names sort in the order they were made; the newest is the forced redo.
    record = store |> Path.join("s1/turns/1/redone/*.json") |> Path.wildcard() |> Enum.max()

    assert {:ok, %{"overwritten" => [%{"path" => "a.txt", "state" => state}]}} =
             Store.json(record)

    assert {:ok, "a the person's\n"} = Store.blob(Path.join(store, "s1"), state["sha256"])
  end

  test "after a redo that put back only some files, --force puts back the rest of it",
       %{store: store, work: work} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c1", "a.txt", "a1\n")
    agent_writes(store, work, "c2", "b.txt", "b1\n")
    {:ok, %{restored: ["a.txt", "b.txt"]}} = Checkpoint.undo(store, "s1")
    File.write!(Path.join(work, "b.txt"), "b the person's\n")

    assert {:ok, %{restored: ["a.txt"], conflicts: [%{path: "b.txt"}]}} =
             Checkpoint.redo(store, "s1")

    assert {:ok, %{turn: 1, restored: ["b.txt"], conflicts: []}} =
             Checkpoint.redo(store, "s1", force: true)

    assert read(work, "b.txt") == "b1\n"

    # The turn is the agent's again, and undoes as a whole.
    assert {:ok, %{turn: 1, restored: ["a.txt", "b.txt"]}} = Checkpoint.undo(store, "s1")
  end

  test "a redo with everything already back says there is nothing to redo",
       %{store: store, work: work} do
    {:ok, 1} = Checkpoint.begin_turn(store, "s1")
    agent_writes(store, work, "c1", "a.txt", "a1\n")
    {:ok, _report} = Checkpoint.undo(store, "s1")
    File.write!(Path.join(work, "a.txt"), "a1\n")

    assert {:ok, %{restored: [], conflicts: []} = redo} = Checkpoint.redo(store, "s1")
    assert Undo.describe(redo) =~ "turn 1: nothing to redo"
    assert {:error, :nothing_to_redo} = Checkpoint.redo(store, "s1")
  end
end
