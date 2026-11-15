defmodule Lemieux.TUI.PlanPanelTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias ExRatatui.Event.Resize
  alias Lemieux.Entry
  alias Lemieux.TUI
  alias Lemieux.TUI.{Keys, PlanInspector, PlanPanel, Screen, Width}

  test "F5 focuses the complete wrapped list without changing the draft" do
    state = plan(tui(), tasks()) |> type("keep this draft")
    draft = ExRatatui.textarea_get_value(state.input)
    state = press(state, "f5")
    assert state.modal.kind == :plan
    assert visible(state) =~ "first item"
    refute visible(state) =~ "last item"
    state = press(state, "end")
    assert visible(state) =~ "last item"
    state = press(state, "home") |> press("down")
    assert state.modal.offset == 1
    state = press(state, "page_down")
    assert state.modal.offset > 1
    assert press(state, "page_up").modal.offset == 1
    state = press(state, "esc")
    assert state.modal == nil
    assert ExRatatui.textarea_get_value(state.input) == draft
  end

  test "the compact summary frees rows, stays inspectable and survives plan updates" do
    state = plan(tui(), tasks())
    expanded = Screen.panes(state).transcript.height
    state = press(state, "m", ["alt"])
    assert PlanPanel.rows(state, 24) == 1
    assert Screen.panes(state).transcript.height > expanded
    assert screen(state) =~ "Todo List"
    refute screen(state) =~ "first item"
    state = plan(state, tasks(), 2)
    assert PlanPanel.rows(state, 24) == 1
    state = state |> press("f5") |> press("m")
    assert state.modal == nil
    assert PlanPanel.rows(state, 24) > 1
    assert screen(state) =~ "first item"
  end

  test "long titles, subtasks and completed plans remain readable in the inspector" do
    tasks = [
      %{
        "id" => "a",
        "title" => String.duplicate("界🙂 title ", 20) <> "tail marker",
        "status" => "in_progress"
      },
      %{"id" => "b", "title" => "child item", "parent_id" => "a", "status" => "pending"}
    ]

    state = plan(tui(test_mode: {35, 12}), tasks) |> press("f5")
    assert {:noreply, state} = TUI.handle_event(%Resize{width: 35, height: 12}, state)
    state = press(state, "end")
    assert visible(state) =~ "tail marker"
    assert visible(state) =~ "child item"
    for line <- body(state).text, do: assert(Width.of(text(line)) <= 31)
    done = Enum.map(tasks, &Map.put(&1, "status", "completed"))
    state = plan(state, done, 2) |> press("home")
    assert visible(state) =~ "Completed"
    state = press(state, "f5")
    assert PlanPanel.rows(state, 12) == 0
    assert press(state, "f5").modal.kind == :plan
  end

  test "the title opens the inspector and configured bindings can open and close it" do
    state = plan(tui(), tasks())

    area = Screen.plan_area(state, Screen.panes(state))
    assert events(state, [{"down", area.x + 2, area.y}]).modal.kind == :plan

    {:ok, keys} = Keys.from_map(%{"ctrl-t" => "todos", "f5" => "forward"})
    state = put_in(state.status.keys, keys) |> press("t", ["ctrl"])
    assert state.modal.kind == :plan
    assert press(state, "t", ["ctrl"]).modal == nil
  end

  defp tasks do
    for i <- 1..60 do
      title =
        case i do
          1 -> "first item"
          60 -> "last item"
          _ -> "item #{i}"
        end

      %{"id" => "t#{i}", "title" => title, "status" => "pending"}
    end
  end

  defp plan(state, tasks, revision \\ 1) do
    info(
      state,
      {:entry,
       Entry.new(:extension_state, %{
         "namespace" => "lemieux.plan",
         "revision" => revision,
         "value" => %{"tasks" => tasks}
       })}
    )
  end

  defp body(state) do
    {body, _} = List.last(PlanInspector.render(state, Screen.panes(state)))
    body
  end

  defp text(line), do: Enum.map_join(line.spans, & &1.content)

  defp visible(state), do: Enum.map_join(body(state).text, "\n", &text/1)
end
