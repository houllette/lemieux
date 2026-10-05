defmodule Lemieux.Providers.ReqLLMCleanupTest do
  # These subsecond deadline checks share ReqLLM's named Finch pool. Running
  # alongside the entire suite can exhaust the deadline before connecting,
  # which tests scheduler contention instead of cleanup of an acquired stream.
  use ExUnit.Case, async: false
  alias Lemieux.{Entry, Request}
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  test "a semantic caller timeout closes a still-active HTTP stream before returning" do
    assert_closed([], :comments, nil)
  end

  test "semantic idle timeout closes a connection even while HTTP keepalives arrive" do
    assert_closed([receive_timeout: 1_000, stream_idle_timeout: 150], :comments, :stream_idle)
  end

  test "the total deadline terminates a stream that keeps producing semantic content" do
    assert_closed(
      [receive_timeout: 1_000, stream_idle_timeout: 1_000, total_timeout: 200],
      :content,
      :total
    )
  end

  defp assert_closed(options, mode, expected_kind) do
    parent = self()

    {url, listener, server} =
      HTTPFixture.server(fn _, _, socket ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
          )

        send(parent, :connected)
        heartbeat_until_closed(socket, parent, mode)
        :sent
      end)

    {Adapter, state} =
      Adapter.new(
        Keyword.merge(
          [
            api_keys: %{zai_coding_plan: "fixture-key"},
            receive_timeout: 150,
            max_retries: 0,
            base_url: url
          ],
          options
        )
      )

    request =
      Request.new("zai_coding_plan:glm-5.3-flash",
        entries: [Entry.new(:user, %{"text" => "fixture"}, seq: 1)]
      )

    caller =
      spawn(fn ->
        result = Adapter.run(state, request, &send(parent, {:provider_event, &1}))
        send(parent, {:result, result})
        # Keeping the consumer alive prevents process death from hiding a leaked
        # stream; the provider boundary itself must release it on return.
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn ->
      Process.exit(caller, :kill)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    assert_receive :connected
    assert_receive {:result, {:error, reason}}
    assert_receive {:provider_event, {:response_metadata, metadata}}
    # A caller-only timeout precedes terminal server metadata; it stays
    # unknown rather than manufacturing HTTP 200 from an open connection.
    assert metadata.status == if(expected_kind, do: 200, else: nil)
    if expected_kind, do: assert(inspect(reason) =~ Atom.to_string(expected_kind))
    assert Process.alive?(caller)
    assert_receive :peer_closed
    send(caller, :finish)
  end

  defp heartbeat_until_closed(socket, parent, mode) do
    case :gen_tcp.recv(socket, 0, 20) do
      {:error, :timeout} ->
        data = chunk(mode)

        case :gen_tcp.send(socket, [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"]) do
          :ok -> heartbeat_until_closed(socket, parent, mode)
          {:error, _} -> send(parent, :peer_closed)
        end

      {:error, :closed} ->
        send(parent, :peer_closed)
    end
  end

  defp chunk(:comments), do: ": keepalive\n\n"

  defp chunk(:content),
    do:
      "data: " <>
        JSON.encode!(%{choices: [%{index: 0, delta: %{content: "x"}, finish_reason: nil}]}) <>
        "\n\n"
end
