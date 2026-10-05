if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.HistorySearch do
    @moduledoc """
    Ctrl-R: search everything typed before, as a shell's reverse search does.

    Up-arrow walks the session's own inputs one at a time, which is right for
    the last few and hopeless for the prompt somebody wrote last Tuesday in
    another repository. This searches `Lemieux.TUI.History.search/2` — the
    session's inputs, then every earlier sitting's, from the history file —
    and narrows as the query is typed.

    Enter or Tab puts the highlighted entry in the input box to be edited or
    sent; nothing is sent from here. Ctrl-R or ↑ moves to an older match, ↓
    to a newer one, and Esc puts back what was in the box before.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Clear
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.TUI
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Editor
    alias Lemieux.TUI.History
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Screen

    @shown 8

    @doc false
    @spec open(TUI.t()) :: TUI.t()
    def open(state) do
      %{
        state
        | modal: %{kind: :history_search, query: "", index: 0, draft: Composer.typed_value(state)}
      }
    end

    @doc "What the search currently offers, newest first."
    @spec matches(TUI.t()) :: [String.t()]
    def matches(%TUI{modal: %{query: query}} = state), do: History.search(state.history, query)

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(%ExRatatui.Event.Key{code: code, modifiers: modifiers} = event, state) do
      case {code, Keys.action(state.status.keys, event)} do
        {_code, action} when action in [:dismiss, :interrupt] -> {:noreply, cancel(state)}
        {_code, action} when action in [:history_search, :previous] -> {:noreply, step(state, 1)}
        {_code, :next} -> {:noreply, step(state, -1)}
        {_code, action} when action in [:submit, :complete] -> {:noreply, accept(state)}
        {"backspace", _action} -> {:noreply, query(state, &drop_last/1)}
        {character, _action} -> {:noreply, typed(state, character, modifiers)}
      end
    end

    @doc false
    @spec paste(ExRatatui.Event.Paste.t(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(%ExRatatui.Event.Paste{content: content}, state) when is_binary(content),
      do: {:noreply, query(state, &(&1 <> String.replace(content, "\n", " ")))}

    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec render(TUI.t(), map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      found = matches(state)
      rows = min(length(found), @shown)
      height = rows + 4
      input = panes.input
      top = max(input.y - height, panes.transcript.y)

      area = %Rect{
        x: input.x,
        y: top,
        width: input.width,
        height: min(height, input.y - top + input.height)
      }

      theme = Screen.theme(state)

      offset = max(state.modal.index - @shown + 1, 0)

      listed =
        found
        |> Enum.with_index()
        |> Enum.slice(offset, @shown)
        |> Enum.map(fn {entry, index} ->
          selected? = index == state.modal.index
          marker = if selected?, do: "› ", else: "  "

          style =
            if selected?,
              do: %Style{fg: Screen.accent(state), modifiers: [:bold]},
              else: %Style{fg: theme.text.plain}

          Line.new([Span.new(marker <> one_line(entry, area.width - 6), style: style)])
        end)

      prompt =
        Line.new([
          Span.new("search: ", style: %Style{fg: theme.text.muted}),
          Span.new(state.modal.query <> "▏",
            style: %Style{fg: theme.voices.you_text, modifiers: [:bold]}
          )
        ])

      empty =
        if found == [],
          do: [
            Line.new([
              Span.new("  no earlier input contains that", style: %Style{fg: theme.text.muted})
            ])
          ],
          else: []

      panel = %Paragraph{
        text: [prompt | listed] ++ empty,
        block: %Block{
          title: " history (#{length(found)}) ",
          titles: [
            %Block.Title{
              content: " Enter take · Ctrl-R older · Esc back ",
              position: :bottom,
              alignment: :right
            }
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: Screen.accent(state)},
          padding: {1, 1, 0, 0}
        }
      }

      [{%Clear{}, area}, {panel, area}]
    end

    defp typed(state, character, modifiers) do
      if String.length(character) == 1 and not Enum.any?(modifiers, &(&1 in ["ctrl", "alt"])),
        do: query(state, &(&1 <> character)),
        else: state
    end

    defp query(state, change),
      do: %{state | modal: %{state.modal | query: change.(state.modal.query), index: 0}}

    defp drop_last(""), do: ""
    defp drop_last(text), do: String.slice(text, 0, String.length(text) - 1)

    defp step(state, by) do
      count = length(matches(state))
      index = if count == 0, do: 0, else: (state.modal.index + by) |> max(0) |> min(count - 1)
      put_in(state.modal.index, index)
    end

    defp accept(state) do
      case Enum.at(matches(state), state.modal.index) do
        nil ->
          cancel(state)

        entry ->
          :ok = Editor.replace(state.input, entry)
          state |> Modal.close() |> Composer.edited()
      end
    end

    defp cancel(state) do
      :ok = Editor.replace(state.input, state.modal.draft)
      Modal.close(state)
    end

    defp one_line(entry, width) do
      flat = entry |> String.replace(~r/\s+/, " ") |> String.trim()
      width = max(width, 4)
      if String.length(flat) > width, do: String.slice(flat, 0, width - 1) <> "…", else: flat
    end
  end
end
