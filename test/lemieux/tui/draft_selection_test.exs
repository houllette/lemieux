defmodule Lemieux.TUI.DraftSelectionTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.CellSession
  alias ExRatatui.Frame
  alias Lemieux.TUI
  alias Lemieux.TUI.TaskPanel

  test "Shift+Up and Down extend and reverse selection across explicit draft lines" do
    draft = "first\nsecond\nthird"
    state = tui(history: ["older prompt"], lines: said(100)) |> sized()
    :ok = ExRatatui.textarea_insert_str(state.input, draft)
    state = draw(state)
    selected = press(state, "up", ["shift"])
    assert selected.modal == nil
    assert ExRatatui.textarea_cursor(selected.input) == {1, 5}
    assert typed(selected) == draft
    assert selected.scroll == 0
    reversed = press(selected, "down", ["shift"])
    assert ExRatatui.textarea_cursor(reversed.input) == {2, 5}
    assert typed(reversed) == draft

    selected = press(reversed, "up", ["shift"])
    assert typed(type(selected, "X")) == "first\nseconX"
    restored = selected |> press("z", ["ctrl"]) |> press("z", ["ctrl"])
    assert typed(restored) == draft

    boundary = Enum.reduce(1..8, restored, fn _, state -> press(state, "up", ["shift"]) end)
    assert boundary.modal == nil
    assert boundary.scroll == 0
    assert typed(boundary) == draft
  end

  test "soft-wrapped drafts select visual rows and still offer Tasks through F6" do
    draft = String.duplicate("x", 50)
    state = tui() |> sized()
    state = put_in(state.terminal.width, 20)
    :ok = ExRatatui.textarea_insert_str(state.input, draft)
    state = draw(state)
    selected = press(state, "up", ["shift"])
    assert selected.modal == nil
    assert ExRatatui.textarea_cursor(selected.input) == {0, 32}
    assert typed(type(selected, "Z")) == String.duplicate("x", 32) <> "Z"
    restored = selected |> press("z", ["ctrl"]) |> press("z", ["ctrl"])
    assert typed(restored) == draft

    label = Enum.map_join(TaskPanel.title(restored, 80), & &1.content)
    assert label =~ "F6"
    refute label =~ "Shift+Up"
    assert press(restored, "f6").modal.kind == :tasks
    assert press(tui() |> sized(), "up", ["shift"]).modal.kind == :tasks
  end

  test "explicit custom Shift+Up actions keep their meaning while unbound arrows select" do
    state = tui(keys: %{"shift-up" => "page_up"}, lines: said(100)) |> sized()
    :ok = ExRatatui.textarea_insert_str(state.input, "first\nsecond")
    assert press(state, "up", ["shift"]).scroll > 0

    state = tui(keys: %{"shift-up" => "forward", "f7" => "tasks"}) |> sized()
    :ok = ExRatatui.textarea_insert_str(state.input, "first\nsecond")
    selected = state |> draw() |> press("up", ["shift"])
    assert selected.modal == nil
    assert ExRatatui.textarea_cursor(selected.input) == {0, 5}
    assert press(selected, "f7").modal.kind == :tasks
  end

  defp draw(state) do
    cells = CellSession.new(state.terminal.width, state.terminal.height)
    frame = %Frame{width: state.terminal.width, height: state.terminal.height}
    :ok = CellSession.draw(cells, TUI.render(state, frame))
    :ok = CellSession.close(cells)
    state
  end
end
