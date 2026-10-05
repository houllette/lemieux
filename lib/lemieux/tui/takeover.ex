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
