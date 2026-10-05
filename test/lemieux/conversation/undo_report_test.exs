defmodule Lemieux.Conversation.UndoReportTest do
  # What /undo, /rewind and /redo say. The report is the safety net's only
  # voice: these pin that it names what it could not do, not just what it did.
  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Undo

  defp conversation(fields \\ []), do: struct!(Conversation.new(model: "test:model"), fields)
  defp effects(conversation, line), do: conversation |> Conversation.input(line) |> elem(1)
  defp said(effects), do: for({:say, text} <- effects, do: text) |> Enum.join("\n")

  defp report(fields) do
    Map.merge(
      %{
        turn: 2,
        action: :undo,
        restored: [],
        deleted: [],
        conflicts: [],
        unrestorable: [],
        not_undone: [],
        next: nil
      },
      Map.new(fields)
    )
  end

  test "a turn with nothing to put back is answered as that turn, with the way further back" do
    line =
      Undo.describe(
        report(
          not_undone: [
            %{
              subject: "`rm notes.txt`",
              reason: "commands are recorded only in a git repository"
            },
            %{
              subject: "`echo x >> .env`",
              reason: "commands are recorded only in a git repository"
            }
          ],
          next: 1
        )
      )

    assert line =~ "turn 2: nothing put back"
    assert line =~ "not undone: `rm notes.txt`, `echo x >> .env` — commands are recorded only"
    assert line =~ "/undo again to undo turn 1"
    refute line =~ "undid"
  end

  test "a turn whose commands changed nothing visible says what it cannot see" do
    line = Undo.describe(report(commands?: true, next: 1))
    assert line =~ "turn 2 changed no file undo records"
    assert line =~ "ignored files"
    assert line =~ "/undo again to undo turn 1"

    # Only file tools ran (a write that was refused): no caveat about commands.
    line = Undo.describe(report(next: 1))
    assert line =~ "turn 2: nothing to put back · the files it recorded are as they were"
    refute line =~ "commands"
  end

  test "what was put back and what was not share one line" do
    line =
      Undo.describe(
        report(
          restored: ["tracked.txt"],
          unrestorable: [%{path: ".env", reason: "changed by a command; git ignores it"}],
          not_undone: [%{subject: "HEAD", reason: "moved from main (abc1234) to wip (def5678)"}],
          next: 1
        )
      )

    assert line =~ "undid turn 2 · restored tracked.txt"
    assert line =~ "could not restore: .env (changed by a command; git ignores it)"
    assert line =~ "not undone: HEAD — moved from main (abc1234) to wip (def5678)"
    # Something was put back: the next turn is not offered as if this one were empty.
    refute line =~ "/undo again"
  end

  test "left-alone files say what --force does and what /undo again does" do
    conflict = [%{path: "b.txt", reason: "changed since the agent wrote it"}]

    line = Undo.describe(report(restored: ["a.txt"], conflicts: conflict, next: 1))
    assert line =~ "undid turn 2 · restored a.txt · left alone: b.txt"

    assert line =~
             "/undo --force puts them back anyway · /undo again keeps them and undoes turn 1"

    # The first turn: there is no turn before it to offer.
    line = Undo.describe(report(conflicts: conflict, next: nil))
    assert String.ends_with?(line, " · /undo --force puts them back anyway")

    line = Undo.describe(report(action: :redo, conflicts: conflict, next: nil))
    assert line =~ "turn 2: nothing redone"
    assert String.ends_with?(line, " · /redo --force puts them back anyway")
  end

  test "a restore undo cannot vouch for is said, to the person and to the model" do
    caveat = %{path: "config/local/x.json", reason: "an earlier command may have changed it"}
    redone = report(restored: ["config/local/x.json", "a.ex"], uncertain: [caveat])

    assert Undo.describe(redone) =~
             "may still differ from before the turn: config/local/x.json (an earlier command"

    note = Undo.note([redone])
    assert note =~ "Put back as they were before: a.ex."
    assert note =~ "though a command may have changed them before that: config/local/x.json."
  end

  test "long lists are counted rather than printed" do
    paths = for n <- 1..2_000, do: "many/f#{n}.txt"
    line = Undo.describe(report(deleted: paths))
    assert line =~ "deleted many/f1.txt, many/f2.txt"
    assert line =~ "many/f10.txt and 1990 more"
    refute line =~ "many/f11.txt"

    subjects = for n <- 1..5, do: %{subject: "`cmd #{n}`", reason: "same reason"}
    line = Undo.describe(report(not_undone: subjects))
    assert line =~ "not undone: `cmd 1`, `cmd 2`, `cmd 3` and 2 more — same reason"
  end

  test "a report without the newer fields still reads" do
    line =
      Undo.describe(%{
        turn: 3,
        restored: ["lib/a.ex"],
        deleted: [],
        conflicts: [],
        unrestorable: []
      })

    assert line == "undid turn 3 · restored lib/a.ex"
  end

  test "a redo says so, and so does the note to the model" do
    redo = report(action: :redo, restored: ["a.ex"], deleted: ["b.ex"])
    assert Undo.describe(redo) =~ "redid turn 2 · restored a.ex · deleted b.ex"

    note = Undo.note([redo])
    assert note =~ "took back their undo"
    assert note =~ "a.ex"
    assert note =~ "b.ex"
  end

  test "nothing left to undo, an unwritable store and nothing to redo each say what is true" do
    {_conversation, effects} =
      Conversation.event(conversation(), {:undo_result, {:error, :nothing_to_undo}})

    assert said(effects) =~ "nothing to undo"
    refute said(effects) =~ "only file changes the agent made"

    {_conversation, effects} =
      Conversation.event(
        conversation(),
        {:undo_result, {:error, {:unwritable, "/home/me/.lmx/checkpoints"}}}
      )

    assert said(effects) =~ "checkpoints could not be written to /home/me/.lmx/checkpoints"

    {_conversation, effects} =
      Conversation.event(conversation(), {:undo_result, {:error, :nothing_to_redo}})

    assert said(effects) =~ "nothing to redo"
  end

  test "in a rewind only the last report says which turn another /undo takes" do
    quiet = report(turn: 3, next: 2, not_undone: [%{subject: "`ls`", reason: "not a repository"}])
    last = report(turn: 2, restored: ["a.ex"], next: 1)

    {_conversation, effects} =
      Conversation.event(conversation(), {:rewind_result, {:ok, [quiet, last]}})

    [first_line, second_line] = for {:say, text} <- effects, do: text
    assert first_line =~ "turn 3: nothing put back"
    refute first_line =~ "/undo again"
    assert second_line =~ "undid turn 2 · restored a.ex"
  end

  # --force finishes the last undo only; an earlier turn of the rewind is past.
  test "in a rewind only the last report offers --force" do
    conflict = [%{path: "b.txt", reason: "changed since the agent wrote it"}]
    earlier = report(turn: 3, conflicts: conflict, next: 2)
    last = report(turn: 2, conflicts: conflict, next: 1)

    {_conversation, effects} =
      Conversation.event(conversation(), {:rewind_result, {:ok, [earlier, last]}})

    [first_line, second_line] = for {:say, text} <- effects, do: text
    assert first_line =~ "left alone: b.txt"
    refute first_line =~ "--force"
    assert second_line =~ "/undo --force puts them back anyway"
  end

  test "an undo with nothing put back leaves no note for the model" do
    {held, _effects} =
      Conversation.event(
        conversation(),
        {:undo_result, {:ok, report(not_undone: [%{subject: "x", reason: "y"}])}}
      )

    assert {_sent, [{:prompt, "next"}]} = Conversation.input(held, "next")
  end

  test "/redo waits for the turn and reads its argument" do
    assert [{:redo, false}] = effects(conversation(), "/redo")
    assert [{:redo, true}] = effects(conversation(), "/redo --force")
    assert said(effects(conversation(), "/redo now")) =~ "usage: /redo"
    refute Enum.any?(effects(conversation(busy?: true), "/redo"), &match?({:redo, _}, &1))
    assert Enum.any?(Conversation.commands(), &(&1.name == "redo"))
  end
end
