defmodule Lemieux.TUI.FeedbackRegressionsTest do
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Conversation
  alias Lemieux.TUI.Cost
  alias Lemieux.TUI.Screen
  alias Lemieux.TUI.TranscriptSpacing
  alias Lemieux.TUI.Turn

  test "overflow scrolls slowly while the permission mode stays stationary" do
    alias ExRatatui.Layout.Rect
    alias Lemieux.TUI.{Responsive, Status, Width}
    assert Responsive.scroll("short", 20, 99) == "short"

    assert Responsive.scroll("a much longer line", 8, 0) !=
             Responsive.scroll("a much longer line", 8, 2)

    for frame <- 0..40 do
      assert Width.of(Responsive.scroll("中🙂long source", 7, frame)) <= 7
    end

    status =
      Status.new(
        permission: "auto",
        requests: 123,
        request_cap: 500,
        conversation: Conversation.new()
      )

    area = %Rect{x: 0, y: 0, width: 30, height: 1}
    [{first, _}] = Status.render(status, area)
    [{next, _}] = Status.render(%{status | scroll_frame: 8}, area)
    assert first.text != next.text
    assert String.starts_with?(first.text, "⏵ auto · ")
    assert String.starts_with?(next.text, "⏵ auto · ")
  end

  test "the running task badge animates on the idle screen clock and clears on completion" do
    alias Lemieux.TUI.{Composer, TaskPanel}
    state = tui() |> sized()
    cache = %{TaskPanel.cache(state) | rows: [%{running?: true, watching?: true}]}
    state = put_in(state.session_view[:tasks], cache)
    [before] = TaskPanel.title(state, 80)
    assert before.content =~ "Tasks 1"
    assert before.style.fg == :light_yellow
    token = make_ref()
    state = put_in(state.terminal.cursor_blink.tick, token)
    assert {:noreply, state} = Composer.blink(state, token)
    [after_tick] = TaskPanel.title(state, 80)
    assert before.content != after_tick.content
    state = put_in(state.session_view.tasks.rows, [%{running?: false, watching?: false}])
    [finished] = TaskPanel.title(state, 80)
    assert finished.content == " Tasks · Shift+Up "
    assert finished.style.fg == nil
    [narrow] = TaskPanel.title(put_in(state.session_view.tasks.rows, cache.rows), 24)
    assert narrow.content =~ "Tasks 1"
    refute narrow.content =~ "Shift+Up"
  end

  test "a natural blank model row supplies the operation separator" do
    rows = [{:model, "answer"}, {:model, ""}, {:tool_heading, "c1", :run, "Run", "pwd"}]
    assert TranscriptSpacing.separate(rows, nil) == rows
  end

  test "the first wrapped draft row remains visible as the composer expands" do
    state = tui() |> sized() |> type(String.duplicate("word ", 15))
    pane = Screen.panes(state).input
    assert painted_row(state, pane.y + 1) =~ "word"
    state = type(state, "nextword")
    pane = Screen.panes(state).input
    assert pane.height == 4
    assert painted_row(state, pane.y + 1) =~ "word"
    assert painted_row(state, pane.y + 2) =~ "nextword"
  end

  test "a boundary space grows the composer without dropping the first row" do
    state = tui() |> sized() |> type(String.duplicate("x", 77))
    pane = Screen.panes(state).input
    assert painted_row(state, pane.y + 1) =~ String.duplicate("x", 77)
    state = type(state, "x ")
    pane = Screen.panes(state).input
    assert pane.height == 4
    assert painted_row(state, pane.y + 1) =~ String.duplicate("x", 78)
    assert typed(state) == String.duplicate("x", 78) <> " "
  end

  test "habs replay omits the startup milestones" do
    state = tui() |> put_in([Access.key!(:resume), :startup_status], :ready) |> command("/habs")
    refute screen(state) =~ "Preparing session"
    refute screen(state) =~ "lmx startup"
    assert state.overlay.text == "GO HABS GO"
  end

  test "costs ceil the total to cents and keep unknown and estimate provenance" do
    for {amount, display} <- [
          {0.231, "$0.24"},
          {0.24, "$0.24"},
          {0.07, "$0.07"},
          {0.2400000000001, "$0.25"},
          {1.0e-15, "$0.01"},
          {0.0001, "$0.01"},
          {0, "$0.00"}
        ] do
      assert Cost.format(%Conversation{spent_usd: amount}) == "cost: " <> display
    end

    assert Cost.format(%Conversation{spent_usd: nil}) == "cost: unknown"

    assert Cost.format(%Conversation{
             estimated_usd: {121, 3},
             estimated_requests: 1,
             unmeasured_requests: 1,
             measured_spent_usd: 0
           }) == "cost: ~$0.13"

    assert Cost.format(%Conversation{
             estimated_usd: {121, 3},
             estimated_requests: 1,
             unmeasured_requests: 1,
             measured_spent_usd: 0.011
           }) == "cost: ~$0.14"
  end

  test "request rows disappear and turn throughput uses only measured request durations" do
    state = tui() |> Turn.start_processing()

    state =
      info(
        state,
        {:entry,
         %{type: :assistant, usage: %{"output_tokens" => 100, "request_duration_us" => 1_000_000}}}
      )

    state =
      info(
        state,
        {:entry,
         %{type: :assistant, usage: %{"output_tokens" => 100, "request_duration_us" => 3_000_000}}}
      )

    refute Enum.any?(state.lines, &match?({:summary, _}, &1))
    finished = Turn.finish_processing(state)
    assert {:summary, summary} = hd(finished.lines)
    assert summary =~ "avg 50.0 tok/s"
    next = finished |> Turn.start_processing() |> Turn.finish_processing()
    assert {:summary, summary} = hd(next.lines)
    refute summary =~ "tok/s"
  end
end
