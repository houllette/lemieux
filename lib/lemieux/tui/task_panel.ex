if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.TaskPanel do
    @moduledoc """
    Native session task list and live log inspector, opened by Shift+Up or its composer badge.

    Rendering reads only cached state. Metadata, logs and human controls run in
    host tasks, with session and request tokens fencing late replies. Monitoring
    is independent of whether this panel is open, and opening it never invokes a
    model. The draft stays in its original editor throughout.
    """
    alias ExRatatui.Event.{Key, Mouse}
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.{Line, Span}
    alias ExRatatui.Widgets.{Block, Paragraph}
    alias Lemieux.CLI.Tasks
    alias Lemieux.Conversation
    alias Lemieux.TUI

    alias Lemieux.TUI.{
      Choices,
      Flash,
      Keys,
      Modal,
      Screen,
      Takeover,
      TaskForm,
      TaskSteer,
      TaskText,
      Transcript,
      Width
    }

    @doc false
    @spec reset(state :: TUI.t(), info :: map() | :unknown) :: TUI.t()
    def reset(state, info \\ :unknown) do
      cache = %{
        loaded?: false,
        session: state.session,
        token: nil,
        timer: nil,
        rows: [],
        details: %{},
        selected: nil,
        detail: nil,
        sources: [],
        monitoring?: false,
        supported?: supported?(info),
        error: nil
      }

      state = put_in(state.session_view[:tasks], cache)
      refresh(state)
    end

    @doc false
    @spec cache(state :: TUI.t()) :: map()
    def cache(state),
      do:
        Map.get(state.session_view, :tasks) ||
          %{
            loaded?: false,
            session: state.session,
            token: nil,
            timer: nil,
            rows: [],
            details: %{},
            selected: nil,
            detail: nil,
            sources: [],
            monitoring?: false,
            supported?: true,
            error: nil
          }

    defp supported?(:unknown), do: true

    defp supported?(%{supervisor: supervisor})
         when is_atom(supervisor) and not is_nil(supervisor),
         do: true

    defp supported?(_info), do: false

    @doc false
    @spec refresh(state :: TUI.t()) :: TUI.t()
    def refresh(%{resume: %{down: down}} = state) when not is_nil(down), do: disconnected(state)
    def refresh(%{session: nil} = state), do: state

    def refresh(state) do
      data = cache(state)

      cond do
        data.session != state.session ->
          reset(state)

        not data.supported? ->
          put_in(state.session_view[:tasks], %{data | error: describe(:native_tasks_unavailable)})

        data.token != nil ->
          state

        true ->
          token = make_ref()
          state = put_in(state.session_view[:tasks], %{data | token: token})
          request(state, token, :snapshot, fn -> Tasks.snapshot(state.session, data.selected) end)
      end
    end

    @doc false
    @spec tick(state :: TUI.t(), session :: pid(), token :: reference()) :: TUI.t()
    def tick(state, session, token) do
      data = cache(state)
      if state.session == session and data.timer == token, do: refresh(state), else: state
    end

    @doc false
    @spec disconnected(state :: TUI.t()) :: TUI.t()
    def disconnected(state) do
      data = cache(state)

      rows = Enum.map(data.rows, &unavailable/1)
      detail = if data.detail, do: unavailable(data.detail)

      put_in(state.session_view[:tasks], %{
        data
        | token: nil,
          timer: nil,
          rows: rows,
          detail: detail,
          monitoring?: false,
          sources: [],
          error: "This session is disconnected."
      })
    end

    defp unavailable(row),
      do:
        Map.merge(row, %{
          running?: false,
          watching?: false,
          status: "unavailable",
          status_label: "Unavailable",
          active?: false,
          tracking_label: "Session disconnected"
        })

    @doc false
    @spec answer(
            state :: TUI.t(),
            session :: pid(),
            token :: reference(),
            kind :: atom(),
            result :: term()
          ) :: TUI.t()
    def answer(state, session, token, :snapshot, result) do
      data = cache(state)

      if state.session == session and data.token == token do
        timer = make_ref()
        Process.send_after(self(), {:tasks_tick, session, timer}, 1000)
        data = %{data | token: nil, timer: timer}

        data =
          case result do
            {:ok, view} ->
              snapshot_data(data, view)

            {:error, :native_tasks_unavailable} ->
              %{data | supported?: false, error: describe(:native_tasks_unavailable)}

            {:error, reason} ->
              %{data | error: describe(reason)}
          end

        state = reconcile(state, data)

        results =
          data.rows
          |> Enum.filter(&(Map.get(&1, :kind) == :command and is_binary(Map.get(&1, :name))))
          |> Enum.map(&%{"name" => &1.name, "status" => Map.get(&1, :status_label, &1.status)})

        Transcript.complete_tasks(state, results)
      else
        state
      end
    end

    def answer(
          %{session: session, modal: %{kind: :tasks, operation: token}} = state,
          session,
          token,
          :action,
          result
        ) do
      notice =
        case result do
          :ok -> Map.get(state.modal, :operation_notice, "Updated.")
          {:error, reason} -> describe(reason)
        end

      state = put_in(state.modal, %{state.modal | operation: nil, notice: notice})
      state = if result == :ok, do: put_in(state.modal.form, nil), else: state
      state = put_in(state.session_view[:tasks], %{cache(state) | token: nil})
      refresh(state)
    end

    def answer(state, _session, _token, _kind, _result), do: state

    defp snapshot_data(data, view) do
      details = Map.take(data.details, Enum.map(view.rows, & &1.id))
      details = if view.detail, do: Map.put(details, view.detail.id, view.detail), else: details
      Map.merge(data, Map.merge(view, %{error: nil, details: details, loaded?: true}))
    end

    @doc false
    @spec open(state :: TUI.t()) :: TUI.t()
    def open(state) do
      case decision(state, :open) do
        :allow ->
          state = %{
            state
            | modal: %{
                kind: :tasks,
                session: state.session,
                focus: :list,
                view: :active,
                content: :output,
                offset: 0,
                follow?: true,
                confirm: nil,
                form: nil,
                notice: nil,
                operation: nil,
                operation_notice: "Updated."
              }
          }

          refresh(state)

        {:deny, reason} ->
          Flash.show(state, reason)
      end
    end

    @doc false
    @spec title(state :: TUI.t(), width :: non_neg_integer()) :: [
            ExRatatui.Widgets.Block.Title.t()
          ]
    def title(state, width) when width >= 28 do
      running = Enum.count(cache(state).rows, &active?/1)
      count = if running > 0, do: " #{running}", else: ""

      shortcut =
        if Keys.action(state.status.keys, %{code: "up", modifiers: ["shift"]}) == :tasks,
          do: " · Shift+Up",
          else: ""

      label = " Tasks#{count}#{shortcut} "

      if decision(state, :open) == :allow,
        do: [%ExRatatui.Widgets.Block.Title{content: label, alignment: :right, position: :top}],
        else: []
    end

    def title(_state, _width), do: []

    @doc false
    @spec badge_at?(state :: TUI.t(), event :: Mouse.t()) :: boolean()
    def badge_at?(state, event) do
      area = Screen.panes(state).input

      case title(state, area.width) do
        [title] ->
          event.y == area.y and event.x >= area.x + area.width - Width.of(title.content) - 1

        [] ->
          false
      end
    end

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(event, state) do
      if Keys.action(state.status.keys, event) == :tasks,
        do: {:noreply, Modal.close(state)},
        else: panel_key(event, state)
    end

    defp panel_key(%Key{code: "c", modifiers: ["ctrl"]}, state),
      do: {:noreply, Modal.close(state)}

    defp panel_key(event, %{modal: %{form: %{kind: :steer}}} = state),
      do: TaskSteer.key(event, state)

    defp panel_key(event, %{modal: %{form: form}} = state) when not is_nil(form),
      do: TaskForm.key(event, state)

    defp panel_key(
           %Key{code: code, modifiers: []},
           %{modal: %{confirm: %{action: action, id: id}}} = state
         ) do
      state = put_in(state.modal.confirm, nil)
      if code == "y", do: {:noreply, act(state, action, id)}, else: {:noreply, state}
    end

    defp panel_key(%Key{code: code, modifiers: []}, state) when code in ["esc", "q"],
      do: {:noreply, Modal.close(state)}

    defp panel_key(%Key{code: "enter", modifiers: []}, state),
      do: {:noreply, choose(state, :output)}

    defp panel_key(%Key{code: "tab", modifiers: []}, state),
      do:
        {:noreply,
         put_in(state.modal.focus, if(state.modal.focus == :list, do: :logs, else: :list))}

    defp panel_key(%Key{code: code, modifiers: []}, state) when code in ["1", "2"] do
      {:noreply, choose(state, if(code == "1", do: :active, else: :history))}
    end

    defp panel_key(%Key{code: code, modifiers: []}, state) when code in ["up", "down"] do
      by = if code == "up", do: -1, else: 1
      state = if state.modal.focus == :list, do: select(state, by), else: scroll(state, by)
      {:noreply, state}
    end

    defp panel_key(%Key{code: code, modifiers: []}, state)
         when code in ["page_up", "page_down", "home", "end"] do
      by =
        case code do
          "page_up" -> -10
          "page_down" -> 10
          "home" -> -1_000_000
          "end" -> 1_000_000
        end

      state = scroll(state, by)
      state = if code == "end", do: put_in(state.modal.follow?, true), else: state
      {:noreply, state}
    end

    defp panel_key(%Key{code: code, modifiers: []}, state) do
      action =
        %{
          "c" => :cancel,
          "s" => :stop,
          "w" => :watch,
          "f" => :follow_up,
          "x" => :clear,
          "a" => :add,
          "o" => :link,
          "r" => :refresh,
          "v" => :inspect,
          "t" => :steer,
          "l" => :output
        }[code]

      {:noreply, choose(state, action)}
    end

    defp panel_key(_event, state), do: {:noreply, state}

    defp choose(state, :confirm) do
      %{action: action, id: id} = state.modal.confirm
      state |> put_in([Access.key!(:modal), :confirm], nil) |> act(action, id)
    end

    defp choose(state, :back), do: put_in(state.modal.confirm, nil)
    defp choose(state, :close), do: Modal.close(state)
    defp choose(state, :add), do: TaskForm.open(state)
    defp choose(state, :refresh), do: refresh(state)

    defp choose(state, :inspect) do
      content =
        if selected(state) && selected(state)[:kind] == :agent, do: :instructions, else: :command

      choose(state, if(state.modal.content == :output, do: content, else: :output))
    end

    defp choose(state, content) when content in [:command, :instructions, :output] do
      state
      |> put_in([Access.key!(:modal), :content], content)
      |> put_in([Access.key!(:modal), :focus], :logs)
      |> put_in([Access.key!(:modal), :offset], 0)
      |> put_in([Access.key!(:modal), :follow?], content == :output)
    end

    defp choose(state, view) when view in [:active, :history] do
      state = put_in(state.modal.view, view)
      row = List.first(visible_rows(state))
      select_row(state, row)
    end

    defp choose(state, nil), do: state

    defp choose(%{modal: %{operation: operation}} = state, _action) when not is_nil(operation),
      do: state

    defp choose(state, action), do: choose_row(state, action, selected(state))
    defp choose_row(state, _action, nil), do: state

    defp choose_row(state, :steer, %{kind: :agent, steerable?: true} = row),
      do: TaskSteer.open(state, row)

    defp choose_row(state, :steer, _row),
      do: put_in(state.modal.notice, "This task does not accept steering.")

    defp choose_row(state, action, %{kind: :agent})
         when action in [:stop, :watch, :follow_up, :clear],
         do:
           put_in(
             state.modal.notice,
             "Agent assignments expose instructions, output, steering and cancellation."
           )

    defp choose_row(state, action, %{managed?: true})
         when action in [:watch, :stop, :follow_up, :clear],
         do:
           put_in(
             state.modal.notice,
             "This agent manages completion. You can inspect or cancel its command."
           )

    defp choose_row(state, :cancel, %{running?: false}),
      do: put_in(state.modal.notice, "Only running local commands can be cancelled here.")

    defp choose_row(state, :follow_up, row) when not row.watching? or row.delivered?,
      do: put_in(state.modal.notice, "Auto-resume can be changed while tracking is active.")

    defp choose_row(state, :watch, %{source: "background", running?: false}),
      do: put_in(state.modal.notice, "This activity has finished. Its result is in History.")

    defp choose_row(state, action, row) when action in [:cancel, :clear],
      do:
        put_in(state.modal.confirm, %{
          action: action,
          id: row.id,
          prompt:
            if(action == :cancel,
              do: cancel_prompt(row),
              else: "Clear retained logs? Transcript evidence is kept."
            )
        })

    defp choose_row(state, action, row), do: act(state, action, row.id)

    defp cancel_prompt(%{agent_type: :writer}), do: "Cancel all writers in this batch?"

    defp cancel_prompt(row),
      do: "#{Map.get(row, :cancel_label, "Cancel command")} #{Map.get(row, :name, "")}?"

    defp act(state, action, id) do
      case decision(state, action) do
        :allow ->
          operation(state, action_work(state, action, id))

        {:deny, reason} ->
          put_in(state.modal.notice, reason)
      end
    end

    defp action_work(state, :link, _id), do: fn -> open_link(state, selected(state).url) end
    defp action_work(state, action, id), do: fn -> Tasks.action(state.session, id, action) end

    defp open_link(state, url) when is_binary(url) do
      case URI.parse(url) do
        %{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
          state.terminal.open_link.(url)

        _uri ->
          {:error, :no_run_link}
      end
    end

    defp open_link(_state, _url), do: {:error, :no_run_link}

    @doc false
    @spec add(state :: TUI.t(), source :: String.t(), values :: map(), follow_up? :: boolean()) ::
            TUI.t()
    def add(%{modal: %{operation: operation}} = state, _source, _values, _follow_up?)
        when not is_nil(operation), do: state

    def add(state, source, values, follow_up?) do
      case decision(state, :add) do
        :allow -> operation(state, fn -> Tasks.add(state.session, source, values, follow_up?) end)
        {:deny, reason} -> put_in(state.modal.notice, reason)
      end
    end

    @doc false
    @spec steer(state :: TUI.t(), id :: String.t(), instruction :: String.t()) :: TUI.t()
    def steer(%{modal: %{operation: operation}} = state, _id, _instruction)
        when not is_nil(operation), do: state

    def steer(state, id, instruction) do
      case decision(state, :steer) do
        :allow ->
          operation(
            state,
            fn -> Tasks.steer(state.session, id, instruction) end,
            "Steering queued for the next model request."
          )

        {:deny, reason} ->
          put_in(state.modal.notice, reason)
      end
    end

    defp operation(state, work, notice \\ "Updated.") do
      token = make_ref()

      state =
        state
        |> put_in([Access.key!(:modal), :operation], token)
        |> put_in([Access.key!(:modal), :operation_notice], notice)

      request(state, token, :action, work)
    end

    defp request(state, token, kind, work) do
      app = self()
      session = state.session
      task = fn -> send(app, {:tasks_result, session, token, kind, work.()}) end

      if state.resume.task_supervisor,
        do: Task.Supervisor.start_child(state.resume.task_supervisor, task),
        else: Task.start(task)

      state
    end

    defp select(state, by) do
      data = cache(state)
      rows = visible_rows(state)
      index = Enum.find_index(rows, &(&1.id == data.selected)) || 0
      row = Enum.at(rows, min(max(index + by, 0), max(length(rows) - 1, 0)))
      select_row(state, row)
    end

    # Selection is immediate; a refresh only replaces that task's output.
    # Clearing the entire inspector between asynchronous replies caused flashes
    # of unrelated help text during rapid navigation. Cached output never crosses
    # task identities, and request tokens still fence late replies.
    defp select_row(state, row) do
      data = cache(state)
      detail = if row, do: Map.merge(Map.get(data.details, row.id, %{logs: nil}), row)
      data = %{data | selected: row && row.id, detail: detail, token: nil}
      content = selected_content(state.modal.content, row)

      state
      |> put_in([Access.key!(:session_view), :tasks], data)
      |> put_in([Access.key!(:modal), :content], content)
      |> put_in([Access.key!(:modal), :offset], 0)
      |> put_in([Access.key!(:modal), :follow?], content == :output)
      |> put_in([Access.key!(:modal), :notice], nil)
      |> refresh()
    end

    defp selected_content(:output, _row), do: :output
    defp selected_content(_content, %{kind: :agent}), do: :instructions
    defp selected_content(_content, %{command: command}) when is_binary(command), do: :command
    defp selected_content(_content, _row), do: :output

    defp scroll(state, by) do
      g = geometry(state, Screen.panes(state))

      maximum =
        max(
          length(
            log_rows(cache(state).detail, g.logs.width, Screen.theme(state), state.modal.content)
          ) -
            max(g.logs.height - 1, 0),
          0
        )

      offset = if state.modal.follow?, do: maximum, else: state.modal.offset

      state
      |> put_in([Access.key!(:modal), :focus], :logs)
      |> put_in([Access.key!(:modal), :offset], min(max(offset + by, 0), maximum))
      |> put_in([Access.key!(:modal), :follow?], false)
    end

    defp selected(state), do: Enum.find(cache(state).rows, &(&1.id == cache(state).selected))

    defp active?(row), do: Map.get(row, :active?, row.running? or row.watching?)

    defp visible_rows(state),
      do: Enum.filter(cache(state).rows, &(active?(&1) == (state.modal.view == :active)))

    # Follow a selected activity into history when it finishes, keeping its
    # output on screen. A refresh must never replace it with a different job.
    defp reconcile(%{modal: %{kind: :tasks}} = state, data) do
      old = selected(state)
      new = Enum.find(data.rows, &(&1.id == data.selected))

      state =
        if old && new && active?(old) && not active?(new),
          do: put_in(state.modal.view, :history),
          else: state

      state = put_in(state.session_view[:tasks], data)

      if Enum.any?(visible_rows(state), &(&1.id == data.selected)),
        do: state,
        else: put_in(state.session_view[:tasks], %{data | selected: nil, detail: nil})
    end

    defp reconcile(state, data), do: put_in(state.session_view[:tasks], data)

    defp decision(state, action),
      do: Conversation.command_decision(Choices.command_policy(state), {:tasks, action})

    @doc false
    @spec paste(event :: term(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(event, %{modal: %{form: %{kind: :steer}}} = state),
      do: TaskSteer.paste(event, state)

    def paste(event, %{modal: %{form: form}} = state) when not is_nil(form),
      do: TaskForm.paste(event, state)

    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec mouse(event :: Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def mouse(event, %{modal: %{form: %{kind: :steer}}} = state),
      do: TaskSteer.mouse(event, state)

    def mouse(event, %{modal: %{form: form}} = state) when not is_nil(form),
      do: TaskForm.mouse(event, state)

    def mouse(%Mouse{kind: kind}, state) when kind in ["scroll_up", "scroll_down"],
      do: {:noreply, scroll(state, if(kind == "scroll_up", do: -3, else: 3))}

    def mouse(%Mouse{kind: "down", button: "left"} = event, state) do
      geometry = geometry(state, Screen.panes(state))
      hit = Enum.find(geometry.buttons, fn {_action, _label, rect} -> inside?(event, rect) end)

      cond do
        hit != nil ->
          {action, _label, _rect} = hit
          {:noreply, choose(state, action)}

        inside?(event, geometry.list) ->
          index = geometry.start + max(event.y - geometry.list.y - geometry.list_header, 0)
          current = Enum.find_index(visible_rows(state), &(&1.id == cache(state).selected)) || 0

          {:noreply,
           state |> put_in([Access.key!(:modal), :focus], :list) |> select(index - current)}

        inside?(event, geometry.logs) ->
          {:noreply, put_in(state.modal.focus, :logs)}

        not inside?(event, geometry.area) ->
          {:noreply, Modal.close(state)}

        true ->
          {:noreply, state}
      end
    end

    def mouse(_event, state), do: {:noreply, state}

    defp inside?(event, rect),
      do:
        event.x >= rect.x and event.x < rect.x + rect.width and
          event.y >= rect.y and event.y < rect.y + rect.height

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(%{modal: %{form: %{kind: :steer}}} = state, panes),
      do: TaskSteer.render(state, panes)

    def render(%{modal: %{form: form}} = state, panes) when not is_nil(form),
      do: TaskForm.render(state, panes)

    def render(state, panes) do
      g = geometry(state, panes)
      theme = Screen.theme(state)
      data = cache(state)

      rows =
        visible_rows(state)
        |> Enum.slice(g.start, g.list_count)
        |> Enum.map(&task_line(&1, data.selected, state.modal.focus, theme))

      rows = if rows == [], do: [line(empty_text(state, data))], else: rows

      log_rows = g.log_rows

      maximum = max(length(log_rows) - max(g.logs.height - 1, 0), 0)
      offset = if state.modal.follow?, do: maximum, else: min(state.modal.offset, maximum)
      notice = notice(state)

      Takeover.frame(
        g.area,
        " Tasks · #{if(state.modal.view == :active, do: "Active", else: "History")} #{length(visible_rows(state))} "
      ) ++
        draw(%Paragraph{text: rows, wrap: false, block: list_block(state, g, theme)}, g.list) ++
        draw(%Paragraph{text: g.detail_rows, wrap: false}, g.detail) ++
        draw(
          %Paragraph{
            text: g.preview_rows,
            wrap: false,
            block: %Block{
              title: " #{inspect_label(data.detail)} · v expand ",
              borders: [:top],
              border_style: %Style{fg: theme.text.muted}
            }
          },
          g.command
        ) ++
        draw(
          %Paragraph{
            text: log_rows,
            scroll: {offset, 0},
            wrap: false,
            block: %Block{
              title: output_title(state, data.detail),
              borders: [:top],
              border_style: focus_style(state.modal.focus == :logs, theme),
              title_style: focus_style(state.modal.focus == :logs, theme)
            }
          },
          g.logs
        ) ++
        draw(
          %Paragraph{text: notice, wrap: false, style: %Style{fg: theme.voices.activity}},
          g.notice
        ) ++
        Enum.flat_map(g.buttons, fn {_action, label, rect} ->
          draw(%Paragraph{text: label, style: %Style{fg: theme.voices.you}}, rect)
        end)
    end

    defp empty_text(_state, %{error: error}) when is_binary(error), do: error

    # A refresh is background bookkeeping. Once an empty view is known, keep
    # it on screen instead of flashing a loading label every polling interval.
    defp empty_text(_state, %{loaded?: false, token: token}) when not is_nil(token),
      do: "Loading tasks…"

    defp empty_text(%{modal: %{view: :history}}, _data), do: "No completed tasks yet."

    defp empty_text(_state, _data),
      do: "No active tasks. Agents, commands and runs appear here automatically."

    defp task_line(row, selected, focus, theme) do
      selected? = row.id == selected
      active? = selected? and focus == :list

      %Line{
        style: %Style{bg: if(active?, do: theme.blocks.code_bg)},
        spans: [
          %Span{content: if(selected?, do: "› ", else: "  "), style: focus_style(active?, theme)},
          %Span{
            content:
              "#{if(row[:parent_id], do: "↳ ", else: "")}#{Map.get(row, :type_label, "Command")} · ",
            style: %Style{fg: theme.text.muted}
          },
          %Span{
            content: clean(row[:name] || row.label),
            style: %Style{
              fg: theme.children.name,
              modifiers: if(selected?, do: [:bold], else: [])
            }
          },
          %Span{
            content: " · #{Map.get(row, :status_label, row.status)}",
            style: %Style{fg: TaskText.colour(row, theme)}
          },
          %Span{
            content: " · #{Map.get(row, :elapsed, "")} · #{Map.get(row, :description, "")}",
            style: %Style{fg: theme.text.muted}
          }
        ]
      }
    end

    defp list_block(_state, %{list_header: 0}, _theme), do: nil

    defp list_block(state, _geometry, theme) do
      active? = state.modal.focus == :list

      %Block{
        title: " Task list · #{if(active?, do: "focused", else: "Tab to focus")} ",
        borders: [:top],
        border_style: focus_style(active?, theme),
        title_style: focus_style(active?, theme)
      }
    end

    defp focus_style(true, theme), do: %Style{fg: theme.voices.you, modifiers: [:bold]}
    defp focus_style(false, theme), do: %Style{fg: theme.text.muted}

    defp output_title(state, detail) do
      title =
        if state.modal.content == :output,
          do: output_heading(detail, state.modal.follow?),
          else:
            "#{inspect_label(detail)} · #{if(state.modal.content == :command, do: "full shell source", else: "full brief")}"

      " #{title} · #{if(state.modal.focus == :logs, do: "focused", else: "Tab to focus")} "
    end

    defp output_heading(nil, _follow?), do: "Output"
    defp output_heading(%{active?: false}, _follow?), do: "Result"
    defp output_heading(_detail, true), do: "Output · following"
    defp output_heading(_detail, false), do: "Output · paused"

    defp line(text), do: %Line{spans: [%Span{content: text}]}
    defp clean(text), do: String.replace(text, ~r/[\x00-\x1f\x7f]/u, " ")
    defp log_text(nil, _content), do: "Select a task to inspect its output."

    defp log_text(detail, :command),
      do: Map.get(detail, :command) || "No local command is available for this activity."

    defp log_text(detail, :instructions),
      do: detail[:instructions] || "No agent brief is available."

    defp log_text(%{logs: nil}, _content), do: "Loading output…"
    defp log_text(%{logs: "", running?: true}, _content), do: "Waiting for output…"
    defp log_text(%{logs: ""}, _content), do: "No output."
    defp log_text(detail, _content), do: detail.logs || ""

    defp log_rows(detail, width, theme, content),
      do:
        TaskText.lines(
          log_text(detail, content),
          content,
          detail && detail[:kind],
          max(width, 1),
          theme
        )

    defp notice(%{modal: %{confirm: %{prompt: prompt}}}), do: "#{prompt}  Y confirm · Esc back"

    defp notice(%{modal: %{operation: operation}}) when not is_nil(operation),
      do: "Updating task…"

    defp notice(%{modal: %{notice: notice}}) when is_binary(notice), do: notice

    defp notice(state),
      do:
        if(state.modal.focus == :logs,
          do: "Output focused · ↑↓ scroll · Home/End · Tab task list",
          else: "Task list focused · ↑↓ select · v toggle details · Tab output"
        )

    defp geometry(state, panes) do
      data = cache(state)
      theme = Screen.theme(state)
      width = max(panes.input.width - 2, 1)

      details = TaskText.details(data.detail, width, theme)

      log_lines = log_rows(data.detail, width, theme, state.modal.content)

      preview = preview_rows(data.detail, state.modal.content, width, theme)

      buttons = buttons(state)
      footer = button_height(buttons, width)
      empty? = visible_rows(state) == [] and is_nil(data.detail)
      list_height = min(max(length(visible_rows(state)), 1), 6) + if(empty?, do: 0, else: 1)
      detail_height = if empty?, do: 0, else: min(length(details), 6)
      command_height = if preview == [], do: 0, else: length(preview) + 1

      log_height = log_height(empty?, log_lines, state.modal.content)

      notice_height = if empty?, do: 0, else: 1
      gap = if empty?, do: 0, else: 2

      area =
        Takeover.tray(
          panes,
          2 + list_height + gap + detail_height + command_height + log_height + notice_height +
            footer
        )

      inner = %Rect{
        x: area.x + min(1, area.width),
        y: area.y + min(1, area.height),
        width: max(area.width - 2, 0),
        height: max(area.height - 2, 0)
      }

      rows = visible_rows(state)
      footer = min(footer, inner.height)
      notice_y = max(inner.height - footer - notice_height, 0)

      body =
        body_layout(
          notice_y,
          length(rows),
          length(details),
          command_height,
          length(log_lines),
          empty?
        )

      count = body.count
      selected = Enum.find_index(rows, &(&1.id == data.selected)) || 0
      start = max(min(selected - div(count, 2), length(rows) - count), 0)
      list = rect(inner, 0, body.list)
      detail = rect(inner, body.list + body.gap, body.detail)
      logs_y = detail.y + detail.height - inner.y + body.after_detail
      command = rect(inner, logs_y, body.command)
      logs = rect(inner, logs_y + body.command, max(notice_y - logs_y - body.command, 0))
      notice = rect(inner, notice_y, notice_height)
      buttons = place_buttons(buttons, inner, max(inner.height - footer, 0))

      %{
        area: area,
        list: list,
        list_count: count,
        list_header: body.header,
        detail: detail,
        command: command,
        logs: logs,
        notice: notice,
        buttons: buttons,
        start: start,
        log_rows: log_lines,
        detail_rows: details,
        preview_rows: preview
      }
    end

    defp body_layout(height, _rows, _details, _preview, _logs, true),
      do: %{
        count: min(height, 1),
        list: min(height, 1),
        header: 0,
        gap: 0,
        detail: 0,
        after_detail: 0,
        command: 0
      }

    defp body_layout(height, rows, details, preview, logs, false) do
      minimum_logs = min(height, min(logs + 1, max(min(div(height, 2), 6), 2)))
      header = min(height, 1)
      count = min(min(rows, 6), max(height - minimum_logs - 3, 0))
      list = count + header
      spare = max(height - list, 0)
      gap = if spare >= min(details, 6) + minimum_logs + 1, do: 1, else: 0
      detail = min(min(details, 6), max(spare - minimum_logs - gap, 0))
      remaining = max(spare - gap - detail, 0)
      after_detail = if remaining > minimum_logs, do: 1, else: 0
      command = if remaining - after_detail - minimum_logs >= preview, do: preview, else: 0

      %{
        count: count,
        list: list,
        header: header,
        gap: gap,
        detail: detail,
        after_detail: after_detail,
        command: command
      }
    end

    defp preview_rows(detail, :output, width, theme) do
      if inspectable?(detail) do
        content = if detail[:kind] == :agent, do: :instructions, else: :command
        detail |> log_rows(width, theme, content) |> Enum.take(2)
      else
        []
      end
    end

    defp preview_rows(_detail, _content, _width, _theme), do: []
    defp log_height(true, _lines, _content), do: 0
    defp log_height(false, lines, :output), do: min(length(lines), 6) + 1
    defp log_height(false, lines, _content), do: min(length(lines), 14) + 1

    @doc false
    @spec area(state :: TUI.t(), panes :: map()) :: Rect.t()
    def area(%{modal: %{form: %{kind: :steer}}} = _state, panes), do: Takeover.tray(panes, 8)
    def area(%{modal: %{form: form}}, panes) when not is_nil(form), do: Takeover.tray(panes, 12)
    def area(state, panes), do: geometry(state, panes).area

    defp inspectable?(%{kind: :agent}), do: true
    defp inspectable?(%{command: command}), do: is_binary(command)
    defp inspectable?(_row), do: false
    defp inspect_label(%{kind: :agent}), do: "Instructions"
    defp inspect_label(_row), do: "Command"

    defp button_height(buttons, width) do
      {_x, rows} =
        Enum.reduce(buttons, {0, 1}, fn {_action, label}, {x, rows} ->
          length = min(Width.of(label), width)
          if x + length > width, do: {length + 1, rows + 1}, else: {x + length + 1, rows}
        end)

      rows
    end

    defp rect(inner, top, height),
      do: %Rect{
        x: inner.x,
        y: inner.y + min(top, inner.height),
        width: inner.width,
        height: min(height, max(inner.height - top, 0))
      }

    defp draw(_widget, %{width: width, height: height}) when width <= 0 or height <= 0, do: []
    defp draw(widget, rect), do: [{widget, rect}]

    defp buttons(%{modal: %{confirm: confirm}}) when not is_nil(confirm),
      do: [{:confirm, "[y Confirm]"}, {:back, "[Esc Back]"}]

    defp buttons(state) do
      active = Enum.count(cache(state).rows, &active?/1)
      history = length(cache(state).rows) - active

      ([{:active, "[1 Active #{active}]"}, {:history, "[2 History #{history}]"}] ++
         inspector_button(selected(state), state.modal.content) ++
         row_controls(selected(state), cache(state).monitoring?))
      |> maybe(cache(state).sources != [], {:add, "[a Add watch]"})
      |> Kernel.++([{:close, "[Esc Close]"}])
    end

    defp inspector_button(%{command: command}, :output) when is_binary(command),
      do: [{:inspect, "[v Expand command]"}]

    defp inspector_button(%{command: command}, _content) when is_binary(command),
      do: [{:inspect, "[v Show output]"}]

    defp inspector_button(%{kind: :agent}, :output), do: [{:inspect, "[v Instructions]"}]
    defp inspector_button(%{kind: :agent}, _content), do: [{:inspect, "[v Show output]"}]
    defp inspector_button(_row, _content), do: []

    defp row_controls(nil, _monitoring?), do: []

    defp row_controls(%{kind: :agent} = row, _monitoring?),
      do:
        []
        |> maybe(row[:steerable?], {:steer, "[t Steer agent]"})
        |> maybe(row.running?, {:cancel, "[c #{row.cancel_label}]"})

    defp row_controls(%{managed?: true} = row, _monitoring?),
      do: maybe([], row.running?, {:cancel, "[c Cancel command]"})

    defp row_controls(row, monitoring?) do
      []
      |> maybe(row.running?, {:cancel, "[c Cancel command]"})
      |> maybe(row.watching?, {:stop, "[s Pause tracking]"})
      |> maybe(
        resumable?(row, monitoring?),
        {:watch, "[w Resume tracking]"}
      )
      |> maybe(
        row.watching? and not row.delivered?,
        {:follow_up, "[f Auto-resume: #{if(row.follow_up?, do: "on", else: "off")}]"}
      )
      |> maybe(
        not row.running? and (row.delivered? or row.watch_id == nil),
        {:clear, "[x Clear logs]"}
      )
      |> maybe(is_binary(row.url) and row.url != "", {:link, "[o Open run]"})
    end

    defp resumable?(row, monitoring?),
      do:
        not row.watching? and monitoring? and
          (row.running? or (row.source != "background" and row.observation == "stopped"))

    defp maybe(list, true, item), do: list ++ [item]
    defp maybe(list, _false, _item), do: list

    defp place_buttons(buttons, inner, top) do
      {placed, _x, _y} =
        Enum.reduce(buttons, {[], 0, top}, fn {action, label}, {placed, x, y} ->
          width = min(Width.of(label), inner.width)
          {x, y} = if x + width > inner.width, do: {0, y + 1}, else: {x, y}

          rect = %Rect{
            x: inner.x + x,
            y: inner.y + min(y, inner.height),
            width: width,
            height: if(y < inner.height, do: 1, else: 0)
          }

          {[{action, label, rect} | placed], x + width + 1, y}
        end)

      Enum.reverse(placed)
    end

    defp describe(:invalid_github_target),
      do: "GitHub needs owner/repo, a numeric run ID and the full 40-character commit SHA."

    defp describe(:already_delivered),
      do: "This result was already delivered; it will not trigger another model turn."

    defp describe(:invalid_deadline), do: "Choose a deadline from 1 to 43200 minutes."

    defp describe(:external_job_cannot_be_cancelled),
      do: "External jobs expose observation controls only."

    defp describe(:session_disconnected), do: "This session is disconnected."
    defp describe(:native_tasks_unavailable), do: "This host does not expose native tasks."
    defp describe(reason), do: "Could not update task: #{inspect(reason)}"
  end
end
