defmodule Lemieux.TUI.Responsive do
  @moduledoc "Width-aware chrome: static when it fits, slowly looping when it does not."
  alias Lemieux.TUI.Width

  @doc "Shows a cell-width window, advancing one grapheme per second on the blink clock."
  @spec scroll(text :: String.t(), width :: non_neg_integer(), frame :: non_neg_integer()) ::
          String.t()
  def scroll(_text, width, _frame) when width <= 0, do: ""

  def scroll(text, width, frame) do
    if Width.of(text) <= width do
      text
    else
      chars = String.graphemes(text <> "   ·   ")
      offset = rem(div(frame, 2), length(chars))
      loop = Enum.drop(chars, offset) ++ chars
      loop |> Enum.join() |> Width.split(width) |> elem(0)
    end
  end
end
