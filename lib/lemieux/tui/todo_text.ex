if Code.ensure_loaded?(ExRatatui.Style) do
  defmodule Lemieux.TUI.TodoText do
    @moduledoc "The status vocabulary shared by todo receipts and the persistent list."

    alias ExRatatui.Style
    alias Lemieux.TUI.Theme

    @doc "A glyph, readable label and semantic style, including in monochrome."
    @spec status(status :: String.t(), theme :: Theme.t()) :: {String.t(), Style.t()}
    def status("completed", theme),
      do: {"✓ Completed", %Style{fg: theme.children.ok, modifiers: [:bold]}}

    def status("in_progress", theme),
      do: {"◐ In progress", %Style{fg: theme.voices.activity, modifiers: [:bold]}}

    def status(_pending, theme),
      do: {"○ Pending", %Style{fg: theme.children.warn, modifiers: [:bold]}}
  end
end
