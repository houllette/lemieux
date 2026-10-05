defmodule Lemieux.Conversation.ColumnsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Conversation.Columns

  doctest Columns

  test "a name longer than the old fixed pad keeps a gap before its words" do
    [line] = Columns.format([{"/permissions", "show or switch the approval mode"}])

    assert line == "/permissions  show or switch the approval mode"
  end

  test "words start in one column however long the names below the cap are" do
    lines = Columns.format([{"/new", "ONE"}, {"/permissions", "TWO"}, {"ctrl-o", "SIX"}])

    assert Enum.map(lines, &:binary.match(&1, ["ONE", "TWO", "SIX"])) ==
             [{14, 3}, {14, 3}, {14, 3}]
  end

  test "a name past the cap puts its words on the next line, under the column" do
    keys = "back_tab, shift-back_tab, ctrl-t"

    [short, long] = Columns.format([{"enter", "send"}, {keys, "cycle mode"}])

    assert short == "enter  send"
    assert long == keys <> "\n       cycle mode"
    refute long =~ "ctrl-tcycle"
  end

  test "the cap is an option" do
    assert Columns.format([{"abcdef", "x"}], max: 3) == ["abcdef\n  x"]
  end
end
