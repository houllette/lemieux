# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Elixir do
    @moduledoc """
    `elixir`: `Evaluated Elixir` with the expression beneath, and the value
    it returned as output.

    The expression is under whichever key the evaluator took it as — `code`
    or `expression` — with the first string argument as the last resort, so
    a renamed parameter shows something rather than nothing.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?),
      do: [
        ToolText.heading(id, :eval, "Evaluated Elixir")
        | ToolText.detail(id, expression(arguments))
      ]

    defp expression(arguments) do
      ToolText.argument(
        arguments,
        "code",
        ToolText.argument(arguments, "expression", ToolText.summarise(arguments))
      )
    end
  end
end
