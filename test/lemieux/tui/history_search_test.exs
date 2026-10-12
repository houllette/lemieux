defmodule Lemieux.TUI.HistorySearchTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Event.Paste
  alias Lemieux.TUI
  alias Lemieux.TUI.HistorySearch

  defp searching(entries, global \\ []) do
    state = tui()
    history = %{state.history | entries: entries, global: global}
    state |> Map.put(:history, history) |> type("unfinished\ndraft") |> press("r", ["ctrl"])
  end

  test "session matches precede earlier sittings, ignoring case and duplicate inputs" do
    state = searching(["deploy current", "run tests"], ["DEPLOY earlier", "deploy current"])
    state = type(state, "DePl")

    assert HistorySearch.matches(state) == ["deploy current", "DEPLOY earlier"]
    assert typed(state) == "unfinished\ndraft"
  end

  test "navigation clamps at either end and Tab takes the selected input without submitting" do
    state = searching(["newest", "middle", "oldest"])
    assert press(state, "down").modal.index == 0

    older = state |> press("r", ["ctrl"]) |> press("up") |> press("up")
    assert older.modal.index == 2

    taken = older |> press("down") |> press("tab")
    assert taken.modal == nil
    assert typed(taken) == "middle"
    refute taken.conversation.busy?
    assert taken.history.entries == ["newest", "middle", "oldest"]
  end

  test "Escape and Ctrl-C restore the complete draft after searching and navigating" do
    for {code, modifiers} <- [{"esc", []}, {"c", ["ctrl"]}] do
      state = searching(["deploy current", "deploy earlier"]) |> type("deploy") |> press("up")
      canceled = press(state, code, modifiers)

      assert canceled.modal == nil
      assert typed(canceled) == "unfinished\ndraft"
      refute canceled.conversation.busy?
    end
  end

  test "accepting a search with no matches restores the draft" do
    state = searching(["deploy current"]) |> type("missing") |> press("up")

    assert state.modal.index == 0
    assert HistorySearch.matches(state) == []
    assert screen(state) =~ "no earlier input contains that"

    taken = press(state, "enter")
    assert taken.modal == nil
    assert typed(taken) == "unfinished\ndraft"
  end

  test "editing a Unicode query resets selection and deletes one grapheme" do
    # The final grapheme is e plus a combining accent, not one codepoint.
    state = searching(["café one", "café two"]) |> type("café") |> press("up")
    assert state.modal.index == 1

    edited = press(state, "backspace")
    assert edited.modal.query == "caf"
    assert edited.modal.index == 0
    assert press(edited, "x", ["alt"]).modal.query == "caf"
    assert press(edited, "x", ["ctrl"]).modal.query == "caf"

    empty = searching([]) |> press("backspace")
    assert empty.modal.query == ""
  end

  test "multiline paste edits the search rather than the draft" do
    state = searching(["deploy the thing"]) |> type("dep")
    assert {:noreply, pasted} = TUI.handle_event(%Paste{content: "loy\nthe thing"}, state)

    assert pasted.modal.query == "deploy the thing"
    assert HistorySearch.matches(pasted) == ["deploy the thing"]
    assert typed(pasted) == "unfinished\ndraft"
    assert {:noreply, ^pasted} = TUI.handle_event(%Paste{content: nil}, pasted)
  end

  test "the selected match stays visible past the first page" do
    state = searching(Enum.map(1..12, &"input #{&1}"))
    state = Enum.reduce(1..9, state, fn _, state -> press(state, "up") end)
    shown = screen(state)

    assert shown =~ "history (12)"
    assert shown =~ "› input 10"
    refute shown =~ "› input 1\n"
    refute shown =~ "input 2\n"
  end

  test "a shortened multiline preview recalls the complete original input" do
    prompt = "first\nsecond " <> String.duplicate("word ", 40)
    state = searching([prompt])
    shown = screen(state)

    assert shown =~ "› first second word"
    assert shown =~ "…"
    refute shown =~ prompt
    assert state |> press("enter") |> typed() == prompt
  end
end
