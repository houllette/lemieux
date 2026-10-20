if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.ToolsPanel do
    @moduledoc """
    Session tool switches in a content-sized tray above the composer.

    The catalog and mutations run outside the UI callback. Replies belong to
    one opening and session, so closing or changing sessions cannot reopen an
    old tray. Catalog visibility is not permission: host command policy and the
    session's tool profile still authorize every change. The session retains its
    durable configuration and model-facing catalog notice; navigation and switch
    receipts are UI state, never chat messages.
    """
    alias ExRatatui.Event.{Key, Mouse}
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.{Conversation, Session, TUI}
    alias Lemieux.TUI.{Choices, Modal, RichText, Screen, Takeover}

    @doc false
    @spec open(state :: TUI.t()) :: TUI.t()
    def open(state), do: state |> initialize() |> refresh()

    defp initialize(state) do
      state
      |> Map.put(:modal, %{
        kind: :tools,
        session: state.session,
        token: nil,
        selected: nil,
        rows: [],
        query: "",
        notice: nil,
        result_notice: nil,
        loading?: false
      })
      |> rows()
    end

    @doc false
    @spec refresh(state :: TUI.t()) :: TUI.t()
    def refresh(%{modal: %{kind: :tools, token: nil}} = state),
      do: request(state, nil, fn -> {:ok, Session.tool_status(state.session)} end)

    def refresh(state), do: state

    @doc false
    @spec sync(state :: TUI.t()) :: TUI.t()
    def sync(%{modal: %{kind: :tools}} = state), do: rows(state)
    def sync(state), do: state

    defp request(%{session: nil} = state, _notice, _work),
      do: put_in(state.modal.notice, "This session is disconnected.")

    defp request(state, notice, work) do
      app = self()
      session = state.session
      token = make_ref()

      task = fn ->
        result =
          try do
            work.()
          catch
            :exit, _reason -> {:error, :session_disconnected}
          end

        send(app, {:tools_panel_result, session, token, result})
      end

      if state.resume.task_supervisor,
        do: Task.Supervisor.start_child(state.resume.task_supervisor, task),
        else: Task.start(task)

      put_in(state.modal, %{
        state.modal
        | token: token,
          notice: if(notice, do: "Updating tools…"),
          result_notice: notice,
          loading?: true
      })
    end

    @doc false
    @spec answer(state :: TUI.t(), session :: pid(), token :: reference(), result :: term()) ::
            TUI.t()
    def answer(
          %{session: session, modal: %{kind: :tools, session: session, token: token}} = state,
          session,
          token,
          {:ok, statuses}
        ) do
      state
      |> Choices.put_tool_statuses(statuses)
      |> put_in([Access.key!(:modal), :token], nil)
      |> put_in([Access.key!(:modal), :loading?], false)
      |> put_in([Access.key!(:modal), :notice], state.modal.result_notice)
      |> rows()
    end

    def answer(
          %{session: session, modal: %{kind: :tools, session: session, token: token}} = state,
          session,
          token,
          {:error, reason}
        ),
        do:
          put_in(state.modal, %{
            state.modal
            | token: nil,
              loading?: false,
              notice: describe(reason)
          })

    def answer(state, _session, _token, _result), do: state

    defp rows(state) do
      query = String.downcase(state.modal.query)

      rows =
        Choices.tool_statuses(state)
        |> Enum.filter(&String.contains?(String.downcase(&1.name <> " " <> source(&1)), query))
        |> Enum.sort_by(&String.downcase(&1.name))

      selected =
        if Enum.any?(rows, &(&1.name == state.modal.selected)),
          do: state.modal.selected,
          else: List.first(rows) && hd(rows).name

      put_in(state.modal, %{state.modal | rows: rows, selected: selected})
    end

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(%Key{code: "esc"}, state), do: {:noreply, Modal.close(state)}
    def key(%Key{code: "c", modifiers: ["ctrl"]}, state), do: {:noreply, Modal.close(state)}
    def key(%Key{code: "r", modifiers: ["ctrl"]}, state), do: {:noreply, refresh(state)}

    def key(%Key{code: code, modifiers: []}, state) when code in ["enter", " "],
      do: {:noreply, toggle(state)}

    def key(%Key{code: code, modifiers: []}, state)
        when code in ["up", "down", "page_up", "page_down", "home", "end"] do
      by =
        %{
          "up" => -1,
          "down" => 1,
          "page_up" => -10,
          "page_down" => 10,
          "home" => -100_000,
          "end" => 100_000
        }[code]

      {:noreply, select(state, by)}
    end

    def key(%Key{code: "backspace", modifiers: []}, state),
      do: {:noreply, filter(state, String.slice(state.modal.query, 0..-2//1))}

    def key(%Key{code: code, modifiers: modifiers}, state) when modifiers in [[], ["shift"]] do
      if String.length(code) == 1,
        do: {:noreply, filter(state, state.modal.query <> code)},
        else: {:noreply, state}
    end

    def key(_event, state), do: {:noreply, state}

    @doc false
    @spec paste(event :: ExRatatui.Event.Paste.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(event, state), do: {:noreply, filter(state, state.modal.query <> event.text)}

    defp filter(state, query),
      do:
        state
        |> put_in([Access.key!(:modal), :query], clean(query) |> String.slice(0, 100))
        |> put_in([Access.key!(:modal), :notice], nil)
        |> rows()

    defp select(state, by) do
      rows = state.modal.rows
      index = Enum.find_index(rows, &(&1.name == state.modal.selected)) || 0
      selected = Enum.at(rows, min(max(index + by, 0), max(length(rows) - 1, 0)))
      put_in(state.modal, %{state.modal | selected: selected && selected.name, notice: nil})
    end

    defp selected(state), do: Enum.find(state.modal.rows, &(&1.name == state.modal.selected))

    defp toggle(%{modal: %{token: token}} = state) when not is_nil(token), do: state

    defp toggle(state) do
      case selected(state) do
        nil -> state
        row -> change(state, [row.name], not row.enabled?)
      end
    end

    @doc false
    @spec change(state :: TUI.t(), names :: [String.t()], enabled? :: boolean()) :: TUI.t()
    def change(%{modal: %{kind: :tools}} = state, names, enabled?),
      do: change_tools(state, names, enabled?)

    def change(state, names, enabled?), do: state |> initialize() |> change_tools(names, enabled?)

    defp change_tools(state, names, enabled?) do
      action = if enabled?, do: :enable_tools, else: :disable_tools

      case decision(state, names, enabled?) do
        :allow ->
          notice =
            "#{Enum.join(names, ", ")} #{if enabled?, do: "activated", else: "deactivated"}."

          request(state, notice, fn ->
            set_access(state.session, action, names)
          end)

        {:deny, reason} ->
          put_in(state.modal.notice, reason)
      end
    end

    defp set_access(session, action, names) do
      with {:ok, _names} <- apply(Session, action, [session, names]),
           do: {:ok, Session.tool_status(session)}
    end

    defp decision(%{conversation: %{busy?: true}}, _names, _enabled?),
      do: {:deny, "Wait for the current turn before changing tools."}

    defp decision(state, names, enabled?) do
      if enabled? and
           Enum.any?(
             Choices.tool_statuses(state),
             &(&1.name in names and not Map.get(&1, :allowed?, true))
           ),
         do: {:deny, "Unavailable under this host profile."},
         else: command_decision(state, names, enabled?)
    end

    defp command_decision(state, names, enabled?) do
      policy = Choices.command_policy(state)

      with :allow <- Conversation.command_decision(policy, :tools_status),
           do:
             Conversation.command_decision(
               policy,
               {if(enabled?, do: :enable_tools, else: :disable_tools), names}
             )
    end

    @doc false
    @spec mouse(event :: Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def mouse(%Mouse{kind: kind}, state) when kind in ["scroll_up", "scroll_down"],
      do: {:noreply, select(state, if(kind == "scroll_up", do: -3, else: 3))}

    def mouse(%Mouse{kind: "down", button: "left"} = event, state) do
      g = geometry(state, Screen.panes(state))

      state =
        cond do
          inside?(event, g.button) ->
            toggle(state)

          inside?(event, g.list) ->
            row = Enum.at(state.modal.rows, g.start + event.y - g.list.y)
            if row, do: put_in(state.modal.selected, row.name), else: state

          true ->
            state
        end

      {:noreply, state}
    end

    def mouse(_event, state), do: {:noreply, state}

    defp inside?(event, rect),
      do:
        event.x >= rect.x and event.x < rect.x + rect.width and event.y >= rect.y and
          event.y < rect.y + rect.height

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      g = geometry(state, panes)
      theme = Screen.theme(state)

      rows =
        state.modal.rows
        |> Enum.slice(g.start, g.list.height)
        |> Enum.map(&tool_line(&1, state.modal.selected, theme))

      rows = if rows == [], do: [text(empty(state), theme.text.muted)], else: rows
      row = selected(state)
      description = if row, do: Map.get(row, :description, "") |> String.slice(0, 512), else: ""
      notice = state.modal.notice || boundary(state, row)
      label = button_label(state, row)

      Takeover.frame(g.area, " Tools · #{length(state.modal.rows)} ") ++
        [
          {%Paragraph{text: "Filter: #{state.modal.query}", style: %Style{fg: theme.voices.you}},
           g.filter},
          {%Paragraph{text: rows, wrap: false}, g.list},
          {%Paragraph{
             text:
               RichText.literal(clean(description), max(g.detail.width, 1), %Style{
                 fg: theme.text.muted
               }),
             wrap: false
           }, g.detail},
          {%Paragraph{text: notice, style: %Style{fg: theme.voices.activity}}, g.notice},
          {%Paragraph{text: label, style: %Style{fg: theme.voices.you, modifiers: [:bold]}},
           g.button},
          {%Paragraph{
             text: "↑↓ Select · type to filter · Space toggle · Esc close",
             style: %Style{fg: theme.text.muted}
           }, g.help}
        ]
    end

    defp tool_line(row, selected, theme) do
      {label, colour} =
        cond do
          not Map.get(row, :allowed?, true) -> {"⊘ Unavailable", theme.children.warn}
          row.enabled? -> {"✓ Active", theme.children.ok}
          true -> {"○ Inactive", theme.text.muted}
        end

      %Line{
        style: %Style{bg: if(row.name == selected, do: theme.blocks.code_bg)},
        spans: [
          %Span{
            content: if(row.name == selected, do: "› ", else: "  "),
            style: %Style{fg: theme.voices.you}
          },
          %Span{
            content: clean(row.name),
            style: %Style{
              fg: theme.children.name,
              modifiers: if(row.name == selected, do: [:bold], else: [])
            }
          },
          %Span{content: " · #{label}", style: %Style{fg: colour}},
          %Span{content: " · #{clean(source(row))}", style: %Style{fg: theme.text.muted}}
        ]
      }
    end

    defp source(%{source: {:mcp, server}}), do: "MCP #{server}"
    defp source(_row), do: "Local"
    defp text(value, colour), do: %Line{spans: [%Span{content: value, style: %Style{fg: colour}}]}
    defp empty(%{modal: %{loading?: true}}), do: "Loading tools…"
    defp empty(%{modal: %{query: ""}}), do: "No tools available."
    defp empty(_state), do: "No matching tools."
    defp boundary(_state, nil), do: ""

    defp boundary(state, row) do
      case decision(state, [row.name], not row.enabled?) do
        :allow -> "Changes affect future requests; session permissions still apply."
        {:deny, reason} -> reason
      end
    end

    defp button_label(_state, nil), do: ""
    defp button_label(%{modal: %{loading?: true}}, _row), do: "Updating…"

    defp button_label(state, row) do
      case decision(state, [row.name], not row.enabled?) do
        :allow -> "[Enter #{if row.enabled?, do: "Deactivate", else: "Activate"}]"
        {:deny, _reason} -> "[Toggle unavailable]"
      end
    end

    defp geometry(state, panes) do
      area = Takeover.tray(panes, min(length(state.modal.rows), 10) + 9)

      inner = %Rect{
        x: area.x + min(area.width, 1),
        y: area.y + min(area.height, 1),
        width: max(area.width - 2, 0),
        height: max(area.height - 2, 0)
      }

      list_height = min(max(length(state.modal.rows), 1), max(inner.height - 6, 0))
      index = Enum.find_index(state.modal.rows, &(&1.name == state.modal.selected)) || 0
      start = max(min(index - div(list_height, 2), length(state.modal.rows) - list_height), 0)

      %{
        area: area,
        filter: rect(inner, 0, 1),
        list: rect(inner, 1, list_height),
        start: start,
        detail: rect(inner, 1 + list_height, 2),
        notice: rect(inner, inner.height - 3, 1),
        button: rect(inner, inner.height - 2, 1),
        help: rect(inner, inner.height - 1, 1)
      }
    end

    defp rect(%Rect{} = inner, offset, height) do
      offset = min(max(offset, 0), inner.height)
      %Rect{inner | y: inner.y + offset, height: min(height, inner.height - offset)}
    end

    defp clean(value), do: String.replace(value, ~r/[\x00-\x1f\x7f]/u, " ")
    defp describe(:busy), do: "Wait for the current turn before changing tools."
    defp describe(:session_disconnected), do: "This session is disconnected."
    defp describe(reason), do: "Could not change tools: #{Conversation.describe(reason)}"
  end
end
