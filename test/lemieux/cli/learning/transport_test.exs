defmodule Lemieux.CLI.Learning.TransportTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lemieux.CLI.Learning.Transport
  alias Lemieux.{Entry, Provider, ProviderPool, Request}
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  setup do
    previous = Application.fetch_env(:req_llm, :finch)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:req_llm, :finch, value)
        :error -> Application.delete_env(:req_llm, :finch)
      end

      capture_log(fn -> assert :ok = ProviderPool.restart(:req_llm) end)
    end)

    :ok
  end

  test "qualification streams use distinct sockets without hiding another dispatch" do
    capture_log(fn ->
      Application.put_env(:req_llm, :finch,
        name: ReqLLM.Finch,
        pools: %{default: [protocols: [:http1], size: 1, count: 1]}
      )

      assert :ok = ProviderPool.restart(:req_llm)
      [shared, shared_again] = two_requests()
      assert shared == shared_again

      assert :ok = Transport.prepare()
      supervisor = Process.whereis(ReqLLM.Supervisor)
      assert is_pid(supervisor)
      assert :ok = Transport.prepare()
      assert Process.whereis(ReqLLM.Supervisor) == supervisor

      [first, second] = two_requests()
      refute first == second
      refute_receive {:socket_request, _}, 50
    end)
  end

  test "preparing the isolated host preserves destination and TLS options" do
    options = [
      protocols: [:http2],
      size: 3,
      count: 2,
      conn_opts: [transport_opts: [verify: :verify_peer]]
    ]

    Application.put_env(:req_llm, :finch,
      name: ReqLLM.Finch,
      pools: %{"https://fixture.invalid" => options, default: options}
    )

    capture_log(fn ->
      assert :ok = Transport.prepare()
      configuration = Application.fetch_env!(:req_llm, :finch)
      assert configuration[:name] == ReqLLM.Finch
      assert map_size(configuration[:pools]) == 2

      for destination <- [:default, "https://fixture.invalid"] do
        configured = configuration[:pools][destination]
        assert configured[:conn_opts] == options[:conn_opts]
        assert configured[:size] == 3
        assert configured[:count] == 2
        assert configured[:protocols] == [:http1]
        assert configured[:conn_max_idle_time] == 0
      end
    end)
  end

  defp two_requests do
    owner = self()
    counter = :atomics.new(1, [])

    {url, listener, server} =
      HTTPFixture.server(
        fn _path, _headers, _body, socket -> serve(socket, owner, counter) end,
        requests: 2
      )

    on_exit(fn ->
      ref = Process.monitor(server)
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
      assert_receive {:DOWN, ^ref, :process, ^server, _}
    end)

    provider =
      Adapter.new(
        api_key: "fixture-key",
        max_retries: 0,
        transport_routes: %{
          "openai" => [provider: "openai", base_url: url, wire_protocol: "openai_chat"]
        }
      )

    request =
      Request.new("openai:gpt-5",
        entries: [Entry.new(:user, %{"text" => "fixture"})],
        params: [max_tokens: 32]
      )

    for _ <- 1..2 do
      assert :ok = Provider.run(provider, request, &send(owner, {:event, &1}))
      assert_receive {:socket_request, socket}
      assert_receive {:event, {:usage, %{"input_tokens" => 2, "output_tokens" => 1}}}
      socket
    end
  end

  defp serve(socket, owner, counter) do
    send(owner, {:socket_request, socket})
    count = :atomics.add_get(counter, 1, 1)
    body = response_body()

    :ok =
      :gen_tcp.send(socket, [
        "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
        "content-length: #{byte_size(body)}\r\nconnection: keep-alive\r\n\r\n",
        body
      ])

    if count < 2 do
      case read_request(socket, "") do
        :ok -> serve(socket, owner, counter)
        {:error, :closed} -> :sent
      end
    else
      :sent
    end
  end

  defp read_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, head)
        read_body(socket, String.to_integer(length), body)

      [_head] ->
        with {:ok, more} <- :gen_tcp.recv(socket, 0, 60_000),
             do: read_request(socket, bytes <> more)
    end
  end

  defp read_body(_socket, length, body) when byte_size(body) >= length, do: :ok

  defp read_body(socket, length, body) do
    with {:ok, more} <- :gen_tcp.recv(socket, length - byte_size(body), 60_000),
         do: read_body(socket, length, body <> more)
  end

  defp response_body do
    chunks = [
      %{model: "gpt-5", choices: [%{index: 0, delta: %{content: "ok"}}]},
      %{
        model: "gpt-5",
        choices: [%{index: 0, delta: %{}, finish_reason: "stop"}],
        usage: %{prompt_tokens: 2, completion_tokens: 1, total_tokens: 3}
      }
    ]

    Enum.map_join(chunks, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <>
      "data: [DONE]\n\n"
  end
end
