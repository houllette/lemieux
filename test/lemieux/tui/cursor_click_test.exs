defmodule Lemieux.TUI.CursorClickTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias Lemieux.TUI.Editor
  alias Lemieux.TUI.Screen

  test "click places the insertion point without changing the draft" do
    state = tui() |> type("hello world")
    pane = Screen.panes(state).input
    state = events(state, [{"down", pane.x + 4, pane.y + 1}]) |> type("X")
    assert typed(state) == "helXlo world"
    assert state.selection == nil
  end

  test "wrapped, scrolled text uses the renderer's current viewport" do
    input = ExRatatui.textarea_new()
    Editor.replace(input, Enum.map_join(1..12, "\n", &"line #{&1}"))
    assert :ok = Editor.place_cursor(input, 20, 3, 2, 0)
    assert ExRatatui.textarea_cursor(input) == {9, 2}
    ExRatatui.textarea_insert_str(input, "X")
    assert ExRatatui.textarea_get_value(input) =~ "liXne 10"
  end

  test "clicks leave combining marks attached to their base" do
    input = ExRatatui.textarea_new()
    Editor.replace(input, "é fin")
    :ok = Editor.place_cursor(input, 20, 3, 0, 0)
    :ok = Editor.place_cursor(input, 20, 3, 1, 0)
    ExRatatui.textarea_insert_str(input, "X")
    assert ExRatatui.textarea_get_value(input) == "éX fin"
  end

  test "emoji sequences stay intact when placing the cursor" do
    for emoji <- ["👨‍👩‍👧‍👦", "👍🏽"] do
      input = ExRatatui.textarea_new()
      Editor.replace(input, emoji <> " fin")
      :ok = Editor.place_cursor(input, 20, 3, 0, 0)
      :ok = Editor.place_cursor(input, 20, 3, 2, 0)
      ExRatatui.textarea_insert_str(input, "X")
      assert ExRatatui.textarea_get_value(input) == emoji <> "X fin"
    end
  end

  test "word wrapping, wide characters and clicks beyond line ends" do
    input = ExRatatui.textarea_new()
    Editor.replace(input, "hello world 中🙂 fin")
    :ok = Editor.place_cursor(input, 10, 5, 2, 1)
    ExRatatui.textarea_insert_str(input, "X")
    assert ExRatatui.textarea_get_value(input) == "hello woXrld 中🙂 fin"
    Editor.replace(input, "中🙂fin")
    :ok = Editor.place_cursor(input, 20, 3, 4, 0)
    ExRatatui.textarea_insert_str(input, "X")
    assert ExRatatui.textarea_get_value(input) == "中🙂Xfin"
    :ok = Editor.place_cursor(input, 20, 3, 19, 0)
    ExRatatui.textarea_insert_str(input, "!")
    assert ExRatatui.textarea_get_value(input) == "中🙂Xfin!"
  end
end
