# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Write do
    @moduledoc """
    `write`: `Writing PATH` in flight, then `Wrote` and the new file's first
    lines, numbered, as additions — or `Overwrote`, which becomes a diff from
    the replaced contents once `Lemieux.TUI.WriteDiff` has read them from the
    call's checkpoint.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?),
      do: [ToolText.heading(id, :write, "Writing", ToolText.argument(arguments, "path"))]

    @impl Lemieux.TUI.Renderer
    def result(%{id: id, arguments: arguments}, %{output: output}, theme),
      do: {:replace, ToolText.write_rows(id, arguments, theme, output)}
  end
end
