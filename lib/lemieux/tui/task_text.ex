if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.TaskText do
    @moduledoc "Semantic typography for the task inspector; shell source and process output remain literal."
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias Lemieux.TUI.{RichText, Theme}

    @doc false
    @spec colour(row :: map(), theme :: Theme.t()) :: Theme.colour()
    def colour(%{running?: true}, theme), do: theme.tools.run
    def colour(%{watching?: true}, theme), do: theme.tools.run
    def colour(%{status: "success"}, theme), do: theme.children.ok

    def colour(row, theme) do
      if String.contains?(row.status, "fail"), do: theme.children.fail, else: theme.text.muted
    end

    @doc false
    @spec details(row :: map() | nil, width :: pos_integer(), theme :: Theme.t()) :: [Line.t()]
    def details(nil, _width, _theme), do: []

    def details(row, width, theme) do
      heading = %Line{
        spans: [
          %Span{
            content: row[:name] || row.label,
            style: %Style{fg: theme.children.name, modifiers: [:bold]}
          },
          %Span{
            content: " · " <> Map.get(row, :status_label, row.status),
            style: %Style{fg: colour(row, theme), modifiers: [:bold]}
          },
          %Span{
            content: if(row[:elapsed] in [nil, ""], do: "", else: " · " <> row.elapsed),
            style: %Style{fg: theme.text.muted}
          }
        ]
      }

      purpose =
        RichText.literal(row[:description] || "", width, %Style{fg: theme.text.plain})
        |> Enum.take(2)

      context =
        [
          row[:owner_label],
          mode(row),
          row[:tracking_label],
          row[:statistics],
          if(row.target["sha"], do: "Commit: #{row.target["sha"]}"),
          if(row[:deadline], do: "Deadline: #{row.deadline}"),
          row[:summary],
          if(length(Map.get(row, :history, [])) > 1,
            do: "Tracking: " <> Enum.join(row.history, " → ")
          )
        ]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.flat_map(&RichText.literal(&1, width, %Style{fg: theme.text.muted}))

      [heading] ++ purpose ++ [%Line{}] ++ context
    end

    defp mode(%{kind: :agent} = row), do: row[:role]
    defp mode(%{watching?: false, running?: false}), do: nil
    defp mode(%{managed?: true}), do: "Completion managed by assignment"
    defp mode(%{follow_up?: true}), do: "Auto-resume on completion"
    defp mode(_row), do: "Notification only"

    @doc false
    @spec lines(
            text :: String.t(),
            content :: atom(),
            kind :: atom() | nil,
            width :: pos_integer(),
            theme :: Theme.t()
          ) :: [Line.t()]
    def lines(text, :command, _kind, width, theme),
      do: RichText.literal(text, width, %Style{fg: theme.blocks.code, bg: theme.blocks.code_bg})

    def lines(text, content, kind, width, theme)
        when content == :instructions or kind == :agent do
      text |> String.trim("\n") |> String.split("\n") |> Enum.flat_map(&prose(&1, width, theme))
    end

    def lines(text, _content, _kind, width, theme) do
      text
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        RichText.literal(line, width, output_style(line, theme))
      end)
    end

    defp prose(text, width, theme) do
      case Regex.run(~r/^\s*\#{1,6}\s+(.+)$/, text) do
        [_, heading] -> RichText.lines([{:model_heading, 3, heading}], width, theme)
        _plain -> RichText.lines([{:model, text}], width, theme)
      end
    end

    defp output_style(text, theme) do
      cond do
        Regex.match?(
          ~r/^\s*(?:\[[^\]]+\]\s*)?(?:error|fatal|fail\w*|validation_failed|traceback)\b/i,
          text
        ) ->
          %Style{fg: theme.children.fail, modifiers: [:bold]}

        Regex.match?(~r/^\s*(?:\[[^\]]+\]\s*)?warn\w*\b/i, text) ->
          %Style{fg: theme.children.warn, modifiers: [:bold]}

        Regex.match?(~r/^\s*(?:\[[^\]]+\]\s*)?(?:ok|pass\w*|success\w*)\b/i, text) ->
          %Style{fg: theme.children.ok}

        true ->
          %Style{fg: theme.text.plain}
      end
    end
  end
end
