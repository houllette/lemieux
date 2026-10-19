if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.TaskPanel do
    @moduledoc """
    Native session task list and live log inspector, opened by F6 or its composer badge.

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
    alias Lemieux.TUI.{Choices, Flash, Modal, RichText, Screen, Takeover, TaskForm, Width}

    @doc false
    @spec reset(state :: TUI.t(), info :: map() | :unknown) :: TUI.t()
    def reset(state, info \\ :unknown) do
      cache = %{
        session: state.session,
        token: nil,
        timer: nil,
        rows: [],
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
            session: state.session,
            token: nil,
            timer: nil,
            rows: [],
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

    defp unavailable(row), do: %{row | running?: false, watching?: false, status: "unavailable"}

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
              Map.merge(data, Map.put(view, :error, nil))

            {:error, :native_tasks_unavailable} ->
              %{data | supported?: false, error: describe(:native_tasks_unavailable)}

            {:error, reason} ->
              %{data | error: describe(reason)}
          end

        put_in(state.session_view[:tasks], data)
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
          :ok -> "Updated."
          {:error, reason} -> describe(reason)
        end

      state = put_in(state.modal, %{state.modal | operation: nil, notice: notice})
      state = if result == :ok, do: put_in(state.modal.form, nil), else: state
      state = put_in(state.session_view[:tasks], %{cache(state) | token: nil})
      refresh(state)
    end

    def answer(state, _session, _token, _kind, _result), do: state

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
                offset: 0,
                follow?: true,
                confirm: nil,
                form: nil,
                notice: nil,
                operation: nil
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
      running = Enum.count(cache(state).rows, &(&1.running? or &1.watching?))
      label = if running > 0, do: " Tasks #{running} running · F6 ", else: " Tasks · F6 "

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
    def key(%Key{code: "c", modifiers: ["ctrl"]}, state), do: {:noreply, Modal.close(state)}
    def key(%Key{code: "f6"}, state), do: {:noreply, Modal.close(state)}

    def key(event, %{modal: %{form: form}} = state) when not is_nil(form),
      do: TaskForm.key(event, state)

    def key(
          %Key{code: code, modifiers: []},
          %{modal: %{confirm: %{action: action, id: id}}} = state
        ) do
      state = put_in(state.modal.confirm, nil)
      if code == "y", do: {:noreply, act(state, action, id)}, else: {:noreply, state}
    end

    def key(%Key{code: code, modifiers: []}, state) when code in ["esc", "q"],
      do: {:noreply, Modal.close(state)}

    def key(%Key{code: "enter", modifiers: []}, state),
      do: {:noreply, put_in(state.modal.focus, :logs)}

    def key(%Key{code: "tab", modifiers: []}, state),
      do:
        {:noreply,
         put_in(state.modal.focus, if(state.modal.focus == :list, do: :logs, else: :list))}

    def key(%Key{code: code, modifiers: []}, state) when code in ["up", "down"] do
      by = if code == "up", do: -1, else: 1
      state = if state.modal.focus == :list, do: select(state, by), else: scroll(state, by)
      {:noreply, state}
    end

    def key(%Key{code: code, modifiers: []}, state)
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

    def key(%Key{code: code, modifiers: []}, state) do
      action =
        %{
          "c" => :cancel,
          "s" => :stop,
          "w" => :watch,
          "f" => :follow_up,
          "x" => :clear,
          "a" => :add,
          "o" => :link,
          "r" => :refresh
        }[code]

      {:noreply, choose(state, action)}
    end

    def key(_event, state), do: {:noreply, state}

    defp choose(state, :confirm) do
      %{action: action, id: id} = state.modal.confirm
      state |> put_in([Access.key!(:modal), :confirm], nil) |> act(action, id)
    end

    defp choose(state, :back), do: put_in(state.modal.confirm, nil)
    defp choose(state, :close), do: Modal.close(state)
    defp choose(state, :add), do: TaskForm.open(state)
    defp choose(state, :refresh), do: refresh(state)
    defp choose(state, nil), do: state

    defp choose(%{modal: %{operation: operation}} = state, _action) when not is_nil(operation),
      do: state

    defp choose(state, action), do: choose_row(state, action, selected(state))
    defp choose_row(state, _action, nil), do: state

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
      do: put_in(state.modal.notice, "Continue can be changed while observation is active.")

    defp choose_row(state, action, row) when action in [:cancel, :clear],
      do: put_in(state.modal.confirm, %{action: action, id: row.id})

    defp choose_row(state, action, row), do: act(state, action, row.id)

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

    defp operation(state, work) do
      token = make_ref()
      state = put_in(state.modal.operation, token)
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
      index = Enum.find_index(data.rows, &(&1.id == data.selected)) || 0
      row = Enum.at(data.rows, min(max(index + by, 0), max(length(data.rows) - 1, 0)))
      data = %{data | selected: row && row.id, detail: nil, token: nil}

      state
      |> put_in([Access.key!(:session_view), :tasks], data)
      |> put_in([Access.key!(:modal), :offset], 0)
      |> put_in([Access.key!(:modal), :follow?], true)
      |> refresh()
    end

    defp scroll(state, by) do
      g = geometry(state, Screen.panes(state))

      maximum =
        max(
          length(log_rows(cache(state).detail, g.logs.width, Screen.theme(state))) -
            max(g.logs.height - 1, 0),
          0
        )

      offset = if state.modal.follow?, do: maximum, else: state.modal.offset

      state
      |> put_in([Access.key!(:modal), :offset], min(max(offset + by, 0), maximum))
      |> put_in([Access.key!(:modal), :follow?], false)
    end

    defp selected(state), do: Enum.find(cache(state).rows, &(&1.id == cache(state).selected))

    defp decision(state, action),
      do: Conversation.command_decision(Choices.command_policy(state), {:tasks, action})

    @doc false
    @spec paste(event :: term(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(event, %{modal: %{form: form}} = state) when not is_nil(form),
      do: TaskForm.paste(event, state)

    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec mouse(event :: Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
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
          index = geometry.start + event.y - geometry.list.y
          current = Enum.find_index(cache(state).rows, &(&1.id == cache(state).selected)) || 0
          {:noreply, select(state, index - current)}

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
    def render(%{modal: %{form: form}} = state, panes) when not is_nil(form),
      do: TaskForm.render(state, panes)

    def render(state, panes) do
      g = geometry(state, panes)
      theme = Screen.theme(state)
      data = cache(state)

      rows =
        data.rows
        |> Enum.slice(g.start, g.list.height)
        |> Enum.map(&task_line(&1, data.selected, theme))

      rows =
        if rows == [],
          do: [
            line(
              if(data.token,
                do: "Loading tasks…",
                else:
                  data.error || "No background tasks. Started commands appear here automatically."
              )
            )
          ],
          else: rows

      log_rows = log_rows(data.detail, g.logs.width, theme)

      maximum = max(length(log_rows) - max(g.logs.height - 1, 0), 0)
      offset = if state.modal.follow?, do: maximum, else: min(state.modal.offset, maximum)
      notice = notice(state)

      Takeover.frame(g.area, " Background tasks · #{length(data.rows)} ") ++
        draw(%Paragraph{text: rows, wrap: false}, g.list) ++
        draw(%Paragraph{text: detail_text(data.detail), wrap: true}, g.detail) ++
        draw(
          %Paragraph{
            text: log_rows,
            scroll: {offset, 0},
            wrap: false,
            block: %Block{
              title: " Output · #{if(state.modal.follow?, do: "following", else: "paused")} ",
              borders: [:top],
              border_style: %Style{fg: theme.text.muted}
            }
          },
          g.logs
        ) ++
        draw(%Paragraph{text: notice, wrap: false}, g.notice) ++
        Enum.flat_map(g.buttons, fn {_action, label, rect} ->
          draw(%Paragraph{text: label, style: %Style{fg: theme.voices.you}}, rect)
        end)
    end

    defp task_line(row, selected, theme) do
      selected? = row.id == selected

      %Line{
        spans: [
          %Span{
            content: if(selected?, do: "› ", else: "  "),
            style: %Style{fg: theme.voices.you}
          },
          %Span{
            content: clean("#{row.status} · #{row.label}"),
            style: %Style{
              fg: task_colour(row, theme),
              modifiers: if(selected?, do: [:bold], else: [])
            }
          }
        ]
      }
    end

    defp task_colour(%{running?: true}, theme), do: theme.tools.run
    defp task_colour(%{watching?: true}, theme), do: theme.tools.run
    defp task_colour(%{status: "success"}, theme), do: theme.children.ok

    defp task_colour(row, theme),
      do:
        if(String.contains?(row.status, "fail"), do: theme.children.fail, else: theme.text.muted)

    defp line(text), do: %Line{spans: [%Span{content: text}]}
    defp clean(text), do: String.replace(text, ~r/[\x00-\x1f\x7f]/u, " ")
    defp log_text(nil), do: "Select a task to inspect its output."
    defp log_text(detail), do: detail.logs || ""

    defp log_rows(detail, width, theme),
      do:
        RichText.lines(
          Enum.map(String.split(log_text(detail), "\n"), &{:lmx, &1}),
          max(width, 1),
          theme
        )

    defp detail_text(nil), do: "F6 opens this view at any time. No model request is needed."

    defp detail_text(row) do
      mode = completion_mode(row)
      monitoring = observation(row)

      [
        clean(row.label),
        "#{row.source} · #{monitoring} · #{mode}",
        if(row.target["sha"], do: "Commit: #{row.target["sha"]}"),
        if(row.deadline, do: "Deadline #{row.deadline}"),
        row.summary
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")
    end

    defp completion_mode(%{managed?: true}), do: "completion required by assignment"
    defp completion_mode(%{follow_up?: true}), do: "continue automatically"
    defp completion_mode(_row), do: "notify only"

    defp observation(%{watching?: true}), do: "watching"
    defp observation(%{observation: nil}), do: "not watched"
    defp observation(%{observation: "completed"}), do: "observation complete"
    defp observation(row), do: "observation #{row.observation}"

    defp notice(%{modal: %{confirm: %{action: action}}}),
      do:
        "#{if(action == :cancel, do: "Cancel this command?", else: "Clear retained logs? Transcript evidence is kept.")}  Y confirm · Esc back"

    defp notice(%{modal: %{operation: operation}}) when not is_nil(operation),
      do: "Updating task…"

    defp notice(%{modal: %{notice: notice}}) when is_binary(notice), do: notice

    defp notice(state),
      do:
        if(state.modal.focus == :logs,
          do: "↑↓ logs · End follow · Tab task list",
          else: "↑↓ select · Enter logs · PgUp/PgDn scroll"
        )

    defp geometry(state, panes) do
      area = Takeover.area(panes, state.terminal.height)

      inner = %Rect{
        x: area.x + min(1, area.width),
        y: area.y + min(1, area.height),
        width: max(area.width - 2, 0),
        height: max(area.height - 2, 0)
      }

      data = cache(state)
      count = min(max(length(data.rows), 1), min(6, max(div(inner.height, 3), 1)))
      selected = Enum.find_index(data.rows, &(&1.id == data.selected)) || 0
      start = max(min(selected - div(count, 2), length(data.rows) - count), 0)
      list = rect(inner, 0, count)
      detail = rect(inner, count + 1, min(6, max(inner.height - count - 5, 0)))
      logs_y = detail.y + detail.height + 1 - inner.y
      logs = rect(inner, logs_y, max(inner.height - logs_y - 4, 0))
      notice = rect(inner, max(inner.height - 4, 0), 1)
      buttons = buttons(state) |> place_buttons(inner, max(inner.height - 3, 0))

      %{
        area: area,
        list: list,
        detail: detail,
        logs: logs,
        notice: notice,
        buttons: buttons,
        start: start
      }
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
      row_controls(selected(state), cache(state).monitoring?)
      |> maybe(cache(state).sources != [], {:add, "[a Add watch]"})
      |> Kernel.++([{:close, "[Esc Close]"}])
    end

    defp row_controls(nil, _monitoring?), do: []

    defp row_controls(%{managed?: true} = row, _monitoring?),
      do: maybe([], row.running?, {:cancel, "[c Cancel command]"})

    defp row_controls(row, monitoring?) do
      []
      |> maybe(row.running?, {:cancel, "[c Cancel command]"})
      |> maybe(row.watching?, {:stop, "[s Stop watching]"})
      |> maybe(not row.watching? and monitoring?, {:watch, "[w Watch]"})
      |> maybe(
        row.watching? and not row.delivered?,
        {:follow_up, "[f Continue: #{if(row.follow_up?, do: "on", else: "off")}]"}
      )
      |> maybe(
        not row.running? and (row.delivered? or row.watch_id == nil),
        {:clear, "[x Clear logs]"}
      )
      |> maybe(is_binary(row.url) and row.url != "", {:link, "[o Open run]"})
    end

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
