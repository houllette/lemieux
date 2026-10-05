defmodule Lemieux.TUI.Window do
  @moduledoc """
  Which rows of a transcript are on screen, and how far up it has scrolled.

  This is `Lemieux.TUI`'s scrollback, kept apart from it and kept pure. The
  terminal UI is an optional Rust NIF dependency, and none of the arithmetic
  below needs it. Keeping it here means the part most likely to be wrong is
  the part CI can run on a machine with no terminal and no artifact for its
  platform. `Lemieux.TUI` itself is defined only when `ex_ratatui` is; this
  module always is.

  ## The offset is measured from the bottom

  `0` means pinned to the newest row, and a larger offset means further back.
  A top-anchored offset would have to be corrected on every append — every new
  line pushes the content down, so staying still means counting up — and the
  correction is exactly the bug that makes a log viewer drift while it
  streams. Measuring from the bottom makes "follow the newest" the number `0`
  and "hold still while text arrives" a number that does not change.

  ## Wrapping is exact, and it is still cheap

  Lines are supplied newest-first. `rows/4` stops as soon as it has enough
  wrapped rows to fill the window, so drawing cost follows viewport height,
  not transcript length. Returned rows are oldest-first, ready to paint.
  """

  alias Lemieux.TUI.Width

  @typedoc "A stored transcript line: who said it, and what they said."
  @type line :: {atom(), String.t()}

  @typedoc "One row of the window: who said it, and the piece of it shown."
  @type row :: {atom(), String.t()}

  @doc """
  The rows to draw, and the offset actually used.

  Returns `{rows, offset}`. The returned offset is the requested one clamped
  to what there is to scroll through, so a caller that pages up past the
  beginning gets the first screen and a number it can store back rather than
  an empty pane and a number that grows forever.

  `rows` is oldest-first, ready to print top to bottom.
  """
  @spec rows(
          newest_first_lines :: [line()],
          width :: pos_integer(),
          height :: non_neg_integer(),
          offset :: non_neg_integer()
        ) :: {[row()], non_neg_integer()}
  def rows(newest_first_lines, width, height, offset)
      when is_list(newest_first_lines) and is_integer(width) and width > 0 and is_integer(height) and
             height >= 0 and is_integer(offset) and offset >= 0 do
    rows(newest_first_lines, width, height, offset, fn {who, text}, row_width ->
      Enum.map(wrap(text, row_width), &{who, &1})
    end)
  end

  @doc """
  The `rows/4` viewport calculation with a caller-supplied line renderer.

  The renderer receives one stored line and the available width, and returns
  the rows it occupies. This lets the optional TUI measure styled text after
  inline markers have been removed without moving scroll arithmetic or a
  walk of the entire transcript into the rendering module.
  """
  @spec rows(
          newest_first_lines :: [line()],
          width :: pos_integer(),
          height :: non_neg_integer(),
          offset :: non_neg_integer(),
          renderer :: (line(), pos_integer() -> [term()])
        ) :: {[term()], non_neg_integer()}
  def rows(newest_first_lines, width, height, offset, renderer) do
    view = view(newest_first_lines, width, height, offset, renderer)

    {view.rows, view.offset}
  end

  @doc """
  The same calculation, plus where the returned rows sit in the transcript.

  `rows/5` answers "what do I paint"; this also answers "what am I looking
  at". `:bottom` is the *depth* of the last returned row — how many wrapped
  rows are newer than it, counting the newest row in the transcript as depth
  `0`. Screen row `i` of `n` returned rows is therefore at depth
  `bottom + (n - 1 - i)`, and the inverse is `i = n - 1 - (depth - bottom)`.

  ## Why depth, rather than a row number from the top

  A depth does not change when the pane scrolls — scrolling changes which
  rows are visible, not how many rows are newer than any of them — and it
  changes by exactly `added` when `added` rows arrive at the bottom, which is
  a number the appending caller already has. That makes it the coordinate a
  mouse selection can be stored in and still mean the same text a screen
  later; `Lemieux.TUI.Selection` is built on it.

  Numbering from the oldest row would be just as stable and costs a walk of
  the whole transcript to find out where the oldest row is — on every drag
  event. Depth is measured from the end the window already starts at, so it
  stays bounded by the viewport.
  """
  @spec view(
          newest_first_lines :: [line()],
          width :: pos_integer(),
          height :: non_neg_integer(),
          offset :: non_neg_integer(),
          renderer :: (line(), pos_integer() -> [term()])
        ) :: %{
          rows: [term()],
          offset: non_neg_integer(),
          bottom: non_neg_integer()
        }
  def view(newest_first_lines, width, height, offset, renderer)
      when is_list(newest_first_lines) and is_integer(width) and width > 0 and is_integer(height) and
             height >= 0 and is_integer(offset) and offset >= 0 and is_function(renderer, 2) do
    wanted = height + offset

    {collected, available, exhausted?} = collect(newest_first_lines, width, wanted, renderer)

    offset = if exhausted?, do: min(offset, max(available - height, 0)), else: offset
    start = max(available - height - offset, 0)
    rows = Enum.slice(collected, start, height)

    # `collected` is gathered from the newest line backwards, so its last
    # element is always the newest row — which is what makes the depth of its
    # index `j` exactly `available - 1 - j`, whether or not the walk stopped
    # early.
    %{rows: rows, offset: offset, bottom: available - start - length(rows)}
  end

  defp collect(newest_first_lines, width, wanted, renderer) do
    Enum.reduce_while(newest_first_lines, {[], 0, true}, fn line, {acc, count, _exhausted?} ->
      rows = renderer.(line, width)
      count = count + length(rows)
      collected = rows ++ acc

      if count >= wanted,
        do: {:halt, {collected, count, false}},
        else: {:cont, {collected, count, true}}
    end)
  end

  @doc """
  Breaks `text` into rows no wider than `width`.

  Breaks on whitespace where it can and mid-word where it cannot, because a
  path or a hash with no spaces in it still has to fit — a wrapper that only
  breaks on spaces silently truncates exactly the lines a person most wants to
  read in full.

  An empty string is one empty row, not none: a blank line in a transcript is
  a paragraph break somebody meant.
  """
  @spec wrap(text :: String.t(), width :: pos_integer()) :: [String.t()]
  def wrap(text, width) when is_binary(text) and is_integer(width) and width > 0 do
    case String.split(text, ~r/\s+/, trim: true) do
      [] -> [""]
      words -> words |> Enum.reduce([], &place(&1, &2, width)) |> Enum.reverse()
    end
  end

  defp place("", rows, _width), do: rows

  # Measured in columns, not graphemes: a CJK character or an emoji is one
  # grapheme in two columns, and a row measured by `String.length/1` ran past
  # the edge and was clipped. See `Lemieux.TUI.Width`.
  defp place(word, rows, width) do
    if Width.of(word) > width do
      {head, tail} = Width.split(word, width)
      place(tail, [head | rows], width)
    else
      place_fitting(word, rows, width)
    end
  end

  defp place_fitting(word, [], _width), do: [word]

  defp place_fitting(word, [row | rest], width) do
    joined = row <> " " <> word
    if Width.of(joined) <= width, do: [joined | rest], else: [word, row | rest]
  end

  @doc """
  Where the offset goes when `added` rows arrive at the bottom.

  Two behaviours, and the offset being measured from the bottom is what makes
  them one line each. At `0` the window is following the newest row and keeps
  following it. Anywhere else somebody has scrolled up to read something, and
  the rows arriving underneath them push the bottom further away — so holding
  the same text on screen means growing the distance to it by exactly as many
  rows as arrived.

  Without that second clause the view slides down by a row for every row the
  model streams, which is the behaviour of a pane that ignores the fact that
  somebody is reading it.
  """
  @spec hold(offset :: non_neg_integer(), added :: integer()) :: non_neg_integer()
  def hold(0, _added), do: 0
  def hold(offset, added), do: max(offset + added, 0)
end
