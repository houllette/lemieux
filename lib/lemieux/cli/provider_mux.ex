defmodule Lemieux.CLI.ProviderMux do
  @moduledoc """
  Lets `lmx` run its registered model routes beside its direct connection.

  Every connection is a `Lemieux.Providers.ReqLLM`. A model's provider prefix
  selects exactly one child for every discovery, validation, estimate and
  request: `ixway:team/coding` goes to the route registered as `ixway`,
  `relay:qwen3-32b` to the one registered as `relay`, and anything else to
  the direct connection. In particular a request on a route that fails never
  retries through direct credentials, and no route answers for another's
  models: a route's catalogue is read under its own name only, so a route
  that listed `openai:gpt-5` could not make that specification mean two
  destinations. This belongs to the CLI host — embedded hosts keep their own
  single-route provider policy — and `Lemieux.CLI.Routes` says which routes
  one invocation registers.

  It held exactly one route, Ixway, by module name, and only the terminal
  UI used it; `lmx run` built a sole-route provider or a direct one. Now any
  registered route goes in the same list, both hosts use it whenever a
  route is registered, and a route's preparation (`prepare/2`, `ready/2`)
  runs through `Lemieux.Providers.ReqLLM.prepare/2` rather than through a
  gateway's module, which is what lets a route an extension registered be
  prefetched, resolved and resumed exactly as Ixway is.

  `:blocked_providers` prevents a shared environment key from advertising a
  second logical provider when the person configured only one provider
  section. It applies to validation and requests as well as menu discovery,
  so typing an unlisted model cannot quietly use the shared key through a
  different API.
  """

  @behaviour Lemieux.Provider

  alias Lemieux.ModelSpec
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Request

  @derive {Inspect, only: []}
  defstruct routes: [], direct: nil, blocked_providers: MapSet.new()

  @typedoc "A registered route: the name its models carry, and the routed connection."
  @type route :: {name :: String.t(), Provider.t()}

  @type t :: %__MODULE__{
          routes: [route()],
          direct: Provider.t(),
          blocked_providers: MapSet.t(String.t())
        }

  # The one route name a person can type into a session that holds no such
  # route — the shipped gateway's, which the documentation names — is
  # answered as a provider that is not available here, rather than handed
  # to the direct connection to say it has never heard of the provider.
  @reserved ["ixway"]

  @doc "Combines the registered routes, in order, with the direct connection."
  @spec new(routes :: [route()], direct :: Provider.t(), opts :: keyword()) :: Provider.t()
  def new(routes, direct, opts \\ []) when is_list(routes) and is_list(opts) do
    state = %__MODULE__{
      routes: routes,
      direct: direct,
      blocked_providers: opts |> Keyword.get(:blocked_providers, []) |> MapSet.new()
    }

    {__MODULE__, state}
  end

  @doc "The names of the routes this provider holds, in registration order."
  @spec route_names(provider :: Provider.t()) :: [String.t()]
  def route_names({__MODULE__, %__MODULE__{routes: routes}}), do: Enum.map(routes, &elem(&1, 0))

  @doc """
  Readies the route a startup model names and resolves the model on it
  (`Lemieux.Providers.ReqLLM.prepare/2`); a direct model needs no
  preparation, and a blocked or absent provider is refused as unavailable.
  """
  @spec prepare(provider :: Provider.t(), model :: String.t()) ::
          {:ok, Provider.t(), String.t()} | {:error, term()}
  def prepare({__MODULE__, %__MODULE__{} = state} = provider, model) when is_binary(model) do
    name = ModelSpec.provider(model)

    cond do
      blocked?(state, model) ->
        {:error, {:provider_unavailable, name}}

      route = List.keyfind(state.routes, name, 0) ->
        {^name, child} = route

        with {:ok, child, model} <- Adapter.prepare(child, model),
             do: {:ok, {__MODULE__, put_route(state, name, child)}, model}

      true ->
        {:ok, provider, model}
    end
  end

  @doc """
  Readies the route named `name` without choosing a model, so its discovery
  is under way before the start model is resolved; a name with no route
  here is left alone.
  """
  @spec ready(provider :: Provider.t(), name :: String.t() | nil) ::
          {:ok, Provider.t()} | {:error, term()}
  def ready({__MODULE__, %__MODULE__{} = state} = provider, name) do
    case List.keyfind(state.routes, name, 0) do
      {^name, child} ->
        with {:ok, child} <- Adapter.ready(child),
             do: {:ok, {__MODULE__, put_route(state, name, child)}}

      nil ->
        {:ok, provider}
    end
  end

  @doc "Readies every registered route, in order, stopping at the first that cannot be."
  @spec discover(provider :: Provider.t()) :: {:ok, Provider.t()} | {:error, term()}
  def discover({__MODULE__, %__MODULE__{routes: routes}} = provider) do
    Enum.reduce_while(routes, {:ok, provider}, fn {name, _child}, {:ok, provider} ->
      case ready(provider, name) do
        {:ok, provider} -> {:cont, {:ok, provider}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "The connection a request for `model` is sent to: its route, else the direct one."
  @spec child(provider :: Provider.t(), model :: String.t()) :: Provider.t()
  def child({__MODULE__, %__MODULE__{} = state}, model) when is_binary(model),
    do: connection(state, model)

  @impl Provider
  def run(state, %Request{} = request, emit) do
    if blocked?(state, request.model) do
      {:error, {:provider_unavailable, ModelSpec.provider(request.model)}}
    else
      state |> connection(request.model) |> Provider.run(request, emit)
    end
  end

  # Each route is asked only when the question is about it or about every
  # provider, and answers only for models under its own name. The direct
  # connection is not asked about a route's name at all.
  @impl Provider
  def available_models(%__MODULE__{routes: routes, direct: direct} = state, opts) do
    asked = asked_provider(opts)

    route_models =
      Enum.flat_map(routes, fn {name, child} ->
        if asked in [nil, name],
          do: child |> Provider.available_models(opts) |> Enum.filter(&own?(&1, name)),
          else: []
      end)

    direct_models =
      if is_nil(asked) or not route?(state, asked),
        do: direct |> Provider.available_models(opts) |> Enum.reject(&blocked?(state, &1)),
        else: []

    route_models ++ direct_models
  end

  @impl Provider
  def model_metadata(%__MODULE__{routes: routes, direct: direct}) do
    Enum.reduce(routes, Provider.model_metadata(direct), fn {_name, child}, metadata ->
      Map.merge(metadata, Provider.model_metadata(child))
    end)
  end

  @impl Provider
  def validate_model(state, model, tools) do
    if blocked?(state, model) do
      {:error, {:provider_unavailable, ModelSpec.provider(model)}}
    else
      state |> connection(model) |> Provider.validate_model(model, tools)
    end
  end

  @impl Provider
  def context_window(state, model) do
    if blocked?(state, model),
      do: nil,
      else: state |> connection(model) |> Provider.context_window(model)
  end

  @impl Provider
  def reasoning_efforts(state, model) do
    if blocked?(state, model),
      do: [],
      else: state |> connection(model) |> Provider.reasoning_efforts(model)
  end

  @impl Provider
  def estimate_cost(state, %Request{} = request) do
    if blocked?(state, request.model),
      do: nil,
      else: state |> connection(request.model) |> Provider.estimate_cost(request)
  end

  @impl Provider
  def input_modalities(state, model) do
    if blocked?(state, model),
      do: :unknown,
      else: state |> connection(model) |> Provider.input_modalities(model)
  end

  defp asked_provider(opts) do
    case Keyword.get(opts, :provider) do
      nil -> nil
      provider -> to_string(provider)
    end
  end

  defp own?(spec, name), do: ModelSpec.provider(spec) == name

  defp route?(%__MODULE__{routes: routes}, name), do: List.keymember?(routes, name, 0)

  defp blocked?(%__MODULE__{blocked_providers: blocked} = state, model) do
    provider = ModelSpec.provider(model)
    MapSet.member?(blocked, provider) or (provider in @reserved and not route?(state, provider))
  end

  defp connection(%__MODULE__{routes: routes, direct: direct}, model) when is_binary(model) do
    case List.keyfind(routes, ModelSpec.provider(model), 0) do
      {_name, child} -> child
      nil -> direct
    end
  end

  defp put_route(%__MODULE__{routes: routes} = state, name, child),
    do: %{state | routes: List.keyreplace(routes, name, 0, {name, child})}
end
