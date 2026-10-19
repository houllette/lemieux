if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Watch do
    @moduledoc """
    Native tracking receipts. A background command already announced its work;
    registering its observer adds no second activity. External runs announce
    their identity once, with subsequent status and output in Tasks. Durable
    tool results retain the full evidence, and ToolText always displays errors.
    """
    @behaviour Lemieux.TUI.Renderer
    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(
          %{
            id: id,
            arguments: %{"action" => "register", "source" => source, "target" => %{} = target}
          },
          _
        )
        when is_binary(source) and source != "background" do
      name = if source == "github", do: ToolText.argument(target, "repository"), else: source
      run = ToolText.argument(target, "run_id", ToolText.argument(target, "task_id"))
      identity = name <> " · run " <> run

      ToolText.background(id, "Tracking " <> ToolText.one_line(identity))
    end

    def call(_call, _exploring?), do: []

    @impl Lemieux.TUI.Renderer
    def result(_call, _result, _theme), do: :none
  end
end
