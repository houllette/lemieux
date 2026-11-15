defmodule Lemieux.TUI.Responsive do
  @moduledoc "Width-aware chrome: static when it fits, slowly looping when it does not."
  alias Lemieux.TUI.Width

  @doc "Keeps screen identity fixed while overflowing metadata loops to its right."
  @spec header(
          identity :: String.t(),
          metadata :: String.t(),
          width :: non_neg_integer(),
          frame :: non_neg_integer()
        ) :: String.t()
  def header(identity, _metadata, width, _frame) when width < 8, do: fit(identity, width)

  def header(identity, metadata, width, frame) do
    text = identity <> " · " <> metadata <> " "

    if Width.of(text) <= width do
      text
    else
      # A long identity must leave some room for metadata. Its shortened form
      # stays fixed too; scrolling the full prefix would hide the workspace.
      budget =
        if Width.of(identity) + 3 < width,
          do: Width.of(identity),
          else: max(width - min(16, div(width, 3)) - 3, 0)

      fixed = fit(identity, budget) <> " · "
      fixed <> scroll(metadata, max(width - Width.of(fixed), 0), frame)
    end
  end

  @doc "Shortens over-wide text with an ellipsis without splitting a grapheme."
  @spec fit(text :: String.t(), width :: non_neg_integer()) :: String.t()
  def fit(_text, width) when width <= 0, do: ""

  def fit(text, width) do
    if Width.of(text) <= width do
      text
    else
      {prefix, _rest} = Width.split(text, width - 1)
      if Width.of(prefix) < width, do: prefix <> "…", else: "…"
    end
  end

  @doc "Shows a cell-width window, advancing one grapheme per two screen-clock frames."
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
