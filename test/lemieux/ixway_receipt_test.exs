defmodule Lemieux.IxwayReceiptTest do
  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Ixway
  alias Lemieux.Provider
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @request_id "req_123"
  @receipt_path "/v1/ixway/requests/#{@request_id}"
  @receipt_token "private-receipt-token"
  @key "private-gateway-key"
  @catalog_source "llm_db 0.12.0 openai/gpt-5.6-sol #{String.duplicate("a", 64)}"

  test "a streamed answer completes before a pending receipt settles" do
    estimate = %{
      "state" => "estimated",
      "amount" => "13.38",
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => "openai",
      "reference_source" => @catalog_source,
      "reason" => nil,
      "excludes" => ["subscription_fee", "api_tool_fees", "api_storage_fees"]
    }

    {provider, cleanup} =
      server_provider(
        [reply(202, %{}, [{"retry-after", "0"}]), reply(200, %{"api_equivalent" => estimate})],
        adapter_options: [
          response_metadata: [
            headers: ~w(x-ixway-key x-ixway-receipt-url x-ixway-receipt-token),
            model_header: "x-ixway-receipt-token"
          ]
        ]
      )

    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:event, {:text_delta, "hello"}}
    assert_receive {:event, {:message, %{"ixway" => disclosure}}}
    assert disclosure["request_id"] == @request_id
    refute Map.has_key?(disclosure, "receipt_token")
    refute Map.has_key?(disclosure, "receipt_url")
    assert_receive {:event, {:usage, usage}}
    assert Lemieux.Usage.normalize(usage, "ixway:team/coding")["cost_usd"] == nil
    assert_receive {:event, {:done, :stop}}
    assert_receive {:event, {:response_metadata, metadata}}
    assert metadata.headers == %{}
    assert metadata.resolved_model == nil
    assert_receive {:receipt_request, @receipt_path, receipt_headers}
    assert receipt_headers["x-ixway-key"] == @key
    assert receipt_headers["x-ixway-receipt-token"] == @receipt_token
    assert_receive {:receipt_request, @receipt_path, _headers}
    assert_receive {:route_observation, "request-1", %{"data" => settled} = observation}
    assert observation["kind"] == "ixway_api_equivalent"
    assert settled["amount"] == "13.38"
    assert settled["reference_provider"] == "openai"
    assert settled["reference_source"] == @catalog_source
    assert settled["excludes"] == estimate["excludes"]

    {conversation, []} =
      Conversation.event(Conversation.new(), {
        :route_observation,
        Map.put(observation, "request_id", "request-1")
      })

    assert Conversation.status(conversation) =~ "estimated cost: $13.38"
    assert Conversation.context_report(conversation) =~ "openai / #{@catalog_source}"
    assert Conversation.context_report(conversation) =~ "subscription fee"
    assert Conversation.context_report(conversation) =~ "current catalog rates"

    visible = inspect([disclosure, usage, observation, metadata])
    refute visible =~ @key
    refute visible =~ @receipt_token
  end

  test "a receipt without api_equivalent produces no comparison" do
    {provider, cleanup} = server_provider([reply(200, %{"cost" => %{"amount" => "2.00"}})])
    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:receipt_request, @receipt_path, _headers}
    refute_receive {:route_observation, _, _}, 100
  end

  test "a pending receipt cannot hold the streamed answer open" do
    {provider, cleanup} = server_provider([reply(200, %{})], receipt_gate: true)
    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:event, {:done, :stop}}
    assert_receive {:receipt_gate, server}
    refute_receive {:route_observation, _, _}, 100
    send(server, :release_receipt)
  end

  test "a failed inference does not disclose receipt credentials through logs or events" do
    {provider, cleanup} = server_provider([], stream_status: 503)
    on_exit(cleanup)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} = run(provider)
        refute inspect(reason) =~ @receipt_token
        refute inspect(reason) =~ @key
      end)

    refute log =~ @receipt_token
    refute log =~ @key
    assert_receive {:event, {:response_metadata, metadata}}
    refute inspect(metadata) =~ @receipt_token
    refute inspect(metadata) =~ @key
    refute_receive {:receipt_request, _, _}, 100
    refute_receive {:route_observation, _, _}, 100
  end

  test "an unknown estimate preserves the gateway reason" do
    unknown = %{
      "state" => "unknown",
      "amount" => nil,
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => nil,
      "reference_source" => nil,
      "reason" => "no_api_catalog_model",
      "excludes" => ["subscription_fee"]
    }

    {provider, cleanup} = server_provider([reply(200, %{"api_equivalent" => unknown})])
    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:route_observation, "request-1", %{"data" => result} = observation}
    assert result["state"] == "unknown"
    assert result["amount"] == nil
    assert result["reason"] == "no_api_catalog_model"

    {conversation, []} =
      Conversation.event(Conversation.new(), {
        :route_observation,
        Map.put(observation, "request_id", "request-1")
      })

    assert Conversation.status(conversation) =~ "estimated cost: unknown (no_api_catalog_model)"
    assert Conversation.context_report(conversation) =~ "subscription fee"
  end

  test "404 and malformed amounts remain unknown" do
    {missing, cleanup} = server_provider([reply(404, %{})])
    on_exit(cleanup)
    assert :ok = run(missing)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "receipt_not_found"}}}

    bad = %{
      "state" => "estimated",
      "amount" => "1e999999",
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => "openai",
      "reference_source" => "openai/gpt-5.6-sol",
      "excludes" => []
    }

    {malformed, cleanup} = server_provider([reply(200, %{"api_equivalent" => bad})])
    on_exit(cleanup)
    assert :ok = run(malformed)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "invalid_estimate"}}}
  end

  test "a receipt URL outside the configured endpoint is refused without a request" do
    {provider, cleanup} =
      server_provider([],
        receipt_url: "https://attacker.example/v1/ixway/requests/#{@request_id}"
      )

    on_exit(cleanup)

    assert :ok = run(provider)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "invalid_receipt_url"}}}

    refute_receive {:receipt_request, _, _}, 100
  end

  test "a receipt redirect is not followed" do
    {provider, cleanup} =
      server_provider([reply(302, %{}, [{"location", "https://attacker.example"}])])

    on_exit(cleanup)

    assert :ok = run(provider)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "receipt_http_302"}}}
  end

  test "a receipt that echoes a credential cannot put it in a visible comparison" do
    echoed = %{
      "state" => "estimated",
      "amount" => "13.38",
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => "openai",
      "reference_source" => "catalog/#{@receipt_token}",
      "excludes" => []
    }

    {provider, cleanup} = server_provider([reply(200, %{"api_equivalent" => echoed})])
    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:route_observation, "request-1", %{"data" => comparison} = observation}
    assert comparison["reason"] == "invalid_estimate"
    refute inspect(comparison) =~ @receipt_token
    refute inspect(comparison) =~ @key
    refute inspect(observation) =~ @receipt_token
  end

  test "a catalog source with a newline cannot enter a visible comparison" do
    unsafe = %{
      "state" => "estimated",
      "amount" => "0.01338",
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => "openai",
      "reference_source" => @catalog_source <> "\nforged status",
      "excludes" => []
    }

    {provider, cleanup} = server_provider([reply(200, %{"api_equivalent" => unsafe})])
    on_exit(cleanup)

    assert :ok = run(provider)
    assert_receive {:route_observation, "request-1", %{"data" => comparison} = observation}
    assert comparison["reason"] == "invalid_estimate"
    refute inspect(observation) =~ "forged status"
  end

  test "pending receipts stop after a bounded number of attempts" do
    responses = for _ <- 1..3, do: reply(202, %{}, [{"retry-after", "0"}])
    {provider, cleanup} = server_provider(responses)
    on_exit(cleanup)

    assert :ok = run(provider)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "settlement_pending"}}}

    for _ <- 1..3, do: assert_receive({:receipt_request, @receipt_path, _headers})
    refute_receive {:receipt_request, _, _}, 100
  end

  test "unavailable and timed out receipts leave the comparison unknown" do
    {unavailable, cleanup} = server_provider([reply(503, %{})])
    on_exit(cleanup)
    assert :ok = run(unavailable)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "receipt_http_503"}}}

    {timed_out, cleanup} =
      server_provider([reply(200, %{"api_equivalent" => %{}})], receipt_delay_ms: 2_500)

    on_exit(cleanup)
    assert :ok = run(timed_out)

    assert_receive {:route_observation, "request-1",
                    %{"data" => %{"reason" => "receipt_timeout"}}}
  end

  test "session displays a comparison without changing usage, spending, or transcript", %{
    tmp_dir: dir
  } do
    equivalent = %{
      "state" => "estimated",
      "amount" => "13.38",
      "currency" => "USD",
      "basis" => "api_catalog_token_equivalent",
      "billed" => false,
      "reference_provider" => "openai",
      "reference_source" => "openai/gpt-5.6-sol",
      "reason" => nil,
      "excludes" => ["subscription_fee", "api_tool_fees"]
    }

    {provider, cleanup} =
      server_provider([
        reply(200, %{
          "api_equivalent" => equivalent,
          "cost" => %{"state" => "known", "amount" => "42.00", "currency" => "USD"}
        })
      ])

    on_exit(cleanup)
    supervisor = :"ixway_receipt_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    assert {:ok, session} =
             Lemieux.start_session(
               supervisor: supervisor,
               provider: provider,
               model: "ixway:team/coding",
               store: JSONL.new(dir),
               tools: [],
               subscriber: self()
             )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "hello")
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    assert_receive {:lemieux, ^id, {:route_observation, %{"data" => comparison} = observation}},
                   5_000

    assert comparison["amount"] == "13.38"
    assert observation["request_id"]
    assert Session.budget(session).spent_usd == nil
    assert Session.snapshot(session).usage.direct["cost_usd"] == nil

    transcript = dir |> Path.join("**/*.jsonl") |> Path.wildcard() |> Enum.map_join(&File.read!/1)
    refute transcript =~ @key
    refute transcript =~ @receipt_token
    refute transcript =~ "13.38"
    refute transcript =~ "api_equivalent"
  end

  test "a local cost cap still refuses an unpriced Ixway request before inference", %{
    tmp_dir: dir
  } do
    provider =
      Ixway.provider(
        Ixway.new(
          endpoint: "https://gateway.example",
          api_key: @key,
          models: [%{"id" => "team/coding", "ixway_ingress_dialects" => ["openai_chat"]}]
        )
      )

    supervisor = :"ixway_budget_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    assert {:ok, session} =
             Lemieux.start_session(
               supervisor: supervisor,
               provider: provider,
               model: "ixway:team/coding",
               store: JSONL.new(dir),
               max_cost_usd: 1.0,
               tools: [],
               subscriber: self()
             )

    id = Session.id(session)
    assert :ok = Session.prompt(session, "hello")
    assert_receive {:lemieux, ^id, {:finished, {:budget, _}}}
    refute_receive {:lemieux, ^id, {:route_observation, _}}, 100
  end

  defp run(provider) do
    Provider.run(
      provider,
      Request.new("ixway:team/coding",
        context: %{request_id: "request-1", route_result_sink: self()},
        entries: [Lemieux.Entry.new(:user, %{"text" => "hello"}, seq: 1)]
      ),
      &send(self(), {:event, &1})
    )
  end

  defp server_provider(responses, opts \\ []) do
    parent = self()

    {endpoint, listener, server} =
      LemieuxTest.HTTPFixture.server(
        fn path, headers, _body, socket ->
          case path do
            "/v1/chat/completions" ->
              send_stream(socket, Keyword.get(opts, :receipt_url, @receipt_path), opts)
              :sent

            @receipt_path ->
              send(parent, {:receipt_request, path, headers})
              receipt_gate(opts, parent)
              Process.sleep(Keyword.get(opts, :receipt_delay_ms, 0))
              index = Process.get(:receipt_index, 0)
              Process.put(:receipt_index, index + 1)
              Enum.fetch!(responses, index)
          end
        end,
        requests: length(responses) + 1
      )

    connection =
      Ixway.new(
        endpoint: endpoint,
        api_key: @key,
        models: [%{"id" => "team/coding", "ixway_ingress_dialects" => ["openai_chat"]}]
      )

    adapter_options = Keyword.get(opts, :adapter_options, [])

    {Ixway.provider(connection, Keyword.merge([max_retries: 0], adapter_options)),
     fn ->
       Process.exit(server, :kill)
       :gen_tcp.close(listener)
     end}
  end

  defp send_stream(socket, receipt_url, opts) do
    if opts[:stream_status] == 503,
      do: send_failed_stream(socket, receipt_url),
      else: send_success_stream(socket, receipt_url)
  end

  defp send_failed_stream(socket, receipt_url) do
    body = JSON.encode!(%{"error" => %{"message" => "unavailable"}})

    :gen_tcp.send(socket, [
      "HTTP/1.1 503 Service Unavailable\r\ncontent-type: application/json\r\n",
      "x-ixway-request-id: #{@request_id}\r\n",
      "x-ixway-receipt-url: #{receipt_url}\r\n",
      "x-ixway-receipt-token: #{@receipt_token}\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  defp send_success_stream(socket, receipt_url) do
    data =
      "data: " <>
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "hello"}, "finish_reason" => nil}
          ]
        }) <>
        "\n\ndata: " <>
        JSON.encode!(%{
          "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 3}
        }) <>
        "\n\ndata: [DONE]\n\n"

    :gen_tcp.send(socket, [
      "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n",
      "x-ixway-request-id: #{@request_id}\r\n",
      "x-ixway-receipt-url: #{receipt_url}\r\n",
      "x-ixway-receipt-token: #{@receipt_token}\r\n",
      "content-length: #{byte_size(data)}\r\nconnection: close\r\n\r\n",
      data
    ])
  end

  defp reply(status, data, headers \\ []) do
    %{status: status, headers: headers, body: JSON.encode!(%{"data" => data})}
  end

  defp receipt_gate(opts, parent) do
    if opts[:receipt_gate] do
      send(parent, {:receipt_gate, self()})

      receive do
        :release_receipt -> :ok
      after
        5_000 -> :ok
      end
    end
  end
end
