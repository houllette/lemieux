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
    put_in(state.terminal.hover, %{state.terminal.hover | enabled?: true, native?: false})
  end

  defp move(state, x, y, modifiers \\ []) do
    TUI.handle_event(%Mouse{kind: "moved", x: x, y: y, modifiers: modifiers}, state)
  end

  test "an explicitly capable local host uses the native runtime option" do
    state = TUI.new(hover_pointer: true, test_mode: {80, 24})
    state = sized(%{state | lines: [{:model, "Visit [Google](https://google.com)"}]})
    assert state.terminal.hover.enabled?

    assert {:noreply, over, opts} = move(state, 10, 1)
    assert opts[:pointer] == :pointer
    assert opts[:render?] == false
    assert {:noreply, same, render?: false} = move(over, 11, 1)
    assert {:noreply, _left, opts} = move(same, 1, 1)
    assert opts[:pointer] == :default
    assert opts[:render?] == false
    assert {:stop, _stopped, pointer: :default} = Hover.transition({:stop, over})
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

  test "unknown and remote transports keep motion inert even with opt-in" do
    for transport <- [:ssh, :session, :distributed, :distributed_server, :unknown] do
      state = TUI.new(test_mode: {80, 24}, transport: transport, hover_pointer: true)
      refute state.terminal.hover.enabled?
      assert {:noreply, _same, render?: false} = move(state, 10, 1)
    end
  end

  test "native scrollback hover resets on resize and return to latest" do
    state = TUI.new(hover_pointer: true, test_mode: {80, 24}) |> sized()
    state = %{state | lines: Enum.reverse(said(100))} |> press("page_up")
    pane = Screen.transcript_pane(state)
    title = Screen.scrollback_title(state.scroll)
    x = pane.x + div(pane.width - String.length(title), 2)
    y = pane.y + pane.height - 1

    assert {:noreply, over, opts} = move(state, x, y)
    assert opts[:pointer] == :pointer

    assert {:noreply, resized, opts} =
             TUI.handle_event(%ExRatatui.Event.Resize{width: 40, height: 16}, over)

    assert opts[:pointer] == :default
    assert resized.terminal.hover.shape == :restore

    assert {:noreply, latest, pointer: :default} =
             TUI.handle_event(%Mouse{kind: "down", button: "left", x: x, y: y}, over)

    assert latest.scroll == 0
  end

  test "queued motion cannot reapply a hand before the external editor starts" do
    owner = self()

    state =
      TUI.new(
        hover_pointer: true,
        test_mode: {80, 24},
        editor: fn text ->
          send(owner, :editing)
          {:ok, text}
        end
      )
      |> sized()

    state = %{state | lines: [{:model, "Visit [Google](https://google.com)"}]}
    {:noreply, over, _opts} = move(state, 10, 1)

    assert {:noreply, pending, pointer: :default} = TUI.handle_event(key("g", ["ctrl"]), over)
    assert_receive :external_edit
    refute_received :editing
    assert {:noreply, pending, render?: false} = move(pending, 10, 1)
    assert pending.terminal.hover.shape == :restore
    assert {:noreply, returned} = TUI.handle_info(:external_edit, pending)
    assert_receive :editing
    assert returned.terminal.hover.shape == :restore
    assert returned.terminal.hover.event == nil
    assert {:noreply, _over, opts} = move(returned, 10, 1)
    assert opts[:pointer] == :pointer
  end

  test "native hover covers snippet frames and restores when the target is covered or dragged" do
    state =
      TUI.new(hover_pointer: true, test_mode: {80, 24})
      |> sized()
      |> TUI.Transcript.say(:model, "before\n```text\n  hello\nworld\n```\nafter")
      |> TUI.Transcript.finish_line()

    assert {:noreply, over, opts} = move(state, 4, 2)
    assert opts[:pointer] == :pointer
    assert over.selection == nil
    assert over.terminal.feedback == nil

    assert {:noreply, _covered, pointer: :default} =
             Hover.transition({:noreply, %{over | overlay: %{}}})

    assert {:noreply, pressed} =
             TUI.handle_event(%Mouse{kind: "down", button: "left", x: 4, y: 2}, over)

    assert {:noreply, dragged, pointer: :default} =
             TUI.handle_event(%Mouse{kind: "drag", button: "left", x: 7, y: 3}, pressed)

    assert dragged.selection
  end

  test "the native runtime deduplicates motion and resets before an editor handoff and shutdown" do
    owner = self()

    editor = fn text ->
      send(owner, {:editor, text})
      {:ok, "edited"}
    end

    runtime =
      native_runtime(
        editor: editor,
        mouse_pointer_fn: fn shape ->
          send(owner, {:pointer, shape})
          :ok
        end
      )

    state = :sys.get_state(runtime).user_state
    event = target_event(state, :link)

    # The callback tests assert render?: false. Whole-runtime frame counts
    # also include the independent caret/chrome timers, so a slow motion
    # burst must not mistake one of those frames for a hover redraw.
    for _n <- 1..100, do: ExRatatui.Runtime.inject_event(runtime, event)
    assert_receive {:pointer, :pointer}
    refute_receive {:pointer, _}, 20
    assert ExRatatui.Runtime.snapshot(runtime).pointer == :pointer
    assert :sys.get_state(runtime).user_state.selection == nil

    :ok = ExRatatui.Runtime.inject_event(runtime, key("g", ["ctrl"]))
    # Messages from the same process retain order: the reset must precede
    # the editor, not merely occur at some point after it returns.
    assert_receive {kind, value} when kind in [:pointer, :editor]
    assert {kind, value} == {:pointer, :default}
    assert_receive {kind, value} when kind in [:pointer, :editor]
    assert {kind, value} == {:editor, ""}
    assert typed(:sys.get_state(runtime).user_state) == "edited"
    assert ExRatatui.Runtime.snapshot(runtime).pointer == :default
    refute_receive {:pointer, :pointer}, 20

    :ok = ExRatatui.Runtime.inject_event(runtime, event)
    assert_receive {:pointer, :pointer}
    GenServer.stop(runtime)
    assert_receive {:pointer, :default}
    refute Process.alive?(runtime)
  end

  test "headless native hover is recorded without needing a terminal writer" do
    runtime = native_runtime([])
    event = target_event(:sys.get_state(runtime).user_state, :link)
    :ok = ExRatatui.Runtime.inject_event(runtime, event)
    assert ExRatatui.Runtime.snapshot(runtime).pointer == :pointer
    GenServer.stop(runtime)
  end

  defp native_runtime(opts) do
    entry =
      Lemieux.Entry.new(:assistant, %{
        "content" => [%{"type" => "text", "text" => "Visit [Google](https://google.com)"}]
      })

    session = fake_session(snapshot("01SESSION", [entry]))

    {:ok, runtime} =
      TUI.start_link(
        opts ++
          [
            name: nil,
            test_mode: {80, 24},
            hover_pointer: true,
            start: fn -> {:ok, session} end
          ]
      )

    on_exit(fn -> if Process.alive?(runtime), do: GenServer.stop(runtime) end)
    runtime
  end

  defp target_event(state, kind) do
    {x, y} =
      Enum.find(for(y <- 0..23, x <- 0..79, do: {x, y}), fn {x, y} ->
        case Pointer.target_at(state, %Mouse{x: x, y: y}) do
          {^kind, _, _} -> true
          _other -> false
        end
      end)

    %Mouse{kind: "moved", x: x, y: y}
  end

  test "the cell transport delivers deduplicated pointer and stopping intents through injected events" do
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

    event = %Mouse{kind: "moved", x: x, y: y}
    :ok = ExRatatui.Runtime.inject_event(runtime, event)
    assert :sys.get_state(runtime).user_state.terminal.hover.shape == :pointer
    assert_receive {:intent, {:mouse_pointer, :pointer}}
    :ok = ExRatatui.Runtime.inject_event(runtime, event)
    refute_receive {:intent, _}, 20
    key = %ExRatatui.Event.Key{code: "c", modifiers: ["ctrl"]}
    monitor = Process.monitor(runtime)
    :ok = ExRatatui.Runtime.inject_event(runtime, key)
    :ok = ExRatatui.Runtime.inject_event(runtime, key)
    assert_receive {:intent, {:mouse_pointer, :restore}}
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    refute Process.alive?(runtime)
  end
end
