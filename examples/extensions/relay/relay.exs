defmodule LemieuxRelayExample do
  @moduledoc """
  A one-file extension that registers a model route: an OpenAI-compatible
  server you run — vLLM, LM Studio, llama.cpp's server, LiteLLM, a proxy of
  your own — under its own provider name, `relay`, with the models you list.

  It shapes no harness: there is no `apply/2` here. What it exports is
  `routes/1` (`Lemieux.Extension.Routes`), which `lmx` calls after loading
  this directory to learn which routes it offers; `lmx` then registers each
  one, wraps it in its own `Lemieux.Providers.ReqLLM`, and sends every
  `relay:ID` request through it (`Lemieux.CLI.Routes`). The direct providers
  stay beside it, and a request on this route never falls back to one of
  them: a model is either served here or refused with a sentence.

  The options come from `extension.json` and, over them, from
  `"extension_options": {"relay": {...}}` in `~/.lmx/config.json`:

    * `"endpoint"` — the server's origin, without `/v1`;
    * `"models"` — the ids it serves, as the server names them;
    * `"default"` — the one `relay:@default` and `--router relay` start on
      (optional; without it, name a model);
    * `"context_window"` — how many tokens the server gives a model, so a
      session compacts in time (optional);
    * `"api_key_env"` — the variable holding the bearer token, `RELAY_API_KEY`
      unless named. A server that checks no key still needs the variable
      set, to anything (`RELAY_API_KEY=none`): a request with no key would
      make `req_llm` look for `OPENAI_API_KEY`, and your OpenAI key must not
      leave for a server that is not OpenAI.

  `routes/1` builds state and does no I/O. A server that could list its own
  models would ask it in `ready/1`, which `lmx` runs before the start model
  is resolved and again before the terminal UI offers the route's models.
  """

  @behaviour Lemieux.Extension.Routes

  @impl true
  @spec routes(opts :: keyword()) ::
          {:ok, [Lemieux.Extension.Routes.registration()]} | {:error, String.t()}
  def routes(opts) do
    config = Keyword.get(opts, :config, %{})

    with {:ok, endpoint} <- endpoint(config),
         {:ok, models} <- models(config),
         {:ok, default} <- default(config, models),
         {:ok, api_key} <- api_key(config) do
      route =
        LemieuxRelayExample.Route.new(
          endpoint: endpoint,
          models: models,
          default: default,
          api_key: api_key,
          context_window: config["context_window"]
        )

      {:ok, [%{name: "relay", route: {LemieuxRelayExample.Route, route}}]}
    end
  end

  defp endpoint(%{"endpoint" => endpoint}) when is_binary(endpoint) do
    case URI.new(endpoint) do
      {:ok, %URI{scheme: scheme, host: host, path: path, query: nil, userinfo: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(endpoint, "/")}

      _other ->
        {:error,
         "relay's \"endpoint\" must be an http(s) origin without /v1, such as http://localhost:8000"}
    end
  end

  defp endpoint(_config),
    do:
      {:error,
       "relay needs an \"endpoint\": set it in extension.json or in " <>
         "\"extension_options\": {\"relay\": {\"endpoint\": \"http://localhost:8000\"}}"}

  defp models(%{"models" => [_ | _] = models}) do
    if Enum.all?(models, &(is_binary(&1) and &1 != "")),
      do: {:ok, models},
      else: {:error, "relay's \"models\" must be a list of model ids"}
  end

  defp models(_config), do: {:error, "relay needs \"models\": the ids the server serves"}

  defp default(%{"default" => default}, models) when is_binary(default) do
    if default in models,
      do: {:ok, default},
      else: {:error, "relay's \"default\" (#{default}) must be one of its \"models\""}
  end

  defp default(_config, _models), do: {:ok, nil}

  defp api_key(config) do
    variable = Map.get(config, "api_key_env", "RELAY_API_KEY")

    case System.get_env(variable) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _unset ->
        {:error,
         "relay needs #{variable} in the environment: the bearer token the server expects, " <>
           "or any value (#{variable}=none) for a server that checks none"}
    end
  end
end

defmodule LemieuxRelayExample.Route do
  @moduledoc """
  The route itself: a fixed catalogue in front of one OpenAI-compatible
  server.

  Every request is encoded as an OpenAI chat completion by `req_llm` —
  pinned, so an id `req_llm` would otherwise send to the Responses API still
  goes to `/v1/chat/completions` — and sent to the configured origin with the
  configured key. Generation parameters cross from the session; the
  destination, the key and the headers never do. Prices are unknown here, so
  a session with `max_cost_usd` refuses its requests rather than counting
  them as free; bound such a session with `max_requests` or `max_turns`.
  """

  @behaviour Lemieux.Provider.Route

  alias Lemieux.ModelSpec

  defmodule Error do
    @moduledoc "A refusal on this side of a request, in a sentence."
    defexception [:reason]

    @impl Exception
    def message(%{reason: {:unknown_model, spec}}),
      do:
        "#{spec} is not a model the relay serves; its models are relay:ID for the ids configured"

    def message(%{reason: :no_default}),
      do: "the relay has no \"default\" configured: choose a model with --model relay:ID"
  end

  # The key is private state. The adapter around a route never shows its
  # state (`Lemieux.Providers.ReqLLM`'s own `Inspect` hides everything), and
  # that is what keeps it out of logs and crash reports: a script compiled by
  # the running `lmx` cannot derive `Inspect` itself, because the protocols
  # are consolidated by then. A compiled bundle can and should.
  defstruct [:endpoint, :api_key, :default, :context_window, models: []]

  @type t :: %__MODULE__{
          endpoint: String.t(),
          api_key: String.t(),
          default: String.t() | nil,
          context_window: pos_integer() | nil,
          models: [String.t()]
        }

  @spec new(attrs :: keyword()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)

  # Nothing to discover: the catalogue is configured. A server that lists
  # its models would be asked here, once, and the answer kept in the state.
  @impl true
  def ready(%__MODULE__{} = state), do: {:ok, state}

  @impl true
  def default_model(%__MODULE__{default: nil}), do: {:error, %Error{reason: :no_default}}
  def default_model(%__MODULE__{default: id}), do: {:ok, ModelSpec.join("relay", id)}

  @impl true
  def available_models(%__MODULE__{models: models}, opts) do
    if Keyword.get(opts, :provider) in [nil, "relay", :relay] and
         Keyword.get(opts, :scope) in [nil, :all, "relay", :relay],
       do: Enum.map(models, &ModelSpec.join("relay", &1)),
       else: []
  end

  @impl true
  def validate_model(%__MODULE__{models: models}, spec, _tools) do
    if ModelSpec.provider(spec) == "relay" and ModelSpec.model_id(spec) in models,
      do: :ok,
      else: {:error, %Error{reason: {:unknown_model, spec}}}
  end

  @impl true
  def context_window(%__MODULE__{context_window: window}, _spec), do: window

  @impl true
  def reasoning_efforts(_state, _spec), do: []

  @impl true
  def estimate_cost(_state, _request), do: nil

  @impl true
  def target(%__MODULE__{} = state, request, options) do
    with :ok <- validate_model(state, request.model, request.tools),
         {:ok, model} <-
           ReqLLM.model(%{
             provider: :openai,
             id: ModelSpec.model_id(request.model),
             extra: %{wire: %{protocol: "openai_chat"}}
           }) do
      # What a session may say about a request: generation and timing. The
      # destination and the credential are this route's and only this route's.
      options =
        Keyword.take(options, [
          :temperature,
          :max_tokens,
          :top_p,
          :reasoning_effort,
          :receive_timeout,
          :stream_idle_timeout,
          :total_timeout,
          :max_retries
        ])

      {:ok, {model, options ++ [base_url: state.endpoint <> "/v1", api_key: state.api_key]}}
    end
  end
end
