defmodule Lemieux.Providers.ReqLLMCodexObjectTest do
  use ExUnit.Case, async: true

  alias Lemieux.{Entry, Provider, Request}
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias LemieuxTest.HTTPFixture

  @schema %{
    "type" => "object",
    "properties" => %{"ok" => %{"type" => "boolean"}},
    "required" => ["ok"],
    "additionalProperties" => false
  }

  test "Codex streams native structured output with the prepared schema and request context" do
    for schema <- [@schema, [ok: [type: :boolean, required: true]]] do
      owner = self()
      request = request(schema, reasoning_effort: "high", output_validation: :strict)

      assert :ok = Provider.run(provider(~s({"ok":true})), request, &send(owner, {:event, &1}))
      assert_receive {:wire, "/codex/responses", headers, body}
      assert headers["authorization"] == "Bearer fixture-token"
      assert headers["chatgpt-account-id"] == "fixture-account"
      assert body["model"] == "gpt-6.1-sol"
      assert body["reasoning"]["effort"] == "high"
      assert body["stream"] == true
      assert body["text"]["format"]["type"] == "json_schema"
      assert body["text"]["format"]["schema"] == @schema
      assert body["text"]["format"]["strict"] == true
      assert inspect(body["input"]) =~ "Return an object with ok=true."
      refute Map.has_key?(body, "openai_codex_model")
      assert_receive {:event, {:message, message}}
      assert [%{"text" => text}] = message["content"]
      assert JSON.decode!(text) == %{"ok" => true}
      assert_receive {:event, {:usage, %{"input_tokens" => 10, "output_tokens" => 5}}}
      assert_receive {:event, {:done, :stop}}
    end
  end

  test "strict validation still rejects malformed JSON and objects outside the exact schema" do
    for text <- ["{broken", ~s({"ok":"yes"}), ~s({"other":true})] do
      owner = self()

      assert {:error, _reason} =
               Provider.run(
                 provider(text),
                 request(@schema, output_validation: :strict),
                 &send(owner, {:event, &1})
               )

      assert_receive {:wire, _, _, _}
      refute_receive {:event, {:done, _}}
      refute_receive {:event, {:message, _}}
    end
  end

  test "invalid caller options still fail before the HTTP request" do
    assert {:error, reason} =
             Provider.run(
               provider(~s({"ok":true})),
               request(@schema, invented_option: true),
               fn _ ->
                 :ok
               end
             )

    assert inspect(reason) =~ "invented_option"
    refute_receive {:wire, _, _, _}
  end

  defp request(schema, params) do
    Request.new("openai_codex:gpt-6.1-sol",
      entries: [Entry.new(:user, %{"text" => "Return an object with ok=true."})],
      output_schema: schema,
      params: params
    )
  end

  defp provider(text) do
    owner = self()

    events = [
      %{"type" => "response.output_text.delta", "delta" => text},
      %{
        "type" => "response.completed",
        "response" => %{
          "id" => "fixture-response",
          "output" => [],
          "usage" => %{"input_tokens" => 10, "output_tokens" => 5, "total_tokens" => 15}
        }
      }
    ]

    body = Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\n\n"))

    {url, listener, server} =
      HTTPFixture.server(fn path, headers, request_body, _socket ->
        send(owner, {:wire, path, headers, JSON.decode!(request_body)})
        %{status: 200, headers: [{"content-type", "text/event-stream"}], body: body}
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    Adapter.new(
      api_key: "fixture-key",
      api_key_provider: :openai_codex,
      access_token: "fixture-token",
      chatgpt_account_id: "fixture-account",
      base_url: url,
      max_retries: 0
    )
  end
end
