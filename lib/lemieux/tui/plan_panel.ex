if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.PlanPanel do
    @moduledoc """
    The session's plan, above the input box, while there is one in progress.

    The `todo` tool (`Lemieux.Extensions.Planning`) keeps its plan in the
    transcript as a `lemieux.plan` extension state; every change is an
    `{:entry, %{type: :extension_state}}` event carrying the whole plan. The
    screen keeps the newest one (`session_view.plan`) and draws it here: a
    long task is easier to follow as a list with the current item marked than
    as tool calls scrolling past.

    Drawn only while some task is not completed — a finished plan has said
    what it had to — and never taller than a third of the screen; a longer
    plan shows the tasks around the one in progress.
    """

    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Text.Line
    alias ExRatatui.Text.Span
    alias ExRatatui.Widgets.Block
    alias ExRatatui.Widgets.Paragraph
    alias Lemieux.Extensions.Planning
    alias Lemieux.TUI
    alias Lemieux.TUI.Art
    alias Lemieux.TUI.Screen

    @doc """
    Keeps the plan from an event or an entry, if it is one. Anything else
    leaves the state alone.
    """
    @spec observe(TUI.t(), term()) :: TUI.t()
    def observe(state, %{
          type: :extension_state,
          payload: %{"namespace" => namespace, "value" => value}
        }) do
      if namespace == Planning.namespace(),
        do: put_plan(state, Planning.tasks(value)),
        else: state
    end

    def observe(state, _entry), do: state

    defp put_plan(state, tasks) do
      done = Enum.count(tasks, &(&1["status"] == "completed"))
      progress = if tasks != [], do: Art.progress(100 * done / length(tasks), "plan")

      state
      |> put_in([Access.key!(:session_view), :plan], tasks)
      |> put_in([Access.key!(:session_view), :plan_progress], progress)
    end

    @doc "The newest plan in `entries`, as `observe/2` would have kept it."
    @spec restore(TUI.t(), [map()]) :: TUI.t()
    def restore(state, entries) do
      entries
      |> Enum.filter(&match?(%{type: :extension_state}, &1))
      |> Enum.reduce(put_in(state.session_view.plan, nil), &observe(&2, &1))
    end

    @doc "How many rows the panel wants: `0` when there is nothing to draw."
    @spec rows(TUI.t(), non_neg_integer()) :: non_neg_integer()
    def rows(state, available) do
      case visible(state) do
        [] -> 0
        tasks -> min(length(tasks) + 3, max(div(available, 3), 3))
      end
    end

    @doc false
    @spec render(TUI.t(), Rect.t()) :: [{term(), Rect.t()}]
    def render(state, %Rect{height: height} = area) when height >= 3 do
      tasks = visible(state)
      progress? = height >= 5 and area.width >= 28
      room = height - 2 - if(progress?, do: 1, else: 0)
      theme = Screen.theme(state)
      current = Enum.find_index(tasks, &(&1["status"] == "in_progress")) || 0
      start = max(min(current - div(room, 2), length(tasks) - room), 0)
      done = Enum.count(tasks, &(&1["status"] == "completed"))

      lines =
        tasks
        |> Enum.slice(start, room)
        |> Enum.map(&line(&1, theme, area.width - 4))

      lines =
        if progress? and not is_nil(state.session_view.plan_progress) do
          {:model_art, animation, description} = state.session_view.plan_progress

          bar =
            Art.lines(animation, description, max(area.width - 4, 1), theme)
            |> Enum.at(1)

          [bar | lines]
        else
          lines
        end

      panel = %Paragraph{
        text: lines,
        wrap: false,
        block: %Block{
          title: " plan #{done}/#{length(tasks)} ",
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: theme.text.muted},
          padding: {1, 1, 0, 0}
        }
      }

      [{panel, area}]
    end

    def render(_state, _area), do: []

    defp visible(%TUI{session_view: %{plan: tasks}}) when is_list(tasks) do
      if Enum.any?(tasks, &(&1["status"] != "completed")), do: tasks, else: []
    end

    defp visible(_state), do: []

    defp line(task, theme, width) do
      {mark, style} =
        case task["status"] do
          "completed" -> {"☑ ", %Style{fg: theme.text.muted}}
          "in_progress" -> {"◐ ", %Style{fg: theme.voices.activity, modifiers: [:bold]}}
          _pending -> {"☐ ", %Style{fg: theme.text.plain}}
        end

      title = to_string(task["title"])

      title =
        if String.length(title) > width - 2,
          do: String.slice(title, 0, max(width - 3, 1)) <> "…",
          else: title

      Line.new([Span.new(mark <> title, style: style)])
    end
  end
end
