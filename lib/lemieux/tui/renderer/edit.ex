# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Edit do
    @moduledoc """
    `edit`: `Editing PATH` while the call is in flight, replaced by `Edited`
    and a numbered, highlighted diff when it lands.

    The change is rebuilt from the `old` and `new` the model sent, so it is
    exact; the line numbers and the context around it come from the edited
    lines the tool returned. See `Lemieux.TUI.ToolText.edit_rows/4`.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?),
      do: [ToolText.heading(id, :edit, "Editing", ToolText.argument(arguments, "path"))]

    @impl Lemieux.TUI.Renderer
    def result(%{id: id, arguments: arguments}, %{output: output}, theme),
      do: {:replace, ToolText.edit_rows(id, arguments, theme, output)}
  end
end
