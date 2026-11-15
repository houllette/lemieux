defmodule Lemieux.TUI.ChromeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI
  alias Lemieux.TUI.{Responsive, Width}

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

  defp header(state, width \\ 80) do
    [{%Paragraph{block: %{title: title}}, _} | _] =
      TUI.render(state, %Frame{width: width, height: 24})

    title
  end
end
