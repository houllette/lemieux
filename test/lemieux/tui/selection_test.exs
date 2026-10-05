defmodule Lemieux.TUI.SelectionTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias Lemieux.TUI.Selection

  @highlight %Style{bg: :blue}

  # Three rows, the middle one built from several spans so the splitting has
  # something to split.
  defp lines do
    [
      %Line{spans: [%Span{content: "lib/lemieux/session.ex"}]},
      %Line{
        spans: [
          %Span{content: "  ✗ ", style: %Style{fg: :red}},
          %Span{content: "bash ", style: %Style{modifiers: [:bold]}},
          %Span{content: "mix test"}
        ]
      },
      %Line{spans: [%Span{content: "done"}]}
    ]
  end

  # The whole transcript on screen, so the newest row is at depth 0.
  defp view(rows \\ lines(), bottom \\ 0), do: %{rows: rows, bottom: bottom, offset: bottom}

  # Points are depths, and the tests read in screen rows. This is the
  # conversion `Lemieux.TUI` does against a live window, spelled out for a
  # three-row one: the last row is depth 0.
  defp at(row, column, rows \\ 3), do: {rows - 1 - row, column}

  defp plain(%Line{spans: spans}), do: Enum.map_join(spans, & &1.content)

  describe "a drag" do
    test "selects what it covered, in reading order, dragged either way" do
      forwards = Selection.start(at(0, 4)) |> Selection.extend(at(0, 10))
      assert Selection.text(forwards, view()) == "lemieux"

      backwards = Selection.start(at(0, 10)) |> Selection.extend(at(0, 4))
      assert Selection.text(backwards, view()) == "lemieux"
      assert Selection.range(backwards) == {at(0, 4), at(0, 10)}
    end

    test "includes the character it ended on" do
      # h-e-l-l-o dragged end to end is "hello", not "hell": an exclusive end
      # is wrong every time somebody drags to the last character of a path.
      whole = Selection.start(at(0, 0)) |> Selection.extend(at(0, 21))
      assert Selection.text(whole, view()) == "lib/lemieux/session.ex"
    end

    test "that never moved selects nothing, so a click clears rather than picks" do
      click = Selection.start(at(1, 5))

      assert Selection.empty?(click)
      assert Selection.text(click, view()) == ""
      assert Selection.highlight(click, view(), @highlight) == lines()
    end

    test "spanning rows takes each row whole between its ends" do
      across = Selection.start(at(0, 12)) |> Selection.extend(at(2, 3))

      assert Selection.text(across, view()) == "session.ex\n  ✗ bash mix test\ndone"
    end

    test "dragged upwards reads the same way as dragged down" do
      up = Selection.start(at(2, 3)) |> Selection.extend(at(0, 12))

      assert Selection.text(up, view()) == "session.ex\n  ✗ bash mix test\ndone"
    end

    test "past the end of a short row stops at the text rather than its padding" do
      past = Selection.start(at(2, 0)) |> Selection.extend(at(2, 400))

      assert Selection.text(past, view()) == "done"
    end
  end

  describe "surviving the transcript moving" do
    test "scrolling does not move the selection off its own text" do
      # Dragged over the middle row while the window showed all three, then
      # scrolled back by one so the same row is now the bottom one on screen.
      selection = Selection.start(at(1, 4)) |> Selection.extend(at(1, 7))
      assert Selection.text(selection, view()) == "bash"

      scrolled = %{rows: Enum.take(lines(), 2), bottom: 1, offset: 1}
      assert Selection.text(selection, scrolled) == "bash"

      assert [_first, row] = Selection.highlight(selection, scrolled, @highlight)
      selected = Enum.filter(row.spans, &(&1.style.bg == :blue))
      assert Enum.map_join(selected, & &1.content) == "bash"
    end

    test "rows arriving underneath it keep it over the same text" do
      selection = Selection.start(at(1, 4)) |> Selection.extend(at(1, 7))

      # Two more rows appended: the same text is now two rows further from the
      # newest one, and `deepen/2` is given exactly that count.
      grown = Selection.deepen(selection, 2)

      after_append = %{
        rows: lines() ++ [%Line{spans: []}, %Line{spans: []}],
        bottom: 0,
        offset: 0
      }

      assert Selection.text(grown, after_append) == "bash"
      refute Selection.text(selection, after_append) == "bash"
    end

    test "deepening nothing is nothing, so appending need not ask" do
      assert Selection.deepen(nil, 7) == nil
    end
  end

  describe "a window that shows only part of the selection" do
    setup do
      # Covers all three rows, but the window only holds the middle one.
      selection = Selection.start(at(0, 12)) |> Selection.extend(at(2, 3))
      middle = %{rows: [Enum.at(lines(), 1)], bottom: 1, offset: 1}

      {:ok, selection: selection, middle: middle}
    end

    test "highlights to both edges", %{selection: selection, middle: middle} do
      assert [row] = Selection.highlight(selection, middle, @highlight)

      assert Enum.all?(row.spans, &(&1.style.bg == :blue))
      assert plain(row) == plain(Enum.at(lines(), 1))
    end

    test "is left alone when the selection is entirely elsewhere" do
      # A selection two screens back, with a window pinned to the newest row.
      away = Selection.start({40, 0}) |> Selection.extend({40, 4})

      assert Selection.highlight(away, view(), @highlight) == lines()
      assert Selection.text(away, view()) == ""
    end

    test "says how far back to look for the rest", %{selection: selection} do
      # What `Lemieux.TUI` turns into a window of its own when copying: three
      # rows ending at the newest one.
      assert Selection.span(selection) == {2, 0}
    end
  end

  describe "highlighting" do
    test "splits a span at the selection's edges rather than styling it whole" do
      # Covers "ash mi" — starting inside the bold span and ending inside the
      # plain one, so both have to be split.
      selection = Selection.start(at(1, 5)) |> Selection.extend(at(1, 10))
      assert [_first, row, _last] = Selection.highlight(selection, view(), @highlight)

      assert plain(row) == plain(Enum.at(lines(), 1))
      assert Enum.map(row.spans, & &1.content) == ["  ✗ ", "b", "ash ", "mi", "x test"]

      selected = Enum.filter(row.spans, &(&1.style.bg == :blue))
      assert Enum.map_join(selected, & &1.content) == "ash mi"
      assert Selection.text(selection, view()) == "ash mi"
    end

    test "keeps the colours the transcript uses to make things findable" do
      selection = Selection.start(at(1, 0)) |> Selection.extend(at(1, 3))
      assert [_first, row, _last] = Selection.highlight(selection, view(), @highlight)

      # The error marker is still red, and now also selected.
      assert [%Span{content: "  ✗ ", style: style} | _rest] = row.spans
      assert style.fg == :red
      assert style.bg == :blue
    end

    test "carries modifiers instead of replacing them" do
      selection = Selection.start(at(1, 4)) |> Selection.extend(at(1, 8))

      [_first, row, _last] =
        Selection.highlight(selection, view(), %Style{modifiers: [:reversed]})

      assert %Span{content: "bash ", style: style} =
               Enum.find(row.spans, &(&1.content == "bash "))

      assert :bold in style.modifiers
      assert :reversed in style.modifiers
    end

    test "leaves rows outside the selection exactly as they were" do
      selection = Selection.start(at(1, 0)) |> Selection.extend(at(1, 2))
      [first, _row, last] = Selection.highlight(selection, view(), @highlight)

      assert first == Enum.at(lines(), 0)
      assert last == Enum.at(lines(), 2)
    end

    test "emits no empty spans, because an empty cell is still work to draw" do
      selection = Selection.start(at(0, 0)) |> Selection.extend(at(0, 21))
      [row | _rest] = Selection.highlight(selection, view(), @highlight)

      refute Enum.any?(row.spans, &(&1.content == ""))
    end

    test "an empty window is drawn rather than crashed on" do
      selection = Selection.start(at(0, 0)) |> Selection.extend(at(0, 5))

      assert Selection.highlight(selection, view([], 0), @highlight) == []
      assert Selection.text(selection, view([], 0)) == ""
    end
  end
end
