defmodule LemieuxTest.StaticRoute do
  @moduledoc false

  # A `Lemieux.Provider.Route` with a fixed catalogue, for tests of what the
  # host does with a route that is not Ixway: registration, the mux, the
  # terminal UI's prefetch, `NAME:@default`, and dispatch to an endpoint of
  # the test's choosing. It implements the two preparation callbacks and
  # reports to `:owner` when they run, so a test can see that the host
  # readied the right route and nothing else.

  @behaviour Lemieux.Provider.Route

  alias Lemieux.ModelSpec

  @derive {Inspect, only: [:name, :models]}
  defstruct name: "relay",
            models: [],
            default: nil,
            endpoint: nil,
            api_key: "static-key",
            window: nil,
            efforts: [],
            owner: nil,
            ready: :ok,
            readied: 0

  def new(attrs \\ []), do: struct!(__MODULE__, attrs)

  @impl true
  def ready(%__MODULE__{ready: {:error, reason}}), do: {:error, reason}

  def ready(%__MODULE__{} = state) do
    notify(state, {:route_ready, state.name})
    {:ok, %{state | readied: state.readied + 1}}
  end

  @impl true
  def default_model(%__MODULE__{default: nil, name: name}), do: {:error, {:no_default, name}}
  def default_model(%__MODULE__{default: model}), do: {:ok, model}

  @impl true
  def available_models(%__MODULE__{name: name, models: models}, opts) do
    asked = Keyword.get(opts, :provider)

    if is_nil(asked) or to_string(asked) == name,
      do: Enum.map(models, &ModelSpec.join(name, &1)),
      else: []
  end

  @impl true
  def model_metadata(%__MODULE__{name: name, models: models}),
    do: Map.new(models, &{ModelSpec.join(name, &1), %{kind: "static"}})

  @impl true
  def validate_model(%__MODULE__{} = state, spec, _tools) do
    if spec in available_models(state, []),
      do: :ok,
      else: {:error, {:unknown_model, spec}}
  end

  @impl true
  def context_window(%__MODULE__{window: window}, _spec), do: window

  @impl true
  def reasoning_efforts(%__MODULE__{efforts: efforts}, _spec), do: efforts

  @impl true
  def estimate_cost(_state, _request), do: nil

  @impl true
  def target(%__MODULE__{endpoint: nil}, _request, _options), do: {:error, :no_endpoint}

  def target(%__MODULE__{} = state, request, options) do
    with :ok <- validate_model(state, request.model, request.tools),
         {:ok, model} <-
           ReqLLM.model(%{
             provider: :openai,
             id: ModelSpec.model_id(request.model),
             extra: %{wire: %{protocol: "openai_chat"}}
           }) do
      notify(state, {:route_target, request.model})

      {:ok,
       {model,
        Keyword.take(options, [:temperature, :max_tokens, :receive_timeout, :stream_idle_timeout]) ++
          [base_url: state.endpoint <> "/v1", api_key: state.api_key]}}
    end
  end

  defp notify(%__MODULE__{owner: owner}, message) when is_pid(owner), do: send(owner, message)
  defp notify(_state, _message), do: :ok
end
