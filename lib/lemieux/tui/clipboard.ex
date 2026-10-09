if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.Clipboard do
    @moduledoc """
    Copies visualizations as the terminal projects them, within a Markdown fence.

    Only closed, valid visualization fences change. Prose and ordinary source
    remain byte-for-byte text; `/copy source` bypasses this projection. Clipboard
    text has no colour, so a text fence carries the monospace geometry, interior
    blank rows and leading spaces. Projection covers the full answer, independent
    of viewport height. It runs on demand, never in the model loop or render path.
    """
    alias Lemieux.TUI.{A2UI, Diagrams, RichText, Theme}

    @fence ~r/^\s{0,3}(`{3,}|~{3,})\s*([^\s`]*)/u
    @closing ~r/^\s{0,3}(`{3,}|~{3,})\s*$/u

    @doc "Replaces closed visualizations with a colour-free, geometry-preserving text fence."
    @spec presentation(source :: String.t(), width :: pos_integer(), theme :: Theme.t()) ::
            String.t()
    def presentation(source, width, theme) do
      if String.valid?(source) do
        {out, open} =
          source |> String.split("\n") |> Enum.reduce({[], nil}, &line(&1, &2, width, theme))

        out = if open, do: [open.lines |> Enum.reverse() |> Enum.join("\n") | out], else: out
        out |> Enum.reverse() |> Enum.join("\n")
      else
        source
      end
    end

    defp line(line, {out, nil}, _width, _theme) do
      case Regex.run(@fence, line) do
        [_, fence, language] ->
          {out, %{fence: fence, language: String.downcase(language), lines: [line]}}

        _plain ->
          {[line | out], nil}
      end
    end

    defp line(line, {out, open}, width, theme) do
      if closes?(line, open.fence) do
        block = [line | open.lines] |> Enum.reverse()
        {[project(block, open.language, width, theme) | out], nil}
      else
        {out, %{open | lines: [line | open.lines]}}
      end
    end

    defp closes?(line, opener) do
      case Regex.run(@closing, line) do
        [_, fence] ->
          String.first(fence) == String.first(opener) and
            String.length(fence) >= String.length(opener)

        _line ->
          false
      end
    end

    defp project(block, language, width, theme) when language in ["a2ui", "mermaid"] do
      source = block |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join("\n")

      case visualization(language, source) do
        {:ok, rows} -> rows |> RichText.lines(width, theme) |> text() |> fenced()
        _unsupported -> Enum.join(block, "\n")
      end
    end

    defp project(block, _language, _width, _theme), do: Enum.join(block, "\n")
    defp visualization(_language, source) when byte_size(source) > 16_384, do: :error
    defp visualization("a2ui", source), do: A2UI.rows(source)
    defp visualization("mermaid", source), do: Diagrams.rows(source)

    defp text(lines),
      do:
        Enum.map_join(lines, "\n", fn line ->
          Enum.map_join(line.spans, & &1.content) |> String.trim_trailing(" ")
        end)

    defp fenced(text) do
      longest =
        Regex.scan(~r/`+/, text)
        |> Enum.map(fn [run] -> String.length(run) end)
        |> Enum.max(fn -> 0 end)

      fence = String.duplicate("`", max(3, longest + 1))
      fence <> "text\n" <> text <> "\n" <> fence
    end
  end
end
