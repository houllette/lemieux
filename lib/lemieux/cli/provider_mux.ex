defmodule Lemieux.CLI.ProviderMux do
  @moduledoc """
  Lets the `lmx` TUI select between its configured Ixway and direct routes.

  Both connections use `Lemieux.Providers.ReqLLM`. A model's
  provider prefix selects exactly one child for every discovery, validation,
  estimate and request. In particular, an `ixway:` request that fails never
  retries through direct credentials. This belongs to the CLI host: embedded
  hosts and the line commands retain their own single-route provider policy.

  `:blocked_providers` prevents a shared environment key from advertising a
  second logical provider when the person configured only one provider section. It
  applies to validation and requests as well as menu discovery, so typing an
  unlisted model cannot quietly use the shared key through a different API.
  """

  @behaviour Lemieux.Provider

  alias Lemieux.Ixway
  alias Lemieux.ModelSpec
  alias Lemieux.Provider
  alias Lemieux.Request

  @derive {Inspect, only: []}
  defstruct [:ixway, :direct, blocked_providers: MapSet.new()]

  @type t :: %__MODULE__{
          ixway: Provider.t() | nil,
          direct: Provider.t(),
          blocked_providers: MapSet.t(String.t())
        }

  @doc "Combines the two independently configured ReqLLM connections."
  @spec new(ixway :: Provider.t() | nil, direct :: Provider.t(), opts :: keyword()) ::
          Provider.t()
  def new(ixway, direct, opts \\ []) do
    state = %__MODULE__{
      ixway: ixway,
      direct: direct,
      blocked_providers: opts |> Keyword.get(:blocked_providers, []) |> MapSet.new()
    }

    {__MODULE__, state}
  end

  @doc "Discovers and resolves an Ixway startup model; direct models need no gateway request."
  @spec prepare(provider :: Provider.t(), model :: String.t()) ::
          {:ok, Provider.t(), String.t()} | {:error, term()}
  def prepare({__MODULE__, %__MODULE__{ixway: nil}}, "ixway:" <> _),
    do: {:error, {:provider_unavailable, "ixway"}}

  def prepare({__MODULE__, %__MODULE__{ixway: ixway} = state}, "ixway:" <> _ = model) do
    with {:ok, ixway, selected} <- Ixway.prepare(ixway, model) do
      {:ok, {__MODULE__, %{state | ixway: ixway}}, selected}
    end
  end

  def prepare({__MODULE__, %__MODULE__{}} = provider, model), do: {:ok, provider, model}

  @doc "Prefetches the optional Ixway catalogue without choosing a startup model."
  @spec discover(provider :: Provider.t()) :: {:ok, Provider.t()} | {:error, term()}
  def discover({__MODULE__, %__MODULE__{ixway: nil}} = provider), do: {:ok, provider}

  def discover({__MODULE__, %__MODULE__{ixway: ixway} = state}) do
    with {:ok, ixway} <- Ixway.discover_provider(ixway) do
      {:ok, {__MODULE__, %{state | ixway: ixway}}}
    end
  end

  @impl Provider
  def run(state, %Request{} = request, emit) do
    if blocked?(state, request.model) do
      {:error, {:provider_unavailable, ModelSpec.provider(request.model)}}
    else
      state |> child(request.model) |> Provider.run(request, emit)
    end
  end

  @impl Provider
  def available_models(%__MODULE__{ixway: ixway, direct: direct} = state, opts) do
    ixway_models = if ixway, do: Provider.available_models(ixway, opts), else: []

    direct_models =
      direct
      |> Provider.available_models(opts)
      |> Enum.reject(&blocked?(state, &1))

    ixway_models ++ direct_models
  end

  @impl Provider
  def model_metadata(%__MODULE__{ixway: ixway, direct: direct}) do
    ixway_metadata = if ixway, do: Provider.model_metadata(ixway), else: %{}
    Map.merge(Provider.model_metadata(direct), ixway_metadata)
  end

  @impl Provider
  def validate_model(state, model, tools) do
    if blocked?(state, model) do
      {:error, {:provider_unavailable, ModelSpec.provider(model)}}
    else
      state |> child(model) |> Provider.validate_model(model, tools)
    end
  end

  @impl Provider
  def context_window(state, model) do
    if blocked?(state, model),
      do: nil,
      else: state |> child(model) |> Provider.context_window(model)
  end

  @impl Provider
  def reasoning_efforts(state, model) do
    if blocked?(state, model),
      do: [],
      else: state |> child(model) |> Provider.reasoning_efforts(model)
  end

  @impl Provider
  def estimate_cost(state, %Request{} = request) do
    if blocked?(state, request.model),
      do: nil,
      else: state |> child(request.model) |> Provider.estimate_cost(request)
  end

  defp blocked?(%__MODULE__{ixway: ixway, blocked_providers: blocked}, model) do
    provider = ModelSpec.provider(model)
    MapSet.member?(blocked, provider) or (provider == "ixway" and is_nil(ixway))
  end

  defp child(%__MODULE__{ixway: ixway}, "ixway:" <> _), do: ixway
  defp child(%__MODULE__{direct: direct}, model) when is_binary(model), do: direct
end
