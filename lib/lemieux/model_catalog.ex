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

  @fallbacks []

  @transport_routes %{
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

  @doc "Returns the complete ReqLLM options required by the verified additions."
  @spec provider_options() :: keyword()
  def provider_options do
    [transport_routes: @transport_routes, catalog_fallbacks: @fallbacks]
  end
end
