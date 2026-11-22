if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.ResumePicker do
    @moduledoc "Searches the host's session index and sends the selected durable ID to resume."

    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.CLI.SessionIndex
    alias Lemieux.Conversation
    alias Lemieux.TUI
    alias Lemieux.TUI.Effects
    alias Lemieux.TUI.Keys
    alias Lemieux.TUI.Modal
    alias Lemieux.TUI.Responsive
    alias Lemieux.TUI.Takeover

    @shown 9

    @doc false
    @spec open(TUI.t(), :here | :all) :: TUI.t()
    def open(state, scope) do
      picker = %{
        kind: :resume_picker,
        scope: scope,
        query: "",
        index: 0,
        matches: [],
        pending: nil,
        error: nil
      }

      state = %{state | modal: picker} |> load_entries(state.resume.sessions)

      case state.resume.list_all do
        nil ->
          state

        list ->
          app = self()
          ref = make_ref()
          Task.start(fn -> send(app, {:resume_picker_index, ref, list.()}) end)
          put_in(state.modal.pending, ref)
      end
    end

    @doc false
    @spec loaded(TUI.t(), reference(), term()) :: TUI.t()
    def loaded(%{modal: %{kind: :resume_picker, pending: ref}} = state, ref, {:ok, sessions}),
      do: state |> put_in([Access.key!(:modal), :pending], nil) |> load_entries(sessions)

    def loaded(%{modal: %{kind: :resume_picker, pending: ref}} = state, ref, {:error, reason}) do
      put_in(state.modal, %{state.modal | pending: nil, error: Conversation.describe(reason)})
    end

    def loaded(state, _ref, _result), do: state

    @doc false
    @spec key(ExRatatui.Event.Key.t(), TUI.t()) :: {:noreply, TUI.t()}
    def key(%ExRatatui.Event.Key{code: tab}, state) when tab in ["tab", "back_tab"],
      do: {:noreply, switch_scope(state)}

    def key(%ExRatatui.Event.Key{code: code, modifiers: modifiers} = event, state) do
      action = Keys.action(state.status.keys, event)

      state =
        case {code, action} do
          {_, action} when action in [:dismiss, :interrupt] -> Modal.close(state)
          {_, :submit} -> choose(state)
          {_, :previous} -> move(state, -1)
          {_, :next} -> move(state, 1)
          {"page_up", _action} -> move(state, -@shown)
          {"page_down", _action} -> move(state, @shown)
          {"backspace", _action} -> filter(state, String.slice(state.modal.query, 0..-2//1))
          {character, _action} -> typed(state, character, modifiers)
        end

      {:noreply, state}
    end

    @doc false
    @spec paste(ExRatatui.Event.Paste.t(), TUI.t()) :: {:noreply, TUI.t()}
    def paste(%ExRatatui.Event.Paste{content: content}, state) do
      {:noreply, filter(state, state.modal.query <> one_line(content))}
    end

    @doc false
    @spec render(TUI.t(), map()) :: list()
    def render(%TUI{modal: picker}, panes) do
      area = Takeover.area(panes, @shown + 5)

      body = %{
        area
        | x: area.x + 1,
          y: area.y + 1,
          width: max(area.width - 2, 0),
          height: max(area.height - 2, 0)
      }

      shown = max(body.height - 3, 0)
      offset = max(picker.index - shown + 1, 0)
      rows = picker.matches |> Enum.slice(offset, shown) |> Enum.with_index(offset)

      choices =
        for {row, index} <- rows do
          cursor = if index == picker.index, do: "› ", else: "  "
          cursor <> if(picker.scope == :here, do: row.here, else: row.all)
        end

      tabs =
        if picker.scope == :here,
          do: "[This folder]   All sessions",
          else: "This folder   [All sessions]"

      choices = if choices == [], do: [empty(picker)], else: choices
      lines = [tabs, "Search: #{picker.query}▏" | choices] ++ [footer(picker)]
      lines = Enum.map(lines, &Responsive.fit(&1, body.width))

      Takeover.frame(area, " Resume session ") ++
        [{%Paragraph{text: Enum.join(lines, "\n")}, body}]
    end

    defp footer(%{pending: ref}) when is_reference(ref), do: "Loading session index… · Esc close"
    defp footer(%{error: error}) when is_binary(error), do: "Session index unavailable · #{error}"
    defp footer(%{matches: []}), do: "Tab switch scope · Esc close"

    defp footer(picker),
      do:
        "#{picker.index + 1}/#{length(picker.matches)} · Tab scope · ↑↓ move · Enter resume · Esc close"

    defp empty(%{pending: ref}) when is_reference(ref), do: "Searching saved sessions…"
    defp empty(%{query: query}) when query != "", do: "No matching sessions"
    defp empty(%{scope: :here}), do: "No previous sessions in this folder"
    defp empty(_picker), do: "No stored sessions"

    defp load_entries(state, sessions) do
      cwd = state.references.cwd
      now = DateTime.utc_now()

      entries =
        sessions
        |> Enum.reject(&(&1.id == state.id))
        |> Enum.uniq_by(& &1.id)
        |> Enum.sort_by(&SessionIndex.activity/1, {:desc, DateTime})
        |> Enum.map(&row(&1, cwd, now))

      state |> put_in([Access.key!(:modal), :entries], entries) |> filter(state.modal.query)
    end

    defp row(session, cwd, now) do
      name = SessionIndex.shorthand(session)
      directory = session.cwd || "directory unknown"

      details = [
        ago(SessionIndex.activity(session), now),
        one_line(session.preview || ""),
        session.model
      ]

      details = Enum.reject(details, &(&1 in [nil, ""]))

      %{
        id: session.id,
        local?: SessionIndex.same_folder?(session.cwd, cwd),
        here: Enum.join([name | details], " · "),
        all: Enum.join([name, directory | details], " · "),
        search: String.downcase(Enum.join([session.id, name, directory | details], " "))
      }
    end

    defp ago(~U[1970-01-01 00:00:00Z], _now), do: nil

    defp ago(at, now) do
      seconds = max(DateTime.diff(now, at), 0)

      cond do
        seconds < 60 -> "just now"
        seconds < 3_600 -> "#{div(seconds, 60)}m ago"
        seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
        seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d ago"
        true -> Calendar.strftime(at, "%Y-%m-%d")
      end
    end

    defp one_line(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

    defp switch_scope(state) do
      scope = if state.modal.scope == :here, do: :all, else: :here
      state |> put_in([Access.key!(:modal), :scope], scope) |> filter(state.modal.query)
    end

    defp filter(%{modal: picker} = state, query) do
      needle = query |> String.trim() |> String.downcase()

      matches =
        Enum.filter(picker.entries, fn entry ->
          (entry.local? or picker.scope == :all) and String.contains?(entry.search, needle)
        end)

      put_in(state.modal, %{picker | query: query, index: 0, matches: matches})
    end

    defp move(state, by),
      do:
        put_in(
          state.modal.index,
          max(min(state.modal.index + by, length(state.modal.matches) - 1), 0)
        )

    defp typed(state, character, modifiers) do
      if String.length(character) == 1 and Enum.all?(modifiers, &(&1 == "shift")),
        do: filter(state, state.modal.query <> character),
        else: state
    end

    defp choose(state) do
      case Enum.at(state.modal.matches, state.modal.index) do
        nil -> state
        row -> Effects.run(Modal.close(state), [{:resume, row.id}]) |> elem(1)
      end
    end
  end
end
