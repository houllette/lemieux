defmodule Lemieux.TUI.ChromeTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Frame
  alias ExRatatui.Widgets.Paragraph
  alias Lemieux.TUI

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
