if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.A2UI.Layout do
    @moduledoc """
    A bounded flow layout for transcript visualizations.

    Containers stay in the projection: flattening them into independent rows
    loses their common edge and makes each gallery canvas choose its own inset.
    Widths and measurements are cached when a closed fence arrives. Drawing
    only projects that tree at the pane width; it never depends on viewport
    height, so scroll accounting, resizing and replay agree on the row height.
    Rows stack when their minimum widths cannot fit. Padding and explicit
    height add space, never crop data to make a layout fit.
    """
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias Lemieux.TUI.Art
    alias Lemieux.TUI.Diagrams
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Theme
    alias Lemieux.TUI.Width

    @doc "Caches intrinsic widths on an already prepared, validated node."
    @spec measure(node :: map()) :: map()
    def measure(node) do
      {preferred, minimum} = intrinsic(node)
      padding = 2 * Map.get(node, "padding", 0)
      preferred = Map.get(node, "width", preferred + padding) |> min(200) |> max(1)
      minimum = Map.get(node, "width", minimum + padding) |> min(preferred) |> max(1)
      Map.merge(node, %{preferred: preferred, minimum: minimum})
    end

    @doc "Projects a prepared tree into styled lines bounded by terminal cells."
    @spec lines(tree :: map(), width :: pos_integer(), theme :: Theme.t()) :: [Line.t()]
    def lines(tree, width, theme), do: render(tree, min(width, 200), theme, true, false)

    defp intrinsic(%{"component" => type, "children" => children} = node)
         when type in ["Column", "Row"] do
      preferred = Enum.map(children, & &1.preferred)
      minimum = Enum.map(children, & &1.minimum)
      gap = Map.get(node, "gap", 0) * (length(children) - 1)

      if type == "Row",
        do: {Enum.sum(preferred) + gap, Enum.max(minimum)},
        else: {Enum.max(preferred), Enum.max(minimum)}
    end

    defp intrinsic(%{"component" => "Text", rows: rows}) do
      lines = RichText.lines(rows, 512, Theme.mono())

      minimum =
        lines
        |> Enum.flat_map(& &1.spans)
        |> Enum.map(&widest_grapheme/1)
        |> Enum.max(fn -> 1 end)

      {natural_width(lines), max(minimum, 1)}
    end

    defp intrinsic(%{"component" => "Table", "headers" => headers, rows: rows}) do
      {natural_width(RichText.lines(rows, 2048, Theme.mono())), 5 * length(headers) - 2}
    end

    defp intrinsic(%{rows: [{:model_diagram, prepared}]}), do: Diagrams.size(prepared)

    defp intrinsic(%{"component" => type, rows: [{:model_art, nil, _description}]}),
      do: art_size(type)

    defp intrinsic(%{rows: [{:model_art, animation, _description}]}) do
      minimum =
        case animation.meta.bounds[:cols] do
          {minimum, _maximum} -> minimum
          _fixed -> animation.cols
        end

      {animation.cols, minimum}
    end

    defp natural_width(lines),
      do: lines |> Enum.map(&line_width/1) |> Enum.max(fn -> 1 end) |> max(1)

    defp widest_grapheme(span),
      do:
        span.content |> String.graphemes() |> Enum.map(&Width.grapheme/1) |> Enum.max(fn -> 1 end)

    defp art_size("ProgressBar"), do: {48, 24}
    defp art_size("Sparkline"), do: {72, 40}
    defp art_size("BarChart"), do: {60, 30}
    defp art_size("FileTree"), do: {36, 12}

    defp render(node, available, theme, compact, stretch?) do
      width = allocation(node, available, stretch?)
      padding = Map.get(node, "padding", 0)
      inset = min(padding, div(width - 1, 2))
      compact = Map.get(node, "compact", compact)

      node
      |> content(width - 2 * inset, theme, compact)
      |> Enum.map(&clip(&1, width - 2 * inset))
      |> padded(inset, padding, width)
    end

    defp allocation(node, available, true),
      do: min(Map.get(node, "width", available), available)

    defp allocation(node, available, false), do: min(node.preferred, available)

    defp content(%{"component" => "Column"} = node, width, theme, compact),
      do: column(node, width, theme, compact)

    defp content(%{"component" => "Row"} = node, width, theme, compact) do
      children = node["children"]
      gap = Map.get(node, "gap", 0)
      minimum = Enum.sum(Enum.map(children, & &1.minimum)) + gap * (length(children) - 1)

      if minimum > width,
        do:
          column(
            Map.merge(node, %{"align" => "start", "justify" => "start"}),
            width,
            theme,
            compact
          ),
        else: row(node, width, theme, compact)
    end

    defp content(node, width, theme, compact) do
      lines = RichText.lines(node.rows, width, theme)
      lines = if compact and art?(node), do: Art.compact(lines), else: lines
      align_block(lines, width, Map.get(node, "align", "start"))
    end

    defp art?(%{rows: [{:model_art, _animation, _description}]}), do: true
    defp art?(_node), do: false

    defp column(node, width, theme, compact) do
      align = Map.get(node, "align", "start")
      blocks = Enum.map(node["children"], &column_child(&1, width, theme, compact, align))
      gap = Map.get(node, "gap", 0)
      lines = blocks |> Enum.intersperse(blanks(gap)) |> List.flatten()
      height = max(Map.get(node, "height", 0) - 2 * Map.get(node, "padding", 0), length(lines))
      distribute_vertical(blocks, lines, height, gap, Map.get(node, "justify", "start"))
    end

    defp column_child(child, width, theme, compact, align) do
      inset = offset(max(width - allocation(child, width, align == "stretch"), 0), align)

      child
      |> render(width, theme, compact, align == "stretch")
      |> Enum.map(&Line.new(spaces(inset) ++ styled_spans(&1)))
    end

    defp distribute_vertical(blocks, lines, height, gap, "spaceBetween")
         when length(blocks) > 1 do
      extra = height - length(lines)
      blocks |> spaced_blocks(gap, extra) |> List.flatten()
    end

    defp distribute_vertical(_blocks, lines, height, _gap, justify),
      do: vertical(lines, height, justify)

    defp row(node, width, theme, compact) do
      children = node["children"]
      gap = Map.get(node, "gap", 0)
      widths = row_widths(children, width - gap * (length(children) - 1))
      blocks = Enum.zip_with(children, widths, &render(&1, &2, theme, compact, true))

      height =
        max(
          Map.get(node, "height", 0) - 2 * Map.get(node, "padding", 0),
          Enum.max(Enum.map(blocks, &length/1))
        )

      blocks = Enum.map(blocks, &vertical(&1, height, Map.get(node, "align", "start")))
      extra = width - Enum.sum(widths) - gap * (length(children) - 1)
      combine(blocks, widths, gap, extra, Map.get(node, "justify", "start"), height)
    end

    defp row_widths(children, available) do
      preferred = Enum.map(children, & &1.preferred)

      if Enum.sum(preferred) <= available,
        do: preferred,
        else: grow_widths(Enum.map(children, & &1.minimum), preferred, available)
    end

    defp grow_widths(widths, preferred, available) do
      room = available - Enum.sum(widths)

      if room <= 0 or widths == preferred do
        widths
      else
        {widths, _room} = Enum.zip(widths, preferred) |> Enum.map_reduce(room, &grow_width/2)
        grow_widths(widths, preferred, available)
      end
    end

    defp grow_width({current, preferred}, room) when room > 0 and current < preferred,
      do: {current + 1, room - 1}

    defp grow_width({current, _preferred}, room), do: {current, room}

    defp combine(blocks, widths, gap, extra, justify, height) do
      gaps =
        distributed_gaps(
          length(blocks) - 1,
          gap,
          if(justify == "spaceBetween", do: extra, else: 0)
        )

      inset = offset(extra, justify)

      for index <- 0..(height - 1) do
        spans =
          Enum.zip(blocks, widths)
          |> Enum.map(fn {block, width} -> fill(Enum.at(block, index), width).spans end)

        joined =
          Enum.zip(spans, gaps ++ [0])
          |> Enum.flat_map(fn {spans, gap} -> spans ++ spaces(gap) end)

        Line.new(spaces(inset) ++ joined)
      end
    end

    defp spaced_blocks(blocks, gap, extra) do
      gaps = distributed_gaps(length(blocks) - 1, gap, extra)
      Enum.zip(blocks, gaps ++ [0]) |> Enum.flat_map(fn {block, gap} -> block ++ blanks(gap) end)
    end

    defp distributed_gaps(0, _gap, _extra), do: []

    defp distributed_gaps(count, gap, extra),
      do:
        for(
          index <- 0..(count - 1),
          do: gap + div(extra, count) + if(index < rem(extra, count), do: 1, else: 0)
        )

    defp vertical(lines, height, align) do
      extra = max(height - length(lines), 0)
      before = offset(extra, align)
      blanks(before) ++ lines ++ blanks(extra - before)
    end

    defp align_block(lines, width, align) do
      used = lines |> Enum.map(&line_width/1) |> Enum.max(fn -> 0 end)
      inset = offset(max(width - used, 0), align)
      Enum.map(lines, &Line.new(spaces(inset) ++ styled_spans(&1)))
    end

    defp offset(extra, "center"), do: div(extra, 2)
    defp offset(extra, "end"), do: extra
    defp offset(_extra, _align), do: 0

    defp padded(lines, 0, 0, _width), do: lines

    defp padded(lines, inset, padding, width) do
      body =
        Enum.map(
          lines,
          &Line.new(spaces(inset) ++ fill(&1, width - 2 * inset).spans ++ spaces(inset))
        )

      blanks(padding) ++ body ++ blanks(padding)
    end

    defp blanks(count), do: List.duplicate(Line.new([]), count)
    defp spaces(0), do: []
    defp spaces(count), do: [Span.new(String.duplicate(" ", count))]
    defp line_width(line), do: line.spans |> Enum.map(&Width.of(&1.content)) |> Enum.sum()

    defp fill(line, width),
      do: Line.new(styled_spans(line) ++ spaces(max(width - line_width(line), 0)))

    defp styled_spans(line),
      do: Enum.map(line.spans, &%{&1 | style: merge_style(line.style, &1.style)})

    defp merge_style(base, style),
      do: %Style{
        fg: style.fg || base.fg,
        bg: style.bg || base.bg,
        modifiers: Enum.uniq(base.modifiers ++ style.modifiers)
      }

    defp clip(line, width) do
      {spans, _remaining} = Enum.map_reduce(styled_spans(line), width, &clip_span/2)
      Line.new(spans)
    end

    defp clip_span(span, remaining) do
      {chars, used} =
        String.graphemes(span.content)
        |> Enum.reduce_while({[], 0}, &clip_grapheme(&1, &2, remaining))

      {%{span | content: chars |> Enum.reverse() |> Enum.join()}, remaining - used}
    end

    defp clip_grapheme(grapheme, {chars, used}, remaining) do
      size = Width.grapheme(grapheme)

      if used + size <= remaining,
        do: {:cont, {[grapheme | chars], used + size}},
        else: {:halt, {chars, used}}
    end
  end
end
