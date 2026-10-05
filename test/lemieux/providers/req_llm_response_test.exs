defmodule Lemieux.Providers.ReqLLMResponseTest do
  use ExUnit.Case, async: true

  alias Lemieux.{Entry, Provider, Request, Session, Store}
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  @moduletag :tmp_dir

  test "a pinned chat route extracts structured output and reports selected response metadata" do
    owner = self()

    provider = provider(200, success_body(), owner)

    request =
      Request.new("openai:gpt-5",
        entries: [Entry.new(:user, %{"text" => "Extract the label"})],
        context: %{request_id: "attempt-1"},
        params: [
          output_validation: :strict,
          transport_routes: %{"openai" => [provider: "openai", wire_protocol: "typo"]},
          response_metadata: [headers: ["set-cookie"]]
        ],
        output_schema: [label: [type: :string, required: true]]
      )

    assert :ok = Provider.run(provider, request, &send(owner, {:event, &1}))
    assert_receive {:path, "/chat/completions"}
    assert_receive {:wire, headers, body}
    assert headers["authorization"] == "Bearer fixture-key"
    assert body["model"] == "gpt-5"
    assert body["stream"] == true
    assert body["response_format"]["type"] == "json_schema"
    refute Map.has_key?(body, "input")

    assert_receive {:event, {:response_metadata, metadata}}
    assert metadata.status == 200
    assert metadata.request_id == "attempt-1"
    assert metadata.requested_model == "openai:gpt-5"
    assert metadata.resolved_model == "served-model"
    assert metadata.headers == %{"x-ixway-request-id" => ["gateway-1"]}
    assert_receive {:event, {:message, message}}
    assert [%{"text" => text}] = message["content"]
    assert JSON.decode!(text) == %{"label" => "test"}
    assert_receive {:event, {:done, :stop}}
    refute_receive {:event, {:response_metadata, _}}
  end

  for status <- [429, 503] do
    @status status
    test "HTTP #{status} retains typed errors and response metadata in a session", context do
      owner = self()
      provider = provider(@status, ~s({"error":{"message":"fixture failure"}}), owner)
      runtime = :"response_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      store = Store.JSONL.new(context.tmp_dir)

      {:ok, session} =
        Lemieux.start_session(
          supervisor: runtime,
          provider: provider,
          store: store,
          model: "openai:gpt-5",
          tools: [],
          subscriber: self(),
          max_requests: 1
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "extract")
      assert_receive {:lemieux, ^id, {:response_metadata, metadata}}
      assert metadata.status == @status
      assert metadata.resolved_model == "served-model"
      assert metadata.headers == %{"x-ixway-request-id" => ["gateway-1"]}
      assert_receive {:lemieux, ^id, {:error, reason}}
      assert ProviderError.http_status(reason) == @status
      assert ProviderError.retry_after_ms(reason) == 17_000
      assert_receive {:lemieux, ^id, {:finished, :error}}
      refute_receive {:lemieux, ^id, {:provider_retry, _}}

      {:ok, entries} = Store.read(store, id)
      [request] = Enum.filter(entries, &(&1.type == :request))
      assert metadata.request_id == request.payload["id"]
      refute JSON.encode!(Enum.map(entries, & &1.payload)) =~ "gateway-1"
      refute JSON.encode!(Enum.map(entries, & &1.payload)) =~ "private-cookie"
    end
  end

  test "an invalid explicit wire protocol fails without silently falling back" do
    assert {:error, {:invalid_transport_route, "openai:gpt-5"}} =
             Adapter.request_target("openai:gpt-5",
               api_key: "fixture-key",
               transport_routes: %{"openai" => [provider: "openai", wire_protocol: "typo"]}
             )
  end

  test "metadata defaults disclose no headers or guessed resolved model" do
    owner = self()
    provider = provider(200, success_body(), owner, response_metadata: [])
    request = Request.new("openai:gpt-5", entries: [Entry.new(:user, %{"text" => "hello"})])

    assert :ok = Provider.run(provider, request, &send(owner, {:event, &1}))
    assert_receive {:event, {:response_metadata, metadata}}
    assert metadata.status == 200
    assert metadata.headers == %{}
    assert metadata.resolved_model == nil
    assert metadata.request_id == nil
  end

  test "Ixway-style json_object extraction stays on the pinned chat protocol" do
    owner = self()
    provider = provider(200, success_body(), owner)

    request =
      Request.new("openai:gpt-5",
        entries: [Entry.new(:user, %{"text" => "Return the label as JSON"})],
        params: [response_format: %{type: "json_object"}]
      )

    assert :ok = Provider.run(provider, request, &send(owner, {:event, &1}))
    assert_receive {:path, "/chat/completions"}
    assert_receive {:wire, _headers, body}
    assert body["response_format"] == %{"type" => "json_object"}
    refute Map.has_key?(body, "tools")
    assert_receive {:event, {:message, message}}
    assert [%{"text" => text}] = message["content"]
    assert JSON.decode!(text) == %{"label" => "test"}
    assert_receive {:event, {:done, :stop}}
  end

  test "structured tool output becomes JSON content without invoking a harness tool" do
    owner = self()
    body = structured_tool_body(~s({"label":"test"}))
    request = Request.new("openai:gpt-5", output_schema: [label: [type: :string, required: true]])
    assert :ok = Provider.run(provider(200, body, owner), request, &send(owner, {:event, &1}))
    assert_receive {:event, {:message, %{"content" => [%{"text" => text}]}}}
    assert JSON.decode!(text) == %{"label" => "test"}
    assert_receive {:event, {:text_delta, ^text}}
    assert_receive {:event, {:done, :stop}}
    refute_receive {:event, {:tool_call, _}}
  end

  test "structured tool output is still a real tool in an ordinary text request" do
    owner = self()
    request = Request.new("openai:gpt-5")

    assert :ok =
             Provider.run(
               provider(200, structured_tool_body(~s({"label":"test"})), owner),
               request,
               &send(owner, {:event, &1})
             )

    assert_receive {:event, {:tool_call, %{name: "structured_output"}}}
    assert_receive {:event, {:done, :tool_calls}}
  end

  test "invalid structured tool output fails its schema without running a tool" do
    owner = self()
    request = Request.new("openai:gpt-5", output_schema: [label: [type: :string, required: true]])

    assert {:error, _} =
             Provider.run(
               provider(200, structured_tool_body(~s({"label":42})), owner),
               request,
               &send(owner, {:event, &1})
             )

    refute_receive {:event, {:done, _}}
    refute_receive {:event, {:tool_call, _}}
  end

  test "strict validation rejects invalid output while retaining response metadata" do
    owner = self()
    provider = provider(200, success_body("[]"), owner)

    request =
      Request.new("openai:gpt-5",
        entries: [Entry.new(:user, %{"text" => "Extract"})],
        params: [output_validation: :strict],
        output_schema: [label: [type: :string, required: true]]
      )

    assert {:error, _reason} = Provider.run(provider, request, &send(owner, {:event, &1}))
    assert_receive {:event, {:response_metadata, %{status: 200}}}
    refute_receive {:event, {:done, _}}
  end

  test "concurrent requests retain their own gateway and Lemieux identities" do
    owner = self()

    providers =
      for id <- ["first", "second"],
          do: {id, provider(200, success_body(), owner, fixture_response_id: id)}

    tasks =
      Enum.map(providers, fn {id, provider} ->
        Task.async(fn ->
          request =
            Request.new("openai:gpt-5",
              entries: [Entry.new(:user, %{"text" => id})],
              context: %{request_id: id}
            )

          Provider.run(provider, request, &send(owner, {id, &1}))
        end)
      end)

    for task <- tasks, do: assert(Task.await(task) == :ok)

    for id <- ["first", "second"] do
      assert_receive {^id, {:response_metadata, metadata}}
      assert metadata.request_id == id
      assert metadata.headers == %{"x-ixway-request-id" => [id]}
      refute_receive {^id, {:response_metadata, _}}
    end
  end

  defp provider(status, body, owner, overrides \\ []) do
    {response_id, overrides} = Keyword.pop(overrides, :fixture_response_id, "gateway-1")

    {url, listener, server} =
      HTTPFixture.server(fn path, headers, request_body, socket ->
        send(owner, {:path, path})
        send(owner, {:wire, headers, JSON.decode!(request_body)})

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} OK\r\n",
            "content-type: #{if status == 200, do: "text/event-stream", else: "application/json"}\r\n",
            "content-length: #{byte_size(body)}\r\n",
            "x-ixway-request-id: #{response_id}\r\nx-ixway-resolved-model: served-model\r\nset-cookie: private-cookie\r\n",
            "retry-after: 17\r\nconnection: close\r\n\r\n",
            body
          ])

        :sent
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    options = [
      api_key: "fixture-key",
      api_key_provider: :openai,
      max_retries: 0,
      response_metadata: [headers: ["x-ixway-request-id"], model_header: "x-ixway-resolved-model"],
      transport_routes: %{
        "openai" => [provider: "openai", base_url: url, wire_protocol: "openai_chat"]
      }
    ]

    Adapter.new(Keyword.merge(options, overrides))
  end

  defp success_body(text \\ ~s({"label":"test"})) do
    chunks = [
      %{model: "served-model", choices: [%{index: 0, delta: %{content: text}}]},
      %{
        model: "served-model",
        choices: [%{index: 0, delta: %{}, finish_reason: "stop"}],
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      }
    ]

    Enum.map_join(chunks, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <>
      "data: [DONE]\n\n"
  end

  defp structured_tool_body(arguments) do
    chunks = [
      %{
        model: "served-model",
        choices: [
          %{
            index: 0,
            delta: %{
              tool_calls: [
                %{
                  index: 0,
                  id: "structured-1",
                  type: "function",
                  function: %{name: "structured_output", arguments: arguments}
                }
              ]
            }
          }
        ]
      },
      %{
        model: "served-model",
        choices: [%{index: 0, delta: %{}, finish_reason: "tool_calls"}],
        usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
      }
    ]

    Enum.map_join(chunks, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <> "data: [DONE]\n\n"
  end
end
