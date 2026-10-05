# Like `Lemieux.TUI`, this exists only when the optional terminal UI
# dependency does: it slices and restyles that library's `Span` structs. The
# arithmetic is still pure and still tested without a terminal.
if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.Selection do
    @moduledoc """
    Dragging a range out of the transcript, and getting the text back.

    The terminal UI captures the mouse so the wheel scrolls the transcript
    rather than walking input history. Capture takes the terminal's own drag
    selection with it, and a screen you cannot copy an error message out of is
    a bad trade however good the scrolling is. So the screen selects for
    itself, and this is the part of that with no screen in it.

    A selection is two points — `{depth, column}`, both zero-based. Anchor is
    where the drag started, cursor is where it is now; either may be the
    earlier one, so `range/1` orders them and everything else works from that.

    ## Depth, not a screen row

    `depth` is the row's distance from the newest row of the transcript, as
    `Lemieux.TUI.Window.view/5` reports it: depth `0` is the newest wrapped
    row, and larger is further back. `column` is counted in graphemes, which
    is what `Lemieux.TUI.RichText` wraps by.

    Storing the screen row instead is the obvious thing and it makes a
    selection that only means anything until the next frame. Scrolling moves
    the text out from under it, and so does every row the model streams, so a
    highlight either drifts onto text nobody dragged over or has to be thrown
    away — and a selection you cannot drag across a scroll cannot cover more
    than a screen. Depth is fixed under scrolling and moves by exactly the
    number of rows appended, which `Lemieux.TUI` knows on every append. So a
    drag can start, scroll a page, and finish somewhere the pane was not
    showing when it began.

    What depth cannot absorb is rows *removed* from the middle — a tool
    result replacing its own placeholder rows — because how far that moves a
    point depends on where the point was. `Lemieux.TUI` drops the selection
    there rather than guessing.

    ## Views, not lines

    `text/2` and `highlight/3` take a window — `%{rows: rows, bottom: bottom}`
    from `Lemieux.TUI.Window.view/5` — rather than a bare list, because a list
    of rows does not say where in the transcript it came from. It also lets
    the two callers pass *different* windows: highlighting works from what is
    on screen and clips to it, while copying asks the window for exactly the
    rows the selection covers, so a selection taller than the pane copies in
    full.

    ## The end is inclusive

    Dragging across `hello` from the `h` to the `o` selects `hello`, not
    `hell`. An exclusive end is tidier arithmetic and wrong every time
    somebody drags to the last character of a path. A drag that never moved
    selects nothing at all — `empty?/1` — so the inclusive end never turns a
    click into a stray character.
    """

    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span

    @typedoc """
    A cell of the transcript: `{depth, column}`, both zero-based.

    Depth counts wrapped rows back from the newest one, so `{0, 0}` is the
    first character of the newest row.
    """
    @type point :: {non_neg_integer(), non_neg_integer()}

    @typedoc "A window over the transcript, as `Lemieux.TUI.Window.view/5` returns it."
    @type view :: %{
            required(:rows) => [Line.t()],
            required(:bottom) => non_neg_integer(),
            optional(atom()) => term()
          }

    @type t :: %__MODULE__{anchor: point(), cursor: point()}

    @enforce_keys [:anchor, :cursor]
    defstruct [:anchor, :cursor]

    @doc "Begins a selection at the cell the drag started on."
    @spec start(point()) :: t()
    def start({depth, column} = point)
        when is_integer(depth) and depth >= 0 and is_integer(column) and column >= 0,
        do: %__MODULE__{anchor: point, cursor: point}

    @doc "Moves the loose end to where the pointer is now."
    @spec extend(selection :: t(), point()) :: t()
    def extend(%__MODULE__{} = selection, {depth, column} = point)
        when is_integer(depth) and depth >= 0 and is_integer(column) and column >= 0,
        do: %{selection | cursor: point}

    @doc """
    Moves a selection back by the `added` rows that just arrived underneath it.

    Depth is distance from the newest row, so rows appended at the bottom move
    every existing row further from it by exactly as many. This is the whole
    reason a selection survives a streaming answer: `Lemieux.TUI` already
    counts `added` to hold the scroll position, and the same number holds the
    highlight.

    `nil` passes through, so the append path does not have to ask whether
    anything is selected.
    """
    @spec deepen(selection :: t() | nil, added :: integer()) :: t() | nil
    def deepen(nil, _added), do: nil
    def deepen(%__MODULE__{} = selection, 0), do: selection

    def deepen(%__MODULE__{anchor: anchor, cursor: cursor}, added) when is_integer(added),
      do: %__MODULE__{anchor: shift(anchor, added), cursor: shift(cursor, added)}

    defp shift({depth, column}, added), do: {max(depth + added, 0), column}

    @doc """
    Whether the drag covered nothing.

    A click is a drag of zero distance, and it selects nothing rather than one
    character — which is what makes clicking a natural way to clear the last
    selection.
    """
    @spec empty?(selection :: t()) :: boolean()
    def empty?(%__MODULE__{anchor: point, cursor: point}), do: true
    def empty?(%__MODULE__{}), do: false

    @doc """
    The selection in reading order, whichever way it was dragged.

    Deeper first, because deeper is further back in the transcript and so
    higher on the screen. This is the one place the axis is inverted relative
    to a screen row, and it is inverted here so that nothing downstream has to
    think about it.
    """
    @spec range(selection :: t()) :: {point(), point()}
    def range(%__MODULE__{anchor: {depth, column} = anchor, cursor: {depth, other} = cursor})
        when column <= other,
        do: {anchor, cursor}

    def range(%__MODULE__{anchor: {depth, _column} = anchor, cursor: {other, _} = cursor})
        when depth > other,
        do: {anchor, cursor}

    def range(%__MODULE__{anchor: anchor, cursor: cursor}), do: {cursor, anchor}

    @doc """
    How far back the selection reaches: `{deepest, shallowest}` depths.

    What a caller needs to ask `Lemieux.TUI.Window.view/5` for exactly the
    rows the selection covers — height is `deepest - shallowest + 1` and
    offset is `shallowest` — which is how copying stays bounded by the size
    of the drag rather than the size of the transcript.
    """
    @spec span(selection :: t()) :: {non_neg_integer(), non_neg_integer()}
    def span(%__MODULE__{} = selection) do
      {{deepest, _from}, {shallowest, _to}} = range(selection)

      {deepest, shallowest}
    end

    @doc """
    The selected text, ready for a clipboard.

    Rows are joined with newlines, and each row is trimmed of the padding the
    pane drew to the right of it: a selection dragged past the end of a short
    line should not come back with the whitespace that was never really there.

    Only the part of the selection `view` covers is returned, so pass a window
    that covers it — see `span/1`.
    """
    @spec text(selection :: t(), view :: view()) :: String.t()
    def text(%__MODULE__{} = selection, %{rows: rows} = view) when is_list(rows) do
      case clip(selection, view) do
        :outside ->
          ""

        {{first, from}, {last, to}} ->
          first..last//1
          |> Enum.map(
            &row_text(Enum.at(rows, &1), from_column(&1, first, from), to_column(&1, last, to))
          )
          |> Enum.reject(&is_nil/1)
          |> Enum.map_join("\n", &String.trim_trailing/1)
      end
    end

    @doc """
    The window's rows with the selected part restyled.

    `style`'s set fields are merged onto whatever each span already carried,
    so a selection over a red error line stays recognisably an error line. A
    span is split at the selection's edges rather than styled whole: a
    selection that snapped to span boundaries would highlight a word the
    person did not drag over.

    A selection that runs off the top or bottom of `view` is highlighted to
    the edge, which is what a drag that scrolled looks like from inside the
    pane.
    """
    @spec highlight(selection :: t(), view :: view(), style :: Style.t()) :: [Line.t()]
    def highlight(%__MODULE__{} = selection, %{rows: rows} = view, %Style{} = style)
        when is_list(rows) do
      case clip(selection, view) do
        :outside ->
          rows

        {{first, from}, {last, to}} ->
          rows
          |> Enum.with_index()
          |> Enum.map(&highlight_row(&1, {first, from}, {last, to}, style))
      end
    end

    # Depth to a row index in this window, and then to the part of that window
    # the selection actually covers. `:outside` when the drag is entirely
    # older or entirely newer than what the window holds — which is the normal
    # state of a selection somebody has scrolled away from, not an error.
    defp clip(selection, %{rows: rows, bottom: bottom}) do
      count = length(rows)
      {{deepest, from}, {shallowest, to}} = range(selection)

      first = count - 1 - (deepest - bottom)
      last = count - 1 - (shallowest - bottom)

      if empty?(selection) or count == 0 or last < 0 or first > count - 1 do
        :outside
      else
        {{max(first, 0), starts_at(first, from)},
         {min(last, count - 1), ends_at(last, count, to)}}
      end
    end

    # A selection running off the top of the window starts at the start of the
    # first row it does cover, and one running off the bottom ends at the end
    # of the last. That is what a drag which scrolled looks like from inside a
    # pane showing only part of it.
    defp starts_at(first, _from) when first < 0, do: 0
    defp starts_at(_first, from), do: from

    defp ends_at(last, count, _to) when last > count - 1, do: :end
    defp ends_at(_last, _count, to), do: to

    defp highlight_row({line, row}, {first, _from}, {last, _to}, _style)
         when row < first or row > last,
         do: line

    defp highlight_row({line, row}, {first, from}, {last, to}, style),
      do: restyle(line, from_column(row, first, from), to_column(row, last, to), style)

    # A row inside the selection runs from its start unless it is the first
    # row, and to its end unless it is the last.
    defp from_column(row, first, from) when row == first, do: from
    defp from_column(_row, _first, _from), do: 0

    defp to_column(row, last, to) when row == last, do: to
    defp to_column(_row, _last, _to), do: :end

    defp row_text(nil, _from, _to), do: nil

    defp row_text(%Line{} = line, from, to) do
      line |> plain() |> slice(from, to)
    end

    defp slice(text, from, :end), do: String.slice(text, from..-1//1)
    defp slice(text, from, to), do: String.slice(text, from..to//1)

    defp plain(%Line{spans: spans}), do: Enum.map_join(spans, & &1.content)

    defp restyle(%Line{spans: spans} = line, from, to, style) do
      {restyled, _column} =
        Enum.map_reduce(spans, 0, fn span, column ->
          {split(span, column, from, to, style), column + String.length(span.content)}
        end)

      %{line | spans: List.flatten(restyled)}
    end

    # One span becomes up to three: what is before the selection, what is
    # inside it, and what is after. Zero-length pieces are dropped rather than
    # emitted, because an empty span is a cell the terminal still has to think
    # about.
    defp split(%Span{content: content} = span, column, from, to, style) do
      length = String.length(content)
      start = max(from - column, 0)
      finish = if to == :end, do: length, else: min(to - column + 1, length)

      if start >= length or finish <= start do
        span
      else
        [
          piece(span, String.slice(content, 0, start), span.style),
          piece(span, String.slice(content, start, finish - start), merge(span.style, style)),
          piece(span, String.slice(content, finish..-1//1), span.style)
        ]
        |> Enum.reject(&is_nil/1)
      end
    end

    defp piece(_span, "", _style), do: nil
    defp piece(span, content, style), do: %{span | content: content, style: style}

    # Only what the selection style actually sets. A style that replaced the
    # span's wholesale would erase the semantic colours the transcript uses to
    # make errors and questions findable, exactly while somebody is reading
    # one closely enough to copy it.
    defp merge(%Style{} = base, %Style{} = selection) do
      %Style{
        fg: selection.fg || base.fg,
        bg: selection.bg || base.bg,
        underline_color: selection.underline_color || base.underline_color,
        modifiers: Enum.uniq(base.modifiers ++ selection.modifiers)
      }
    end
  end
end
