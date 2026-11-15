defmodule Lemieux.TUI.StatusPagesTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Resize
  alias ExRatatui.Frame
  alias ExRatatui.Layout.Rect
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.Conversation
  alias Lemieux.TUI
  alias Lemieux.TUI.{Responsive, Screen, Status, Width}

  test "pages pack complete stats with stationary permissions and cycle in order" do
    status =
      Status.new(
        permission: "auto",
        requests: 7,
        request_cap: 20,
        throughput: "avg 12 tok/s",
        conversation: Conversation.new()
      )

    assert Status.pages(status, 40) == [
             {[:requests, :throughput], "⏵ auto · req 7/20 · avg 12 tok/s"},
             {[:context, :session], "⏵ auto · context ? · session 0 tok"},
             {[:cost], "⏵ auto · cost: $0.00"}
           ]

    area = %Rect{x: 0, y: 0, width: 40, height: 1}
    [{page, _}] = Status.render(%{status | page_anchor: :session}, area)
    assert page.text == "⏵ auto · context ? · session 0 tok"
    [{page, _}] = Status.render(%{status | page_anchor: :cost}, area)
    assert page.text == "⏵ auto · cost: $0.00"

    assert [{_, wide}] = Status.pages(status, 200)
    assert wide == " " <> Enum.join(Status.segments(status), " · ")
  end

  test "oversized stats get explicit ellipses and Unicode never exceeds the viewport" do
    for width <- 1..30 do
      pages =
        Responsive.pages([summary: String.duplicate("中🙂", 20), cost: "cost: unknown"], width)

      assert Enum.flat_map(pages, &elem(&1, 0)) == [:summary, :cost]

      for {_keys, text} <- pages do
        assert Width.of(text) <= width
        assert String.valid?(text)
      end
    end

    assert [{[:summary], text}, _] =
             Responsive.pages([summary: "a statistic too wide", cost: "$0"], 8)

    assert String.ends_with?(text, "…")
  end

  test "repacking keeps the anchored stat on screen and costs retain their provenance" do
    status = Status.new(requests: 7, request_cap: 20, conversation: Conversation.new())
    narrow = Status.pages(status, 25)
    wider = Status.pages(status, 35)
    assert {keys, _text} = Enum.at(narrow, Status.page_index(narrow, :session))
    assert :session in keys
    assert {keys, _text} = Enum.at(wider, Status.page_index(wider, :session))
    assert :session in keys

    estimated = %{status.conversation | estimated_usd: {121, 3}, estimated_requests: 1}

    [{page, _}] =
      Status.render(%{status | conversation: estimated, page_anchor: :cost}, %Rect{
        width: 20,
        height: 1
      })

    assert page.text =~ "cost: ~$0.13"

    unknown = %{status.conversation | spent_usd: nil}

    [{page, _}] =
      Status.render(%{status | conversation: unknown, page_anchor: :cost}, %Rect{
        width: 20,
        height: 1
      })

    assert page.text =~ "cost: unknown"
  end

  test "idle pages rotate every five seconds without transcript or value updates resetting them" do
    clock = :atomics.new(1, [])

    state =
      TUI.new(
        model: "test:m",
        test_mode: {60, 24},
        clock: fn -> :atomics.get(clock, 1) end
      )

    state = put_in(state.session_view.request_cap, 500)
    state = put_in(state.session_view.requests, 123)
    state = put_in(state.session_view.throughput, {100, 1_000_000})
    assert {:noreply, state} = TUI.handle_event(%Resize{width: 60, height: 24}, state)
    assert %{timer: timer, token: token} = state.terminal.chrome_timer
    assert Process.read_timer(timer) <= 5_000
    first = status_row(state)

    :atomics.put(clock, 1, 4_999)

    assert {:noreply, state} =
             TUI.handle_info({:lemieux, state.id, {:text_delta, "new text"}}, state)

    assert state.terminal.chrome_timer.timer == timer
    assert status_row(state) == first

    Process.cancel_timer(timer)
    :atomics.put(clock, 1, 5_000)
    assert {:noreply, state} = TUI.handle_info({:chrome_tick, token}, state)
    second = status_row(state)
    assert second != first
    rotation = state.terminal.status_rotation
    assert rotation.next_at == 10_000

    assert {:noreply, state} =
             TUI.handle_event(
               %Resize{width: 61, height: 24},
               put_in(state.session_view.requests, 124)
             )

    assert state.terminal.status_rotation == rotation

    timer = state.terminal.chrome_timer
    Process.cancel_timer(timer.timer)
    :atomics.put(clock, 1, 10_000)
    assert {:noreply, state} = TUI.handle_info({:chrome_tick, timer.token}, state)
    assert status_row(state) == String.replace(first, "req 123/500", "req 124/500")

    timer = state.terminal.chrome_timer.timer
    assert {:noreply, state} = TUI.handle_event(%Resize{width: 200, height: 24}, state)
    assert state.terminal.chrome_timer == nil
    assert state.terminal.status_rotation.next_at == nil
    assert Process.read_timer(timer) == false
  end

  defp status_row(state) do
    pane = Screen.panes(state).status

    state
    |> TUI.render(%Frame{width: state.terminal.width, height: state.terminal.height})
    |> Enum.find_value(fn
      {%Paragraph{text: text}, ^pane} -> text
      _widget -> nil
    end)
  end
end
