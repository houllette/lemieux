# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.AskUser do
    @moduledoc """
    `ask_user` uses a dedicated panel while waiting. The transcript keeps a
    compact receipt after the panel closes, without repeating the prompt.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id}, _exploring?), do: [ToolText.heading(id, :ordinary, "Asked user")]

    @impl Lemieux.TUI.Renderer
    def result(
          _call,
          %{payload: %{"structured_content" => %{"answers" => answers, "status" => "answered"}}},
          _theme
        )
        when is_list(answers),
        do: {:answer, "#{length(answers)} answer(s) submitted"}

    def result(_call, %{payload: %{"structured_content" => %{"answers" => [first | _]}}}, _theme),
      do: {:answer, "question #{first["status"] || "incomplete"}"}

    def result(_call, %{output: answer}, _theme), do: {:answer, answer}
  end
end
