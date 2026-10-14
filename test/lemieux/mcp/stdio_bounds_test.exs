defmodule Lemieux.MCP.StdioBoundsTest do
  use ExUnit.Case, async: true
  alias Lemieux.MCP.Transport.Stdio

  defp state(opts) do
    {:ok, config} = Stdio.configure(%{"command" => "cat"}, stdio_limits: opts)
    {:ok, state} = Stdio.connect(config)
    on_exit(fn -> Stdio.close(state) end)
    state
  end

  test "fragmented messages retain only a bounded partial line" do
    state = state(max_frame_bytes: 32, max_buffer_bytes: 64)
    port = state.port
    assert {:ok, [], state} = Stdio.handle_message(state, {port, {:data, "{\"id\":"}})
    assert {:ok, [%{"id" => 1}], state} = Stdio.handle_message(state, {port, {:data, "1}\n"}})
    assert state.buffer == ""

    assert {:closed, {:stdio_limit, :frame}, _state} =
             Stdio.handle_message(state, {port, {:data, String.duplicate("x", 33)}})

    assert Port.info(port) == nil
  end

  test "oversized complete frames and cumulative output terminate explicitly" do
    state = state(max_frame_bytes: 16, max_total_bytes: 24)

    assert {:closed, {:stdio_limit, :frame}, _state} =
             Stdio.handle_message(state, {state.port, {:data, String.duplicate("x", 17) <> "\n"}})

    state = state(max_frame_bytes: 16, max_total_bytes: 24)

    assert {:ok, [%{"id" => 1}], state} =
             Stdio.handle_message(state, {state.port, {:data, "{\"id\":1}\n"}})

    assert {:ok, [%{"id" => 2}], state} =
             Stdio.handle_message(state, {state.port, {:data, "{\"id\":2}\n"}})

    assert {:closed, {:stdio_limit, :total}, _state} =
             Stdio.handle_message(state, {state.port, {:data, "{\"id\":3}\n"}})
  end

  test "outbound frames are bounded and close is idempotent" do
    state = state(max_frame_bytes: 16)

    assert {:error, {:stdio_limit, :frame}, _state} =
             Stdio.notify(state, %{"message" => String.duplicate("x", 32)})

    assert :ok = Stdio.close(state)
    assert :ok = Stdio.close(state)
  end

  test "invalid stdout is counted without exporting its content" do
    state = state(max_diagnostic_bytes: 4)
    secret = "secret-token"

    assert {:closed, {:stdio_limit, :diagnostics}, state} =
             Stdio.handle_message(state, {state.port, {:data, secret <> "\n"}})

    refute inspect(state) =~ secret
  end

  test "invalid limits are rejected before a launcher runs" do
    assert {:error, reason} =
             Stdio.configure(%{"command" => "cat"}, stdio_limits: [max_frame_bytes: 0])

    assert reason =~ "stdio limits"
  end
end
