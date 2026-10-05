# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Bash do
    @moduledoc """
    `bash`: `Ran` and the command's first line, with its output beneath.

    `ToolText.call/4` decorates the `:run` heading with Bash syntax spans in
    the current theme, before it reaches the draw loop.

    No `result/3`: the generic outcome — output under the heading, capped to
    a few rows with the middle elided — is exactly what a command wants.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?) do
      command = arguments |> ToolText.argument("command") |> ToolText.one_line()

      [ToolText.heading(id, :run, "Ran", command)]
    end
  end
end
