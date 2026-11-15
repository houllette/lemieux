if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.PlanInspector do
    @moduledoc """
    A read-only, scrollable view of the complete cached Todo List.

    The pinned preview intentionally clips titles and follows current work.
    This view wraps every title, including subtasks, so neither a small terminal
    nor a long plan makes a task inaccessible. Opening it makes no session or
    provider call, and leaves the composer's draft and selection untouched.
    """
    alias ExRatatui.Event.Key
    alias ExRatatui.Layout.Rect
    alias ExRatatui.Style
    alias ExRatatui.Widgets.{Block, Clear, Paragraph}
    alias Lemieux.TUI
    alias Lemieux.TUI.{Keys, Modal, PlanPanel, RichText, Screen, Width}

    @doc false
    @spec key(event :: Key.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def key(%Key{code: code} = event, state) do
      action = Keys.action(state.status.keys, event)

      next =
        cond do
          action in [:todos, :interrupt, :dismiss] or code == "q" -> Modal.close(state)
          action == :toggle_todos or code == "m" -> state |> PlanPanel.toggle() |> Modal.close()
          true -> move(state, code)
        end

      {:noreply, next}
    end

    defp move(state, code) when code in ["up", "k"], do: scroll(state, -1)
    defp move(state, code) when code in ["down", "j"], do: scroll(state, 1)
    defp move(state, "page_up"), do: scroll(state, -page(state))
    defp move(state, code) when code in ["page_down", " "], do: scroll(state, page(state))
    defp move(state, "home"), do: put_in(state.modal.offset, 0)
    defp move(state, "end"), do: scroll(state, :end)
    defp move(state, _code), do: state

    @doc false
    @spec mouse(event :: ExRatatui.Event.Mouse.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def mouse(%{kind: "scroll_up"}, state), do: {:noreply, scroll(state, -3)}
    def mouse(%{kind: "scroll_down"}, state), do: {:noreply, scroll(state, 3)}
    def mouse(_event, state), do: {:noreply, state}

    @doc false
    @spec paste(event :: ExRatatui.Event.Paste.t(), state :: TUI.t()) :: {:noreply, TUI.t()}
    def paste(_event, state), do: {:noreply, state}

    @doc false
    @spec render(state :: TUI.t(), panes :: map()) :: [{term(), Rect.t()}]
    def render(state, panes) do
      area = area(panes)
      lines = lines(state, area)
      offset = min(state.modal.offset, max(length(lines) - max(area.height - 2, 1), 0))

      body = %Paragraph{
        text: Enum.slice(lines, offset, max(area.height - 2, 0)),
        wrap: false,
        block: %Block{
          title: " Todo List · revision #{Map.get(state.session_view, :plan_revision, 0)} ",
          titles: [
            %Block.Title{
              content: footer(state, area.width),
              position: :bottom
            }
          ],
          borders: [:all],
          border_type: :rounded,
          border_style: %Style{fg: Screen.accent(state)},
          padding: {1, 1, 0, 0}
        }
      }

      [{%Clear{}, area}, {body, area}]
    end

    defp footer(state, width) do
      action = if state.session_view.plan_collapsed?, do: "expand", else: "minimize"

      choices = [
        " ↑↓ PgUp/PgDn · Home/End · m #{action} · Esc close ",
        " ↑↓ PgUp/Dn · m #{action} · Esc close ",
        " ↑↓ · m #{action} · Esc close ",
        " Esc close "
      ]

      Enum.find(choices, List.last(choices), &(Width.of(&1) <= width - 2))
    end

    defp lines(state, area) do
      rows =
        Enum.map(state.session_view.plan || [], fn task ->
          {:todo_item, task["id"], task["status"],
           if(task["parent_id"], do: "↳ ", else: "") <> task["title"]}
        end)

      RichText.lines(rows, max(area.width - 4, 1), Screen.theme(state))
    end

    defp area(panes) do
      top = panes.transcript.y
      bottom = panes.input.y + panes.input.height
      %Rect{x: panes.input.x, y: top, width: panes.input.width, height: max(bottom - top, 0)}
    end

    defp page(state), do: max(area(Screen.panes(state)).height - 3, 1)

    defp scroll(state, by) do
      area = area(Screen.panes(state))
      last = max(length(lines(state, area)) - max(area.height - 2, 1), 0)
      offset = if by == :end, do: last, else: (state.modal.offset + by) |> max(0) |> min(last)
      put_in(state.modal.offset, offset)
    end
  end
end
