if Code.ensure_loaded?(ExRatatui.Text.Line) do
  defmodule Lemieux.TUI.TranscriptSpacing do
    @moduledoc """
    One blank row between transcript groups, shared by live delivery and
    replay. Output stays attached to its call and consecutive exploration
    details stay together. Spaces are actual rows so scrolling, selection
    and links count the same cells that the screen draws.
    """

    alias Lemieux.TUI.Blocks
    alias Lemieux.TUI.ToolText

    @doc "Separates chronological rows from each other and the preceding row."
    @spec separate(rows :: [term()], previous :: term()) :: [term()]
    def separate(rows, previous) do
      {groups, _last} =
        Enum.map_reduce(rows, previous, fn row, previous ->
          rows = if boundary?(row, previous), do: [{:space, ""}, row], else: [row]
          {rows, row}
        end)

      List.flatten(groups)
    end

    defp boundary?(_row, nil), do: false
    defp boundary?(_row, {:space, _text}), do: false

    defp boundary?({:tool_heading, id, _kind, _verb, _subject}, previous),
      do: is_nil(id) or ToolText.call_id(previous) != id

    defp boundary?({:tool_heading, id, :run, _verb, _subject, _spans}, previous),
      do: ToolText.call_id(previous) != id

    defp boundary?({:tool_question, id, _text}, previous), do: ToolText.call_id(previous) != id

    defp boundary?({:you, _text}, previous),
      do: Blocks.model_row?(previous) or tool_group?(previous) or match?({:lmx, _}, previous)

    defp boundary?(row, previous), do: Blocks.model_row?(row) and tool_group?(previous)

    defp tool_group?({:subagent_child, _child}), do: true
    defp tool_group?({:subagent_summary, _status, _text}), do: true
    defp tool_group?({:summary, _text}), do: true
    defp tool_group?({:compact_result, _text}), do: true
    defp tool_group?(row), do: ToolText.row?(row)
  end
end
