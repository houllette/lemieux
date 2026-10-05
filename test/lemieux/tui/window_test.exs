defmodule Lemieux.TUI.WindowTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.Window

  defp lines(n, prefix \\ "line"),
    do: for(i <- n..1//-1, do: {:lmx, "#{prefix} #{i}"})

  defp text(rows), do: Enum.map(rows, fn {_who, text} -> text end)

  describe "wrap/2" do
    test "breaks on whitespace" do
      assert Window.wrap("the quick brown fox", 10) == ["the quick", "brown fox"]
    end

    test "breaks a word with nothing to break on rather than overflowing" do
      rows = Window.wrap("lib/lemieux/a_very_long_module_name.ex", 12)

      assert Enum.all?(rows, &(String.length(&1) <= 12))
      assert Enum.join(rows) == "lib/lemieux/a_very_long_module_name.ex"
    end

    test "a blank line is one row, because somebody meant it" do
      assert Window.wrap("", 10) == [""]
      assert Window.wrap("   ", 10) == [""]
    end

    test "text that fits is left alone" do
      assert Window.wrap("short", 10) == ["short"]
    end

    test "measures graphemes rather than encoded bytes" do
      assert Window.wrap("éé", 2) == ["éé"]
      assert Window.wrap("ééé", 2) == ["éé", "é"]
    end
  end

  describe "rows/4 at the bottom" do
    test "shows the newest rows, oldest first" do
      assert {rows, 0} = Window.rows(lines(100), 40, 3, 0)
      assert text(rows) == ["line 98", "line 99", "line 100"]
    end

    test "a short transcript is shown whole, without padding" do
      assert {rows, 0} = Window.rows(lines(2), 40, 10, 0)
      assert text(rows) == ["line 1", "line 2"]
    end

    test "an empty transcript is an empty window" do
      assert Window.rows([], 40, 10, 0) == {[], 0}
    end
  end

  describe "rows/4 scrolled back" do
    test "the offset counts rows from the bottom" do
      assert {rows, 5} = Window.rows(lines(100), 40, 3, 5)
      assert text(rows) == ["line 93", "line 94", "line 95"]
    end

    test "an offset past the beginning is clamped, and the clamp is reported" do
      # Ten rows, a window of three: seven is as far back as it goes.
      assert {rows, 7} = Window.rows(lines(10), 40, 3, 10_000)
      assert text(rows) == ["line 1", "line 2", "line 3"]
    end
  end

  describe "rows/4 counts wrapped rows, not stored lines" do
    test "one long line occupies the window it actually needs" do
      # Each line wraps to exactly two rows at width 10.
      lines = [{:lmx, "cccccccccc dddddddddd"}, {:lmx, "aaaaaaaaaa bbbbbbbbbb"}]

      assert {rows, 0} = Window.rows(lines, 10, 3, 0)

      # Three rows of the four, so the first line is half off the top — which
      # is the whole difference from counting stored lines, where this would
      # have shown both lines and left a row empty.
      assert text(rows) == ["bbbbbbbbbb", "cccccccccc", "dddddddddd"]
    end

    test "scrolling steps by rows, so a wrapped line takes two pages of one" do
      lines = [{:lmx, "cc"}, {:lmx, "aaaaaaaaaa bbbbbbbbbb"}]

      assert {[{:lmx, "cc"}], 0} = Window.rows(lines, 10, 1, 0)
      assert {[{:lmx, "bbbbbbbbbb"}], 1} = Window.rows(lines, 10, 1, 1)
      assert {[{:lmx, "aaaaaaaaaa"}], 2} = Window.rows(lines, 10, 1, 2)
    end
  end

  describe "rows/4 does not walk the whole transcript" do
    test "stops as soon as the window is full" do
      newest = Enum.take(lines(1_000), 3)
      lines = newest ++ [{:lmx, :never_reached}]

      assert {rows, 0} = Window.rows(lines, 40, 3, 0)
      assert text(rows) == ["line 998", "line 999", "line 1000"]
    end

    test "work does not grow with hidden history" do
      history = lines(100_000)

      # The BEAM charges garbage collection to the process that runs it, so a
      # single reading here answers "did a collection land between these two
      # lines" at least as much as it answers the question being asked: 423
      # reductions when one did not, 34,000 when one did. Collecting first is
      # not enough, because a hundred thousand lines stay live and the next
      # collection has to walk them again — that was still failing at 68,000.
      #
      # The smallest of several readings is the honest number. A `rows/4` that
      # had gone back to walking the history would be large in every one of
      # them, so the assertion still fails for the reason it exists.
      readings =
        for _ <- 1..5 do
          {:reductions, before_rows} = Process.info(self(), :reductions)
          result = Window.rows(history, 40, 3, 0)
          {:reductions, after_rows} = Process.info(self(), :reductions)
          {after_rows - before_rows, result}
        end

      {cost, result} = Enum.min_by(readings, &elem(&1, 0))

      assert {rows, 0} = result
      assert text(rows) == ["line 99998", "line 99999", "line 100000"]
      assert cost < 1_000
    end

    test "and does look, when the window reaches that far back" do
      lines = lines(2) ++ [{:lmx, :never_reached}]

      assert_raise FunctionClauseError, fn -> Window.rows(lines, 40, 10, 0) end
    end
  end

  # `bottom` is what makes a mouse selection outlive the frame it was dragged
  # on: see `Lemieux.TUI.Selection`.
  describe "view/5" do
    defp plain(line, width), do: Enum.map(Window.wrap(elem(line, 1), width), &{elem(line, 0), &1})

    defp view(lines, width, height, offset),
      do: Window.view(lines, width, height, offset, &plain/2)

    test "the newest row is depth zero, whatever the transcript is doing" do
      assert %{rows: rows, bottom: 0, offset: 0} = view(lines(100), 40, 3, 0)
      assert text(rows) == ["line 98", "line 99", "line 100"]
    end

    test "scrolling back moves the window, not the depths" do
      # The same row — "line 98" — is the newest on screen after scrolling by
      # two, and is still two rows back from the newest in the transcript.
      assert %{rows: rows, bottom: 2, offset: 2} = view(lines(100), 40, 3, 2)
      assert text(rows) == ["line 96", "line 97", "line 98"]
    end

    test "the reported depths name the rows that came back" do
      %{rows: rows, bottom: bottom} = view(lines(100), 40, 4, 5)
      count = length(rows)

      # depth = bottom + (count - 1 - i), which is the arithmetic every caller
      # does; assert it against what is actually in each row.
      for {row, i} <- Enum.with_index(rows) do
        depth = bottom + (count - 1 - i)
        assert row == {:lmx, "line #{100 - depth}"}
      end
    end

    test "a transcript shorter than the window still counts from its newest row" do
      assert %{rows: rows, bottom: 0, offset: 0} = view(lines(2), 40, 10, 0)
      assert text(rows) == ["line 1", "line 2"]
    end

    test "a wrapped line contributes every row it occupies" do
      # One line wrapping to three rows, so depth counts rows and not lines.
      lines = [{:lmx, "aaa bbb ccc"}, {:lmx, "old"}]

      assert %{rows: rows, bottom: 0} = view(lines, 3, 2, 0)
      assert text(rows) == ["bbb", "ccc"]

      assert %{rows: rows, bottom: 2, offset: 2} = view(lines, 3, 2, 2)
      assert text(rows) == ["old", "aaa"]
    end

    test "scrolling past the beginning clamps the offset and says so" do
      assert %{rows: rows, offset: 7, bottom: 7} = view(lines(10), 40, 3, 900)
      assert text(rows) == ["line 1", "line 2", "line 3"]
    end

    test "an empty transcript is an empty window rather than an error" do
      assert %{rows: [], bottom: 0, offset: 0} = view([], 40, 5, 0)
    end
  end

  describe "hold/2" do
    test "a window at the bottom keeps following" do
      assert Window.hold(0, 4) == 0
    end

    test "a window scrolled back holds its text as rows arrive under it" do
      assert Window.hold(10, 3) == 13
    end

    test "a line that got shorter does not push the offset negative" do
      assert Window.hold(2, -5) == 0
    end
  end
end
