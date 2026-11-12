if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.QuestionSelection do
    @moduledoc """
    Selection in question content, independent of staged answers and the editor.

    Points use the rendered, wrapped rows and their scroll offsets. The panel
    supplies source joins and prefix lengths, so copying rejoins soft wraps
    and drops answer markers without changing hit-testing or highlighting.
    """
    alias ExRatatui.Style
    alias Lemieux.TUI.Flash
    alias Lemieux.TUI.Pointer
    alias Lemieux.TUI.QuestionPanel
    alias Lemieux.TUI.Screen
    alias Lemieux.TUI.Selection
    alias Lemieux.TUI.Width

    @doc false
    @spec mouse(ExRatatui.Event.Mouse.t(), map()) :: tuple()
    def mouse(event, state) do
      panel = QuestionPanel.area(state.tools.question_flow, Screen.panes(state))
      selection = Map.get(state.tools.question_flow, :selection)

      cond do
        event.y < panel.y and event.kind in ["down", "scroll_up", "scroll_down"] ->
          flow = Map.delete(state.tools.question_flow, :selection)
          Pointer.mouse(event, put_in(state.tools.question_flow, flow))

        is_nil(selection) and event.kind in ["drag", "up"] ->
          Pointer.mouse(event, state)

        true ->
          panel_mouse(event, state)
      end
    end

    defp panel_mouse(event, state) do
      flow = state.tools.question_flow
      panes = Screen.panes(state)
      views = QuestionPanel.selection_views(flow, panes)
      view = Enum.find(Map.values(views), &(&1 && inside?(&1.area, event)))
      selection = Map.get(flow, :selection)

      panel_event(event, state, flow, panes, views, view, selection)
    end

    defp panel_event(%{kind: kind}, state, flow, panes, _views, view, _selection)
         when kind in ["scroll_up", "scroll_down"] do
      by = if kind == "scroll_up", do: -3, else: 3
      flow = scroll_panel(flow, panes, view, by)
      {:noreply, put_in(state.tools.question_flow, flow)}
    end

    defp panel_event(
           %{kind: "down", button: "left"} = event,
           state,
           flow,
           _panes,
           _views,
           view,
           _selection
         )
         when not is_nil(view) do
      selection = %{
        region: view.region,
        signature: view.signature,
        range: Selection.start(point(view, event))
      }

      state = %{state | selection: nil}
      {:noreply, put_in(state.tools.question_flow, Map.put(flow, :selection, selection))}
    end

    defp panel_event(
           %{kind: "drag", button: "left"} = event,
           state,
           flow,
           _panes,
           views,
           _view,
           selection
         )
         when not is_nil(selection) do
      view = Map.get(views, selection.region)

      if valid?(selection, view) do
        next = %{selection | range: Selection.extend(selection.range, point(view, event))}
        {:noreply, put_in(state.tools.question_flow.selection, next)}
      else
        {:noreply, put_in(state.tools.question_flow, Map.delete(flow, :selection))}
      end
    end

    defp panel_event(%{kind: "up", button: "left"}, state, _flow, _panes, views, _view, selection)
         when not is_nil(selection) do
      view = Map.get(views, selection.region)
      text = if valid?(selection, view), do: selected_text(selection.range, view), else: ""
      {:noreply, copy(state, text)}
    end

    defp panel_event(_event, state, _flow, _panes, _views, _view, _selection),
      do: {:noreply, state}

    defp scroll_panel(flow, _panes, %{region: :visual} = view, by),
      do:
        Map.put(
          flow,
          :visual_scroll,
          min(max(view.scroll + by, 0), max(length(view.rows) - view.area.height, 0))
        )

    defp scroll_panel(flow, panes, _view, by), do: QuestionPanel.scroll(flow, panes, by)

    @doc false
    @spec keyboard_copy(state :: map()) :: tuple()
    def keyboard_copy(state) do
      flow = state.tools.question_flow
      views = QuestionPanel.selection_views(flow, Screen.panes(state))
      selection = Map.get(flow, :selection)

      text =
        if selection && valid?(selection, Map.get(views, selection.region)) &&
             not Selection.empty?(selection.range),
           do: selected_text(selection.range, Map.fetch!(views, selection.region)),
           else: QuestionPanel.copy_text(flow)

      {:noreply, copy(state, text)}
    end

    @doc false
    @spec highlight(flow :: map(), view :: map()) :: list()
    def highlight(flow, view) do
      selection = Map.get(flow, :selection)

      if selection && selection.region == view.region && valid?(selection, view),
        do:
          Selection.highlight(selection.range, %{rows: view.rows, bottom: 0}, %Style{
            modifiers: [:reversed]
          }),
        else: view.rows
    end

    defp valid?(_selection, nil), do: false
    defp valid?(selection, view), do: selection.signature == view.signature

    defp inside?(area, event),
      do:
        event.x >= area.x and event.x < area.x + area.width and
          event.y >= area.y and event.y < area.y + area.height

    defp point(view, event) do
      row = min(max(event.y - view.area.y + view.scroll, 0), max(length(view.rows) - 1, 0))
      text = Enum.at(view.meta, row, %{text: ""}).text
      column = grapheme_column(text, max(event.x - view.area.x, 0))
      {max(length(view.rows) - row - 1, 0), column}
    end

    defp grapheme_column(text, cells) do
      text
      |> String.graphemes()
      |> Enum.reduce_while({0, 0}, fn grapheme, {column, width} ->
        if width + Width.of(grapheme) > cells,
          do: {:halt, {column, width}},
          else: {:cont, {column + 1, width + Width.of(grapheme)}}
      end)
      |> elem(0)
    end

    defp selected_text(range, view) do
      if Selection.empty?(range) do
        ""
      else
        {{first, from}, {last, to}} = Selection.range(range)
        top = length(view.rows) - first - 1
        bottom = length(view.rows) - last - 1

        top..bottom
        |> Enum.map_join(fn index ->
          row = Enum.at(view.meta, index)
          selected_row(row, index, top, bottom, from, to)
        end)
      end
    end

    defp selected_row(row, index, top, bottom, from, to) do
      start = max(if(index == top, do: from, else: 0), row.prefix)
      finish = if index == bottom, do: to, else: max(String.length(row.text) - 1, 0)
      part = if finish < start, do: "", else: String.slice(row.text, start..finish)
      if(index == top, do: "", else: row.join) <> part
    end

    defp copy(state, ""), do: state

    defp copy(state, text) do
      notice =
        case state.terminal.clipboard.(text) do
          :ok -> "copied #{String.length(text)} characters"
          _error -> "could not copy question text; clipboard unavailable"
        end

      Flash.show(state, notice)
    end
  end
end
