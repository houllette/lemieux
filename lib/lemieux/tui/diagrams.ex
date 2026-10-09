if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.Diagrams do
    @moduledoc """
    Cached native diagrams with width-only projection and semantic fallback.

    Preparing frames and terminal spans happens when a fence closes, never
    during drawing. The same pure selection supplies drawing and scroll height.
    Diagrams preserve their interior whitespace and never pass through gallery
    compaction or connector clipping. Colours come from the terminal theme.
    """
    alias Lemieux.Extensions.A2UI.Diagram
    alias Lemieux.TUI.RichText
    alias Lemieux.TUI.Theme

    @doc "Compiles a closed Mermaid fence using the same catalog adapter."
    @spec rows(source :: String.t()) :: {:ok, [tuple()]} | {:error, String.t()} | :error
    def rows(source) do
      with {:ok, prepared} <- prepare(%{"component" => "MermaidDiagram", "source" => source}),
           do: {:ok, [{:model_diagram, prepared}]}
    end

    @doc "Prepares native frames and terminal spans once."
    @spec prepare(node :: map()) :: {:ok, map()} | {:error, String.t()} | :error
    def prepare(node) do
      with {:ok, prepared} <- Diagram.prepare(node) do
        {:ok, project(prepared)}
      end
    end

    @doc "Converts already prepared frames to terminal spans without compiling diagrams again."
    @spec project(prepared :: map()) :: map()
    def project(prepared) do
      variants =
        Enum.map(prepared.variants, fn variant ->
          variant |> Map.put(:lines, frame_lines(variant.frame)) |> Map.drop([:frame, :layout])
        end)

      %{prepared | variants: variants}
    end

    @doc "Intrinsic and minimum whole-diagram widths, or textual fallback measurements."
    @spec size(prepared :: map()) :: {pos_integer(), pos_integer()}
    def size(%{variants: []}), do: {80, 12}

    def size(prepared),
      do:
        {Enum.max(Enum.map(prepared.variants, & &1.cols)),
         Enum.min(Enum.map(prepared.variants, & &1.cols))}

    @doc "Selects complete cached geometry and applies the current palette."
    @spec lines(prepared :: map(), width :: pos_integer(), theme :: Theme.t()) :: [
            ExRatatui.Text.Line.t()
          ]
    def lines(prepared, width, theme) do
      case Diagram.select(prepared, width) do
        nil ->
          prepared.summary
          |> String.split("\n")
          |> Enum.map(&{:lmx, &1})
          |> RichText.lines(width, theme)

        variant ->
          RichText.lines([{:lmx, prepared.title}], width, theme)
          |> title_lines(prepared.title)
          |> Kernel.++(Enum.map(variant.lines, &tint(&1, theme)))
      end
    end

    defp title_lines(_lines, ""), do: []
    defp title_lines(lines, _title), do: lines

    defp tint(line, theme),
      do: %{
        line
        | spans:
            Enum.map(
              line.spans,
              &%{&1 | style: %{&1.style | fg: ink(&1.style.fg, theme), bg: nil}}
            )
      }

    defp ink(_colour, %{name: "mono"}), do: nil
    defp ink({:rgb, 88, 166, 255}, theme), do: theme.accent
    defp ink({:rgb, 201, 209, 217}, theme), do: theme.text.plain
    defp ink({:rgb, 139, 148, 158}, theme), do: theme.text.muted
    defp ink({:rgb, 210, 153, 34}, theme), do: theme.blocks.heading
    defp ink({:rgb, 188, 140, 255}, theme), do: theme.blocks.quote
    defp ink({:rgb, 63, 185, 80}, theme), do: theme.children.ok
    defp ink(_colour, theme), do: theme.text.plain

    if Code.ensure_loaded?(Ascii.ExRatatui) do
      defp frame_lines(frame), do: Ascii.ExRatatui.lines(frame, ground: false)
    else
      defp frame_lines(_frame), do: []
    end
  end
end
