# Guarded as `Lemieux.TUI.ToolText` is: rows are built through it, and it
# only exists with the optional terminal dependency.
if Code.ensure_loaded?(ExRatatui.CodeBlock) do
  defmodule Lemieux.TUI.Renderer.Bash do
    @moduledoc """
    `bash`: `Ran` and the command's first line, with its output beneath.

    `ToolText.call/4` decorates the `:run` heading with Bash syntax spans in
    the current theme, before it reaches the draw loop.

    Background launches share a compact group. Their launch receipt is model
    guidance, while status and output belong in the native Tasks view.
    """

    @behaviour Lemieux.TUI.Renderer

    alias Lemieux.Background.Label
    alias Lemieux.ID.Shorthand
    alias Lemieux.TUI.ToolText

    @impl Lemieux.TUI.Renderer
    def call(%{id: id, arguments: arguments}, _exploring?) do
      command = arguments |> ToolText.argument("command") |> ToolText.one_line()

      if arguments["background"] == true,
        do: [
          ToolText.heading(nil, :background, "Background tasks:"),
          ToolText.task(id, nil, Label.summary(arguments["summary"]), "queued")
        ],
        else: [ToolText.heading(id, :run, "Ran", command)]
    end

    @impl Lemieux.TUI.Renderer
    def result(%{id: id, arguments: %{"background" => true} = args}, %{payload: payload}, _theme) do
      case payload["structured_content"] do
        %{"background_tracking_error" => error} when is_binary(error) ->
          {:output, "Tracking unavailable: #{ToolText.one_line(error)}"}

        %{"task_id" => task_id, "status" => "running"} = facts when is_binary(task_id) ->
          name = facts["task_name"] || Shorthand.of(task_id)

          {:update,
           [
             ToolText.task(
               id,
               name,
               Label.summary(facts["summary"] || args["summary"]),
               "running"
             )
           ]}

        _other ->
          {:output, payload["output"] || ""}
      end
    end

    def result(_call, %{output: output}, _theme), do: {:output, output}
  end
end
