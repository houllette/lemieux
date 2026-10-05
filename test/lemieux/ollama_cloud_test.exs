defmodule Lemieux.OllamaCloudTest do
  use ExUnit.Case, async: false

  alias Lemieux.ModelCatalog
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider

  setup do
    original = Application.get_env(:req_llm, :ollama_api_key)
    Application.put_env(:req_llm, :ollama_api_key, "ollama-cloud-key")

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:req_llm, :ollama_api_key)
        value -> Application.put_env(:req_llm, :ollama_api_key, value)
      end
    end)
  end

  test "the compatibility profile discovers and routes Ollama Cloud models" do
    options = ModelCatalog.provider_options()
    provider = ReqLLMProvider.new(options)

    assert "ollama_cloud:gpt-oss:120b" in Provider.available_models(provider,
             scope: :ollama_cloud,
             require: [chat: true, tools: true]
           )

    assert :ok = Provider.validate_model(provider, "ollama_cloud:gpt-oss:120b", [])

    assert {:ok, {"openai:gpt-oss:120b", request_options}} =
             ReqLLMProvider.request_target("ollama_cloud:gpt-oss:120b", options)

    assert request_options[:base_url] == "https://ollama.com/v1"
    assert request_options[:api_key] == "ollama-cloud-key"
  end
end
