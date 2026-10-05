defmodule Lemieux.ModelSpec do
  @moduledoc """
  The two parts of a `req_llm` model specification.

  A specification has one separator between its provider and model id, but a
  model id may contain more colons of its own. Ollama tags are the ordinary
  example: `ollama:qwen3.8:27b` means provider `ollama`, model id
  `qwen3.8:27b`. Splitting every colon makes provider-scoped model selection
  silently produce the wrong id, so every caller goes through this module and
  splits once.
  """

  @type provider :: String.t()
  @type model_id :: String.t()

  @doc "Returns the provider and model id, or `:error` for an incomplete specification."
  @spec split(spec :: String.t()) :: {:ok, {provider(), model_id()}} | :error
  def split(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider, model_id] when provider != "" and model_id != "" ->
        {:ok, {provider, model_id}}

      _invalid ->
        :error
    end
  end

  @doc "Returns the provider portion of a specification, or `nil`."
  @spec provider(spec :: String.t() | nil) :: provider() | nil
  def provider(spec) when is_binary(spec) do
    case split(spec) do
      {:ok, {provider, _model_id}} -> provider
      :error -> nil
    end
  end

  def provider(nil), do: nil

  @doc "Returns the model-id portion of a specification, or `nil`."
  @spec model_id(spec :: String.t() | nil) :: model_id() | nil
  def model_id(spec) when is_binary(spec) do
    case split(spec) do
      {:ok, {_provider, model_id}} -> model_id
      :error -> nil
    end
  end

  def model_id(nil), do: nil

  @doc "Joins a provider and model id without interpreting colons inside the id."
  @spec join(provider :: provider(), model_id :: model_id()) :: String.t()
  def join(provider, model_id)
      when is_binary(provider) and provider != "" and is_binary(model_id) and model_id != "" do
    provider <> ":" <> model_id
  end
end
