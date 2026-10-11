if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Subagents do
    @moduledoc """
    Subagents announce themselves by name. Their lifecycle events supply the
    child rows and completion footer, so repeating the tool's JSON envelope
    would show the same result twice and bury the status in opaque IDs. The
    full envelope remains in the transcript and the tool-output pager. The
    historical `delegate` name uses this renderer too.
    """
    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id}, _exploring?), do: [ToolText.heading(id, :subagents, "Subagents:")]

    @impl Lemieux.TUI.Renderer
    def result(_call, %{output: output}, _theme) do
      case JSON.decode(output) do
        {:ok, %{"results" => results, "status" => status}}
        when is_list(results) and is_binary(status) ->
          :none

        _unknown ->
          {:output, output}
      end
    end
  end
end
