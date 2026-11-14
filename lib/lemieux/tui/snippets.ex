if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.Snippets do
    @moduledoc "Source-to-cell metadata for snippet copying; frames never become source."
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias Lemieux.TUI.Width

    @doc false
    @spec render(
            text :: String.t(),
            spans :: list() | nil,
            width :: pos_integer(),
            background :: term()
          ) :: [Line.t()]
    def render(text, spans, width, background) do
      styled =
        if is_list(spans) and Enum.map_join(spans, & &1.content) == text,
          do:
            Enum.flat_map(spans, fn span ->
              Enum.map(String.graphemes(span.content), &{&1, span.style})
            end),
          else: Enum.map(String.graphemes(text), &{&1, %Style{}})

      {rows, row, _used} =
        Enum.reduce(styled, {[], [], 0}, fn {source, style}, {rows, row, used} ->
          display = if source == "\t", do: "    ", else: source
          size = Width.of(display)

          cell = %{
            source: source,
            display: display,
            width: size,
            style: %{style | bg: background}
          }

          if used > 0 and used + size > width,
            do: {[Enum.reverse(row) | rows], [cell], size},
            else: {rows, [cell | row], used + size}
        end)

      rows = Enum.reverse([Enum.reverse(row) | rows])

      rows
      |> Enum.with_index()
      |> Enum.map(fn {cells, index} ->
        line = Line.new(Enum.map(cells, &Span.new(&1.display, style: &1.style)))
        Map.put(line, :copy, %{cells: cells, continuation?: index < length(rows) - 1})
      end)
    end

    @doc "Returns the whole source block under a wrapped transcript point, including its frame."
    @spec at(
            lines :: list(),
            point :: {non_neg_integer(), non_neg_integer()},
            renderer :: (term() -> list())
          ) :: term()
    def at(lines, {depth, _column}, renderer), do: find_block(lines, 0, nil, depth, renderer)

    defp find_block([], _offset, _open, _depth, _renderer), do: nil
    defp find_block(_rows, offset, nil, depth, _renderer) when offset > depth, do: nil

    defp find_block([row | rest], offset, open, depth, renderer) do
      next = offset + length(renderer.(row))

      case block_row(row, offset, next, open, depth) do
        {:found, target} -> target
        {:continue, open} -> find_block(rest, next, open, depth, renderer)
      end
    end

    defp block_row({:model_fence, :close, _language, _fence}, offset, _next, _open, _depth),
      do: {:continue, {offset, []}}

    defp block_row({:model_code, _language, text, _spans}, offset, _next, nil, _depth),
      do: {:continue, {offset, [text]}}

    defp block_row(
           {:model_code, _language, text, _spans},
           _offset,
           _next,
           {bottom, source},
           _depth
         ),
         do: {:continue, {bottom, [text | source]}}

    defp block_row(
           {:model_fence, :open, _language, _fence},
           _offset,
           next,
           {bottom, source},
           depth
         )
         when depth >= bottom and depth < next,
         do: {:found, {:snippet, {bottom, next}, Enum.join(source, "\n")}}

    defp block_row({:model_fence, :open, _language, _fence}, _offset, _next, _open, _depth),
      do: {:continue, nil}

    defp block_row(_row, _offset, _next, open, _depth), do: {:continue, open}
  end
end
