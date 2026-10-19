if Code.ensure_loaded?(ExRatatui.Layout.Rect) do
  defmodule Lemieux.TUI.Takeover do
    @moduledoc "Shared geometry and frame for TUI takeover panels."

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear

    @doc "Anchors a panel at the bottom of the working area."
    @spec area(panes :: map(), rows :: pos_integer()) :: Rect.t()
    def area(panes, rows) do
      bottom = panes.input.y + panes.input.height
      height = min(rows, bottom - panes.transcript.y)
      %Rect{x: panes.input.x, y: bottom - height, width: panes.input.width, height: height}
    end

    @doc "Grows upward from the composer, keeping part of the transcript visible."
    @spec tray(panes :: map(), rows :: non_neg_integer()) :: Rect.t()
    def tray(panes, rows) do
      available = max(min(panes.input.y - panes.transcript.y, panes.transcript.height), 0)
      keep = if available >= 9, do: max(div(available, 3), 3), else: min(available, 1)
      height = min(rows, max(available - keep, 0))
      %Rect{x: panes.input.x, y: panes.input.y - height, width: panes.input.width, height: height}
    end

    @doc "Clears and frames a panel so other content can be drawn over it."
    @spec frame(area :: Rect.t(), title :: String.t()) :: [{term(), Rect.t()}]
    def frame(area, title) do
      [
        {%Clear{}, area},
        {%Block{title: title, borders: [:all], border_type: :rounded}, area}
      ]
    end
  end
end
