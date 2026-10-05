defmodule Lemieux.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Lemieux.ModelCatalog
  alias Lemieux.ModelSpec

  test "every fallback remains absent from ReqLLM's bundled catalog" do
    fallbacks = ModelCatalog.fallbacks()
    assert fallbacks == []
    assert fallbacks == Enum.uniq(fallbacks), "catalog fallbacks must be unique"

    Enum.each(fallbacks, fn spec ->
      provider = spec |> ModelSpec.provider() |> String.to_existing_atom()
      discovered = ReqLLM.available_models(api_key: "catalog-canary", scope: provider)

      refute spec in discovered,
             "#{spec} is now supplied by llm_db; remove its catalog fallback"
    end)
  end

  test "ReqLLM's dedicated Z.AI encoder preserves tool-result association" do
    context =
      ReqLLM.Context.new([
        ReqLLM.Context.user("Read secret.txt"),
        ReqLLM.Context.assistant([],
          tool_calls: [
            {"read_file", %{"path" => "secret.txt"}, [id: "call_123"]}
          ]
        ),
        ReqLLM.Context.tool_result("call_123", "read_file", "marmalade")
      ])

    {:ok, model} = ReqLLM.model("zai_coding_plan:glm-5.3")
    {:ok, provider} = ReqLLM.provider(model.provider)
    {:ok, request} = provider.prepare_request(:chat, model, context, api_key: "not-used")

    message =
      request
      |> provider.encode_body()
      |> Map.fetch!(:body)
      |> Jason.decode!()
      |> Map.fetch!("messages")
      |> List.last()

    assert message["role"] == "tool"
    assert message["content"] == "marmalade"
    assert message["tool_call_id"] == "call_123"
    assert message["name"] == "read_file"
  end

  test "the compatibility profile keeps every required transport route" do
    options = ModelCatalog.provider_options()

    assert options[:catalog_fallbacks] == ModelCatalog.fallbacks()

    refute Map.has_key?(options[:transport_routes], "zai_coding_plan")

    assert options[:transport_routes]["ollama_cloud"] == [
             provider: "openai",
             base_url: "https://ollama.com/v1",
             credential_provider: "ollama"
           ]
  end
end
