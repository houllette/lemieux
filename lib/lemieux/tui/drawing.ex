if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.Drawing do
    @moduledoc """
    One bounded placeholder for an open visualization fence.

    The event-sourced answer keeps the exact source independently. Holding one
    display row prevents streamed JSON from filling the viewport, and retaining
    at most 16 KiB here prevents an oversized answer from becoming a second
    unbounded copy. No partial document is compiled or rendered.
    """
    @limit 16_384

    @doc false
    @spec new(language :: String.t(), fence :: String.t(), caption :: String.t()) :: map()
    def new(language, fence, caption) do
      %{
        language: language,
        fence: fence,
        description: caption(caption, language),
        lines: [],
        current: nil,
        bytes: 0,
        oversized?: false
      }
    end

    @doc false
    @spec next(drawing :: map(), text :: String.t()) :: map()
    def next(drawing, text) do
      drawing =
        if drawing.current == nil or drawing.oversized?,
          do: drawing,
          else: complete_line(drawing)

      extend(%{drawing | current: ""}, text)
    end

    @doc false
    @spec extend(drawing :: map(), text :: String.t()) :: map()
    def extend(drawing, text) do
      current = drawing.current || ""

      current =
        if drawing.oversized?, do: current <> String.slice(text, 0, 128), else: current <> text

      size = drawing.bytes + byte_size(current) + if(drawing.lines == [], do: 0, else: 1)
      # Delimiters are not source. A complete 16 KiB document must still
      # accept its closing fence; keep only a bounded prefix for that purpose.
      closer? = byte_size(current) <= 128 and Regex.match?(~r/^\s{0,3}(`+|~+)\s*$/u, current)
      oversized? = drawing.oversized? or (size > @limit and not closer?)

      %{
        drawing
        | current: if(oversized?, do: String.slice(current, 0, 128), else: current),
          lines: if(oversized?, do: [], else: drawing.lines),
          oversized?: oversized?
      }
    end

    defp complete_line(drawing) do
      bytes = drawing.bytes + byte_size(drawing.current) + if(drawing.lines == [], do: 0, else: 1)

      %{
        drawing
        | lines: [drawing.current | drawing.lines],
          bytes: bytes,
          oversized?: bytes > @limit
      }
    end

    @doc false
    @spec source(drawing :: map()) :: String.t()
    def source(drawing), do: drawing.lines |> Enum.reverse() |> Enum.join("\n")

    @doc false
    @spec failure(drawing :: map()) :: String.t()
    def failure(%{oversized?: true}), do: "Visualization exceeds the 16 KiB fence limit."
    def failure(_drawing), do: "Missing closing fence; the drawing was not completed."

    defp caption("", "a2ui"), do: "A2UI visualization"
    defp caption("", "mermaid"), do: "diagram"

    defp caption(text, _language),
      do:
        text
        |> String.replace(~r/[\x00-\x1f\x7f]|\s+/u, " ")
        |> String.trim()
        |> String.slice(0, 96)
  end
end
