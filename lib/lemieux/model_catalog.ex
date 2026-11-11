defmodule Lemieux.ModelCatalog do
  @moduledoc """
  Verified compatibility additions that lag ReqLLM's bundled model catalog.

  A model can reach a provider before `llm_db` knows about it, and a catalog
  provider can temporarily need a different compatible wire transport. Keeping
  those facts together matters: advertising a model without the route that
  makes its requests valid would put an unusable choice in a host's picker.

  Hosts opt into `provider_options/0` when constructing
  `Lemieux.Providers.ReqLLM`. The standalone CLI does; other embedding hosts
  can use the same public, canary-tested profile without copying it. These are
  compatibility facts, not credentials, pricing, limits, or a claim that the
  provider is configured. Credential-aware discovery still decides which
  providers and fallbacks are advertised.
  """

  alias Lemieux.Providers.ReqLLM, as: Adapter

  @fallbacks []

  @mtplx_url "http://127.0.0.1:8000/v1"

  @transport_routes %{
    "mtplx" => [
      model_provider: :mtplx,
      provider: "openai",
      base_url: @mtplx_url,
      wire_protocol: "openai_chat",
      # ReqLLM requires a bearer value even on a keyless OpenAI-compatible server.
      default_api_key: "mtplx"
    ],
    # llm_db publishes Ollama Cloud's models and metadata before ReqLLM has a provider
    # module for them. The service exposes an OpenAI-compatible `/v1` surface while
    # its documented credential remains `OLLAMA_API_KEY`. Keeping `ollama_cloud`
    # logical preserves its catalog identity and keeps local, unauthenticated `ollama`
    # models available in the same session.
    "ollama_cloud" => [
      provider: "openai",
      base_url: "https://ollama.com/v1",
      credential_provider: "ollama"
    ]
  }

  @doc "Returns model specifications verified but absent from the bundled catalog."
  @spec fallbacks() :: [String.t()]
  def fallbacks, do: @fallbacks

  @doc "Returns the default MTPLX OpenAI-compatible API URL."
  @spec mtplx_url() :: String.t()
  def mtplx_url, do: @mtplx_url

  @doc "Resolves catalog models and IDs advertised by MTPLX."
  @spec resolve(String.t()) :: {:ok, LLMDB.Model.t()} | {:error, term()}
  def resolve(spec), do: Adapter.resolve_model(spec, provider_options())

  @doc "Returns the complete ReqLLM options required by the verified additions."
  @spec provider_options() :: keyword()
  def provider_options do
    [transport_routes: @transport_routes, catalog_fallbacks: @fallbacks]
  end
end
