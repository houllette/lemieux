defmodule Lemieux.TUI.HoverTest do
  use ExUnit.Case, async: true
  import Lemieux.TUI.TestSupport
  alias ExRatatui.Event.Mouse
  alias Lemieux.TUI
  alias Lemieux.TUI.Hover
  alias Lemieux.TUI.Pointer
  alias Lemieux.TUI.QuestionPanel
  alias Lemieux.TUI.Screen

  defp enabled do
    state = sized(tui(lines: [{:model, "Visit [Google](https://google.com)"}]))
    put_in(state.terminal.hover.enabled?, true)
  end

  defp move(state, x, y, modifiers \\ []) do
    TUI.handle_event(%Mouse{kind: "moved", x: x, y: y, modifiers: modifiers}, state)
  end

  test "enter, bursts, modifiers and leave only change pointer intents" do
    state = enabled()

    assert {:noreply, over, render?: false, intents: [{:mouse_pointer, :pointer}]} =
             move(state, 10, 1)

    assert over.lines == state.lines
    assert over.scroll == state.scroll
    assert over.selection == nil
    assert typed(over) == typed(state)
    assert {:noreply, same, render?: false} = move(over, 11, 1, ["ctrl"])

    assert {:noreply, left, render?: false, intents: [{:mouse_pointer, :restore}]} =
             move(same, 1, 1)

    assert {:noreply, _same, render?: false} = move(left, 1, 1)
  end

  test "text regions, covers and stopping restore the prior host pointer" do
    {:noreply, over, _opts} = move(enabled(), 10, 1)
    input = Screen.panes(over).input

    assert {:noreply, _text, render?: false, intents: [{:mouse_pointer, :restore}]} =
             move(over, input.x + 1, input.y + 1)

    assert {:noreply, _covered, intents: [{:mouse_pointer, :restore}]} =
             Hover.transition({:noreply, %{over | overlay: %{}}})

    assert {:stop, _stopped, intents: [{:mouse_pointer, :restore}]} =
             Hover.transition({:stop, over})

    {:noreply, modal} =
      TUI.handle_info(
        {:lemieux, over.id,
         {:question, %{call_id: "ask", ask_user: true, question: "Why?", options: []}}},
        over
      )

    # This compact question leaves the link visible above it.
    assert modal.terminal.hover.shape == :pointer
    area = QuestionPanel.area(modal.tools.question_flow, Screen.panes(modal))

    assert {:noreply, _covered, render?: false, intents: [{:mouse_pointer, :restore}]} =
             move(modal, area.x + 2, area.y + 2)
  end

  test "scrollback uses the same visible marker as clicking, including resize and return to latest" do
    state = enabled() |> Map.put(:lines, Enum.reverse(said(100))) |> press("page_up")
    pane = Screen.transcript_pane(state)
    title = Screen.scrollback_title(state.scroll)
    x = pane.x + div(pane.width - String.length(title), 2)

    assert {:noreply, over, render?: false, intents: [{:mouse_pointer, :pointer}]} =
             move(state, x, pane.y + pane.height - 1)

    assert {:noreply, latest, intents: [{:mouse_pointer, :restore}]} =
             TUI.handle_event(
               %Mouse{kind: "down", button: "left", x: x, y: pane.y + pane.height - 1},
               over
             )

    assert latest.scroll == 0

    assert {:noreply, _resized, _opts} =
             TUI.handle_event(%ExRatatui.Event.Resize{width: 40, height: 16}, over)
  end

  test "drag selection restores a hand and never opens a target" do
    state = enabled()
    {:noreply, over, _opts} = move(state, 10, 1)

    assert {:noreply, pressed} =
             TUI.handle_event(%Mouse{kind: "down", button: "left", x: 10, y: 1}, over)

    assert {:noreply, dragged, intents: [{:mouse_pointer, :restore}]} =
             TUI.handle_event(%Mouse{kind: "drag", button: "left", x: 16, y: 1}, pressed)

    assert dragged.selection
    assert dragged.terminal.link_press == nil
  end

  test "unknown, headless and remote transports keep clicks without any pointer effect" do
    for transport <- [:local, :ssh, :distributed, :unknown] do
      state = TUI.new(test_mode: {80, 24}, transport: transport, hover_pointer: true)
      refute state.terminal.hover.enabled?
      assert {:noreply, _same, render?: false} = move(state, 10, 1)
    end
  end

  test "the supported cell transport delivers intents without redrawing for motion" do
    owner = self()

    entry =
      Lemieux.Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => "Visit [Google](https://google.com)"}]
      })

    session = fake_session(snapshot("01SESSION", [entry]))
    canvas = ExRatatui.CellSession.new(80, 24)

    {:ok, runtime} =
      ExRatatui.Transport.start_server(
        mod: TUI,
        name: nil,
        transport:
          {:cell_session, canvas, fn _diff -> :ok end,
           fn intent -> send(owner, {:intent, intent}) end},
        hover_pointer: true,
        test_mode: {80, 24},
        start: fn -> {:ok, session} end
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    state = :sys.get_state(runtime).user_state
    assert state.terminal.hover.enabled?

    {x, y} =
      Enum.find(for(y <- 0..23, x <- 0..79, do: {x, y}), fn {x, y} ->
        match?({:link, _, _}, Pointer.target_at(state, %Mouse{x: x, y: y}))
      end)

    before = ExRatatui.Runtime.snapshot(runtime).render_count
    event = %Mouse{kind: "moved", x: x, y: y}
    # 0.20's inject_event/2 omits flushing intents. Use the public transport
    # input message to exercise the actual cell transport delivery path.
    send(runtime, {:ex_ratatui_event, event})
    assert :sys.get_state(runtime).user_state.terminal.hover.shape == :pointer
    assert_receive {:intent, {:mouse_pointer, :pointer}}
    send(runtime, {:ex_ratatui_event, event})
    assert ExRatatui.Runtime.snapshot(runtime).render_count == before
    refute_receive {:intent, _}, 20
    key = %ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"]}
    monitor = Process.monitor(runtime)
    send(runtime, {:ex_ratatui_event, key})
    send(runtime, {:ex_ratatui_event, key})
    assert_receive {:intent, {:mouse_pointer, :restore}}
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    refute Process.alive?(runtime)
  end
end
