# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Read do
    @moduledoc """
    `read`: one line under an `Explored` heading, shared with the reads
    around it, and nothing when the result arrives.

    The file's contents are the one output nobody wants in the transcript —
    the model read it, the person has it open — so the result adds no rows.
    A failed read still shows its error, as every failure does.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, exploring?),
      do: ToolText.exploration(id, "Read #{ToolText.argument(arguments, "path")}", exploring?)

    @impl Lemieux.TUI.Renderer
    def result(_call, _result, _theme), do: :none
  end
end
