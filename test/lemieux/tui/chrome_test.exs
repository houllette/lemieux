defmodule Lemieux.TUI.ChromeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Event.Resize
  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI
  alias Lemieux.TUI.{Responsive, Width}

  import Lemieux.TUI.TestSupport,
    only: [fake_session: 1, snapshot: 1, snapshot: 2, type: 2, suggestions: 1]

  test "overflow gets a quarter-second clock independent of cursor blinking and stops when it fits" do
    clock = :atomics.new(1, [])

    state =
      TUI.new(
        id: "01SESSION",
        model: "test:" <> String.duplicate("long-model-", 12),
        test_mode: {80, 24},
        clock: fn -> :atomics.get(clock, 1) end
      )

    assert {:noreply, state} = TUI.handle_event(%Resize{width: 80, height: 24}, state)
    assert %{timer: timer, token: token} = Map.get(state.terminal, :chrome_timer)
    assert Process.read_timer(timer) <= 250
    initial = header(state)
    blink = state.terminal.cursor_blink
    Process.cancel_timer(timer)
    :atomics.put(clock, 1, 250)
    assert {:noreply, state} = TUI.handle_info({:chrome_tick, token}, state)
    assert header(state) != initial
    assert state.terminal.cursor_blink == blink

    timer = state.terminal.chrome_timer.timer
    assert {:noreply, state} = TUI.handle_event(%Resize{width: 2_000, height: 24}, state)
    assert state.terminal.chrome_timer == nil
    assert Process.read_timer(timer) == false
    assert {:noreply, ^state, render?: false} = TUI.handle_info({:chrome_tick, token}, state)

    assert {:noreply, hidden} = TUI.handle_event(%Resize{width: 80, height: 1}, state)
    assert hidden.terminal.chrome_timer == nil
  end

  test "ticker moves one terminal column at a time without cutting wide graphemes" do
    assert Responsive.scroll("中🙂abc", 3, 0) == "中"
    assert Responsive.scroll("中🙂abc", 3, 1) == " 🙂"
    assert Responsive.scroll("中🙂abc", 3, 2) == "🙂a"
    assert Responsive.scroll("中🙂abc", 3, 3) == " ab"

    for width <- 0..8, frame <- 0..30 do
      text = Responsive.scroll("中🙂long source", width, frame)
      assert Width.of(text) <= width
      assert String.valid?(text)
    end
  end

  test "the identity stays stationary while only header metadata scrolls" do
    state =
      TUI.new(
        id: "01SESSION",
        cwd: "/work/project",
        model: "test:" <> String.duplicate("model-", 20),
        test_mode: {80, 24},
        clock: fn -> 0 end
      )
      |> put_in([Access.key!(:appearance), :name], "my-session")

    identity = " lemieux (v#{Lemieux.version()}) · /work/project · my-session · "
    initial = header(state)
    next = header(%{state | clock: fn -> 6_000 end})
    assert String.starts_with?(initial, identity)
    assert String.starts_with?(next, identity)
    assert next != initial
    assert Width.of(next) <= 78
  end

  test "fitting metadata is static and tiny identity layouts stay within the viewport" do
    assert Responsive.header("app · folder · session", "model", 40, 0) ==
             Responsive.header("app · folder · session", "model", 40, 99)

    for width <- 0..40 do
      text = Responsive.header("app · /長い/場所 · " <> String.duplicate("🙂", 12), "model", width, 0)
      assert Width.of(text) <= width
      assert String.valid?(text)
    end

    shortened =
      Responsive.header("app · very-long-folder · session", String.duplicate("model", 10), 30, 0)

    advanced =
      Responsive.header("app · very-long-folder · session", String.duplicate("model", 10), 30, 8)

    fixed = shortened |> String.split(" · ") |> Enum.drop(-1) |> Enum.join(" · ")
    assert String.ends_with?(fixed, "…")
    assert String.starts_with?(advanced, fixed <> " · ")
  end

  test "header progress follows screen time and survives streamed transcript updates" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)

    state =
      TUI.new(
        id: "01SESSION",
        model: "test:" <> String.duplicate("long-model-", 12),
        test_mode: {80, 24},
        clock: fn -> :atomics.get(clock, 1) end
      )

    initial = header(state)
    :atomics.put(clock, 1, 7_000)
    advanced = header(state)
    assert advanced != initial

    state =
      Enum.reduce(1..20, state, fn index, state ->
        assert {:noreply, next} =
                 TUI.handle_info({:lemieux, state.id, {:text_delta, "chunk #{index}\n"}}, state)

        assert header(next) == advanced
        next
      end)

    :atomics.put(clock, 1, 8_000)
    assert header(state) != advanced
    assert state.terminal.cursor_blink.visible?
  end

  test "enabled fast service stays visible in red beside scrolling metadata" do
    state =
      TUI.new(id: "fast", model: "test:" <> String.duplicate("long-", 30), test_mode: {80, 24})

    assert {:noreply, state} =
             TUI.handle_info({:lemieux, state.id, {:fast_mode_changed, "off", "fast"}}, state)

    for width <- [8, 35, 80], frame <- [0, 2_000] do
      title = header(%{state | clock: fn -> frame end}, width)
      assert %ExRatatui.Text.Line{} = title
      assert Enum.any?(title.spans, &(&1.content =~ "FAST" and &1.style.fg == :red)) or width < 6
      assert Width.of(Enum.map_join(title.spans, & &1.content)) <= max(width - 2, 0)
    end

    assert {:noreply, state} =
             TUI.handle_info({:lemieux, state.id, {:fast_mode_changed, "fast", "off"}}, state)

    assert is_binary(header(state))
    assert header(state, 2) == ""
  end

  test "fast badge joins fitting metadata with one space and disappears cleanly" do
    state = TUI.new(id: "fast", model: "test:model", test_mode: {160, 24})
    original = header(state, 160)
    enabled = put_in(state.conversation.fast_mode, "fast")
    title = header(enabled, 160)
    assert Enum.map_join(title.spans, & &1.content) =~ "effort default · FAST "
    refute Enum.map_join(title.spans, & &1.content) =~ "default  ·"
    assert header(put_in(enabled.conversation.fast_mode, "off"), 160) == original
  end

  test "resuming uses the session's active mode and older snapshots default to off" do
    session = fake_session(Map.put(snapshot("restored"), :fast_mode, "ultrafast"))
    assert {:ok, state} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert state.conversation.fast_mode == "ultrafast"
    assert Enum.any?(header(state).spans, &(&1.content =~ "ULTRAFAST" and &1.style.fg == :red))
    old_session = fake_session(snapshot("older"))
    assert {:ok, old} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, old_session} end)
    assert old.conversation.fast_mode == "off"
    assert is_binary(header(old))
  end

  test "the last prepared access program is read-only, independent of priority, and restored" do
    model = "openai:gpt-6-sol"

    requested =
      Lemieux.Request.new(model,
        params: [provider_options: [access_programs: %{"cyber" => "standard"}]]
      )
      |> Lemieux.RequestSnapshot.build()

    entry = Lemieux.Entry.new(:request, requested)
    state = TUI.new(id: "access", model: model, models: [model], test_mode: {160, 24})
    state = put_in(state.conversation.priority, "fast")

    assert {:noreply, observed} = TUI.handle_info({:lemieux, state.id, {:entry, entry}}, state)
    assert observed.session_view.requested_access_program == "Standard"
    assert Enum.map_join(header(observed, 100).spans, & &1.content) =~ "STANDARD REQ · FAST"
    assert Enum.map_join(header(observed, 21).spans, & &1.content) =~ "STD REQ · FAST"

    assert %{items: [label]} = observed |> type("/model ") |> suggestions()
    assert label =~ "last requested Standard"

    wrong_request =
      Lemieux.Entry.new(:assistant, %{
        "request_id" => "prior-request",
        "confirmed_access_program" => "standard"
      })

    confirmation =
      Lemieux.Entry.new(:assistant, %{
        "request_id" => requested["id"],
        "confirmed_access_program" => "standard"
      })

    assert {:noreply, unconfirmed} =
             TUI.handle_info({:lemieux, state.id, {:entry, wrong_request}}, observed)

    assert unconfirmed.session_view.confirmed_access_program == nil

    assert {:noreply, confirmed} =
             TUI.handle_info({:lemieux, state.id, {:entry, confirmation}}, unconfirmed)

    assert confirmed.session_view.confirmed_access_program == "Standard"
    assert Enum.map_join(header(confirmed, 100).spans, & &1.content) =~ "STANDARD REQ/CONF · FAST"
    assert Enum.map_join(header(confirmed, 21).spans, & &1.content) =~ "STD REQ/CONF · FAST"

    saved = Map.put(snapshot("restored", [entry, confirmation]), :model, model)
    session = fake_session(saved)
    assert {:ok, reopened} = TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end)
    assert reopened.session_view.requested_access_program == "Standard"
    assert reopened.session_view.confirmed_access_program == "Standard"

    no_program =
      Lemieux.Entry.new(:request, Lemieux.RequestSnapshot.build(Lemieux.Request.new(model)))

    assert {:noreply, ordinary} =
             TUI.handle_info({:lemieux, state.id, {:entry, no_program}}, confirmed)

    assert ordinary.session_view.requested_access_program == nil
    assert ordinary.session_view.confirmed_access_program == nil
    assert Enum.map_join(header(ordinary, 100).spans, & &1.content) =~ "FAST"
    refute Enum.map_join(header(ordinary, 100).spans, & &1.content) =~ "REQ"

    config = Lemieux.Entry.new(:session, %{"params" => %{"standard_access" => true}})
    assert {:noreply, next} = TUI.handle_info({:lemieux, state.id, {:entry, config}}, ordinary)
    assert Enum.map_join(header(next, 100).spans, & &1.content) =~ "STANDARD NEXT · FAST"
  end

  defp header(state, width \\ 80) do
    [{%Paragraph{block: %{title: title}}, _} | _] =
      TUI.render(state, %Frame{width: width, height: 24})

    title
  end
end
