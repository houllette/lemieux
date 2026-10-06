defmodule Lemieux.Providers.ReqLLM do
  @moduledoc """
  The `Lemieux.Provider` that actually talks to a model, through `req_llm`.

  This is the only implementation in the library that sends model requests,
  and it is deliberately thin: translate a `Lemieux.Request` into a
  `ReqLLM.Context`, stream it, translate the events back. Everything
  provider-shaped — authentication, retries, SSE framing, the differences
  between Anthropic's and OpenAI's wire formats — is `req_llm`'s problem, and
  the reason this module stays small is that keeping it that way is the whole
  point of depending on `req_llm` at all.

  ## Provider encoding stays in req_llm

  The model is a `req_llm` specification string, and every provider that
  library supports works through this module unchanged. Development targets
  Anthropic because that is what the first host bills against, but request
  encoding and transport remain that dependency's responsibility.

  Deterministic provider rejection rules are still preflighted here when
  `req_llm` does not expose them as capabilities. Anthropic, for example,
  rejects top-level schema combinators on custom tools. Letting that reach the
  network spends a request only to get a `400` whose tool index hides the
  offending dynamic or MCP tool; the local check names it instead. It does not
  rewrite the schema, so providers that accept the full JSON Schema continue
  to receive it unchanged.

  ## The key is checked before the request is built

  A missing key is by far the most common way a first run fails, and it is
  not worth a network round trip to discover. `run/3` resolves it up front and
  returns `{:error, {:missing_api_key, provider, hint}}`, which a host can put
  in front of a person as a sentence about their environment rather than an
  HTTP 401.

  ## Gateways use the API base URL

  A host routes every model request through an API-compatible gateway with
  `new(base_url: url)`. `req_llm` still chooses the provider wire protocol and
  appends that provider's endpoint path, so this is a provider API base rather
  than an HTTP CONNECT forward proxy. It is provider state, not session
  configuration: transcripts never retain deployment URLs or credentials
  embedded in them, and a resumed session uses the provider its host supplies
  now.

  ## A route replaces the catalog and the destination

  `new(route: {module, state})` hands discovery, selection, validation, the
  wire target, the context window and the reasoning-effort menu to a
  `Lemieux.Provider.Route`; this adapter still owns every inference request
  through ReqLLM. A routed adapter accepts only what its route advertises and
  cannot fall back to direct-provider credentials or URLs, which is why
  `:route` refuses to combine with them. The shipped route is a gateway this
  module does not name — it builds the pair itself, so that the adapter can
  never again be in a compile cycle with one destination. The route's state
  is private host state, like a key.

  ## API-compatible transports stay host policy

  Some services expose a model catalog and credential under their own
  `req_llm` provider while accepting requests through another provider's wire
  protocol. A host can describe that deployment with `:transport_routes`.
  Lemieux still validates, accounts for and records the logical model; only
  the model specification used for the HTTP request changes. A route may name
  a `:credential_provider` when the logical provider deliberately shares an
  established `req_llm` credential identity. This keeps an endpoint and its
  credential scoped to that provider when an interactive session later
  switches models.

  ## Reasoning effort crosses one type boundary

  Lemieux keeps reasoning efforts as strings because they are user-facing,
  persisted in transcripts and restored across releases. `req_llm` validates
  the request option against canonical atoms. Normalize at this adapter's
  request boundary: converting earlier would put atoms into the durable
  session contract, while forwarding the string makes providers such as Z.AI
  reject the request before any HTTP call is made.

  ## Provider-scoped credentials

  An interactive session may switch providers, so a scalar `:api_key` is not
  enough information: ReqLLM treats it as the key for whichever provider is
  being asked, which can make every catalog provider look configured and can
  send the key to the wrong service after a model change. Multi-provider hosts
  pass `api_keys: %{provider => key}` instead. Discovery and requests then use
  only the key belonging to the logical provider.

  A legacy scalar key remains supported for fixed-provider embedders. Pair it
  with `api_key_provider: :anthropic` when model changes are possible; a
  provider mismatch is rejected before a request. Unscoped scalar keys no
  longer widen all-provider discovery, although a caller may still make an
  explicitly scoped catalog query while migrating.

  ## A model on the person's own machine

  Three things are different about `ollama:` models, the ones an Ollama
  daemon the person runs serves. None of them applies to a request a host
  routes elsewhere (`:route`, or a `:transport_routes` entry for `ollama`).

  **Its answer has no end of its own.** `req_llm` asks for a model's
  published output limit when a request sets none, and a hosted API stops an
  answer at its model's own maximum. A local model has neither: Ollama
  generates until the model stops, and shifts its window rather than stop
  when the answer fills it. A model that fell into repeating itself wrote
  the same sentence 305 times over fifteen minutes before anybody stopped
  it — the stream-idle limit never fires while tokens flow, and turn and
  request limits count requests, not tokens. So a local request carries
  `max_tokens: 16_384` (`:local_max_tokens`) unless the request, the host or
  the catalog set a limit: room for a long file written in one call, with
  thinking first. That is a bound, not a cure: at the 18 tokens a second
  that model managed, 16,384 tokens still take about fifteen minutes. Until
  then the only bound was a person stopping it.

  Other models without a published limit get no default here, because their
  servers already bound an answer and some refuse a larger bound outright.
  vLLM refuses a request whose prompt plus `max_tokens` exceeds its window,
  so with 16,384 reserved a 16k-window server would refuse every request.
  OpenAI refuses `max_tokens` from its reasoning models, and an uncatalogued
  model's name is all `req_llm` has to tell one by.

  **The first token can be minutes away.** Ollama sends nothing while it
  reads a prompt, and a cold 27B model took 324 seconds over a 32,000-token
  one. A silence that long means a stalled stream from a hosted API and a
  model still reading from a local one, so a local request's transport and
  stream-idle limits are raised to at least `:local_idle_timeout`
  (15 minutes) and never lowered. `req_llm` keeps one stream-idle timer for
  the whole answer, which is why the option is not called a first-token
  timeout: the gap allowed between later tokens is that long too. A local
  daemon that fails mid-answer closes the stream rather than going quiet,
  which ends it at once. It is still a check on progress, not a clock on
  the whole answer: an answer that keeps arriving is never cut.

  **Its window is the daemon's, and nobody publishes it.** Ollama sizes the
  window when it loads a model and drops what does not fit without an error,
  so `context_window/2` asks the daemon (`Lemieux.Providers.OllamaWindow`)
  rather than the catalog, and every answer is followed by a
  `{:context_window, tokens}` event saying what the daemon served it with.
  `ollama_window: false` turns both lookups off.
  """

  @behaviour Lemieux.Provider

  alias Lemieux.Entry
  alias Lemieux.ModelSpec
  alias Lemieux.OpenTelemetry
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Provider.Interrupted
  alias Lemieux.Provider.Route
  alias Lemieux.Providers.OllamaWindow
  alias Lemieux.Providers.ReqLLM.ResponseMetadata
  alias Lemieux.Request
  alias Lemieux.Tool
  alias Lemieux.Usage
  alias ReqLLM.Context
  alias ReqLLM.Message
  alias ReqLLM.Message.ContentPart
  alias ReqLLM.Message.ReasoningDetails
  alias ReqLLM.Provider.Options, as: ProviderOptions
  alias ReqLLM.Provider.Reasoning
  alias ReqLLM.Providers.Ollama, as: OllamaProvider
  alias ReqLLM.StreamResponse

  # How long a stream may go quiet before it is a failure. `req_llm` defaults to
  # thirty seconds, which is right for a web request and wrong for this: a
  # reasoning model asked a long question routinely spends longer than that before
  # its first token, and the harness then manufactures a timeout the provider was
  # never going to produce.
  @default_receive_timeout :timer.minutes(2)

  # The ceiling on one answer from a local model. The moduledoc says why
  # there has to be one and why only there; this size is a long file written
  # in a single tool call with room to think first.
  @local_max_tokens 16_384

  # How long a local model's stream may stay silent, which is first of all
  # how long it may read before its first token. Measured cold prefill ran at
  # about 100 tokens a second for a 27B model, so a 64,000-token
  # conversation read from nothing takes over ten minutes.
  @local_idle_timeout :timer.minutes(15)

  # The options `req_llm` would see if anything named them: it refuses an
  # option it does not know, so these are this adapter's and stop here.
  @adapter_options [:local_max_tokens, :local_idle_timeout, :ollama_window]

  # Every name a request's generated-token limit goes by.
  @output_limits [:max_tokens, :max_completion_tokens, :max_output_tokens]

  @anthropic_forbidden_top_level_schema_keywords ~w(oneOf allOf anyOf)

  defmodule State do
    @moduledoc false

    # Provider options can contain credentials, authenticated gateway URLs and
    # headers. A provider lives inside Session state, which OTP may include in
    # a crash report, so none of it is safe to inspect.
    @derive {Inspect, only: []}
    defstruct options: [],
              api_keys: nil,
              api_key_defaults: nil,
              api_key_provider: nil,
              route: nil,
              response_metadata: %{headers: [], model_header: nil},
              local_max_tokens: nil,
              local_idle_timeout: nil,
              ollama_window: true

    @type t :: %__MODULE__{
            route: Route.t() | nil,
            response_metadata: map(),
            options: keyword(),
            api_keys: %{String.t() => String.t()} | nil,
            api_key_defaults: %{String.t() => String.t()} | nil,
            api_key_provider: String.t() | nil,
            local_max_tokens: pos_integer() | nil,
            local_idle_timeout: pos_integer() | nil,
            ollama_window: boolean()
          }
  end

  @doc """
  Builds the provider.

  ## Options

    * `:route` — a `{module, state}` pair implementing `Lemieux.Provider.Route`.
      Makes that route the sole inference destination and catalogue authority.
      Mutually exclusive with direct credentials, base URLs and transport routes.
      The shipped gateway route builds this pair itself: see
      `Lemieux.Ixway.provider/2`.
    * `:api_key` — overrides the key `req_llm` would resolve from the
      environment for a fixed-provider embedder. Pair it with
      `:api_key_provider` if a session may switch models.
    * `:api_key_defaults` — provider-scoped personal defaults used only when
      ReqLLM has no ambient key. Unlike `:api_keys`, absent entries retain
      ordinary environment and local-provider discovery.
    * `:api_key_provider` — binds a scalar `:api_key` to one logical provider
      and rejects attempts to spend it elsewhere.
    * `:api_keys` — a map of logical provider names to keys. This is the
      multi-provider form: catalog discovery and requests are scoped to the
      matching entry, and absent entries do not fall through to ambient keys.
    * `:base_url` — replaces the selected provider's API base URL. Use this for
      an API-compatible gateway or model proxy; `req_llm` appends the
      provider-specific request path.
    * `:transport_routes` — maps a logical provider name to a keyword list
      containing the API-compatible `:provider`, default `:base_url` and an
      optional `:credential_provider`. The logical provider still owns model
      metadata and the route's credential lookup result. An OpenAI transport
      may pin `:wire_protocol` to `"openai_chat"` or `"openai_responses"` so
      catalog changes cannot select a different endpoint or encoding. The
      pin retains catalog capabilities; unknown models remain unqualified.
    * `:response_metadata` — host-only keyword options: `headers: []` selects
      response headers to disclose, and `model_header: nil` optionally names
      the gateway's resolved-model header. The adapter emits an ephemeral
      `{:response_metadata, map}` before returning an error or emitting a
      terminal event. Headers default to none and missing facts stay nil.
      The selected headers are not persisted by Lemieux; hosts choose their
      own audit storage and must not select credential-bearing headers.
      Ixway key and receipt headers are always removed even if selected.
    * `:catalog_fallbacks` — model specifications a host has confirmed but the
      bundled catalog does not yet contain. A fallback is advertised only
      when ordinary discovery found another reachable model for its provider.
    * `:propagate_trace_context` — when true, injects the active W3C trace
      context into provider HTTP headers without replacing an explicit host
      `traceparent` or `tracestate`. Keep this false unless the configured
      endpoint is a trusted gateway such as Ixway.
    * `:receive_timeout` — how long a stream may go quiet before it is a
      failure. Defaults to two minutes rather than `req_llm`'s thirty seconds:
      thirty is a web-request default, and a reasoning model asked a long
      question routinely spends longer than that before its first token. A
      live `gpt-5.6` reflection at medium effort failed on exactly this, and
      the investigator experiment had already had to raise it in its own
      script. Lower it deliberately if a stalled request should fail fast.
    * `:local_max_tokens` — the `max_tokens` a request to an `ollama:` model
      carries when neither it, the host's options nor the catalog sets an
      output limit. Defaults to #{@local_max_tokens}; `nil` sends none,
      leaving the answer unbounded. Other models get no default: the
      moduledoc says why.
    * `:local_idle_timeout` — the least an `ollama:` request's
      `:receive_timeout` and `:stream_idle_timeout` are raised to, in
      milliseconds, because a local model sends nothing until it has read
      the whole prompt. It covers the whole answer, not only its first
      token. Defaults to fifteen minutes; `nil` leaves them as configured.
    * `:ollama_window` — whether to ask a local Ollama daemon what window it
      serves a model with (`Lemieux.Providers.OllamaWindow`). Defaults to
      `true`; with `false`, `context_window/2` answers `nil` for `ollama:`
      models and no `{:context_window, _}` event follows an answer.
    * any other option is passed to `req_llm` on every request.
  """
  @spec new(opts :: keyword()) :: Lemieux.Provider.t()
  def new(opts \\ []) when is_list(opts), do: {__MODULE__, build_state(opts)}

  @impl Lemieux.Provider
  def available_models(%State{route: route}, opts) when not is_nil(route),
    do: Route.available_models(route, opts)

  def available_models(provider_state, opts) do
    state = normalize_state(provider_state)
    options = Keyword.merge(state.options, opts)
    discovered = discover_models(state, opts)
    reachable = discovered |> Enum.map(&ModelSpec.provider/1) |> MapSet.new()

    fallbacks =
      options
      |> Keyword.get(:catalog_fallbacks, [])
      |> Enum.filter(&MapSet.member?(reachable, ModelSpec.provider(&1)))
      |> Enum.reject(&(&1 in discovered))

    discovered ++ fallbacks
  end

  @impl Lemieux.Provider
  def model_metadata(%State{route: route}) when not is_nil(route),
    do: Route.model_metadata(route)

  def model_metadata(_state), do: %{}

  @impl Lemieux.Provider
  def validate_model(%State{route: route}, spec, tools) when not is_nil(route),
    do: Route.validate_model(route, spec, tools)

  def validate_model(provider_state, spec, tools) do
    state = normalize_state(provider_state)

    with {:ok, model} <- model(spec),
         {:ok, options} <- options_for_model(state, model),
         :ok <- check_key(model, options),
         :ok <- check_route_key(model, options) do
      check_tools(model, Request.new(spec, tools: tools), options)
    end
  end

  @impl Lemieux.Provider
  def reasoning_efforts(%State{route: route}, spec) when not is_nil(route),
    do: route |> Route.reasoning_efforts(spec) |> with_default_effort()

  def reasoning_efforts(_state, spec) do
    case model(spec) do
      {:ok, model} -> model |> effort_values() |> with_default_effort()
      {:error, _reason} -> []
    end
  rescue
    # Capability discovery must not make a model unusable when the catalog is
    # unavailable or an older database has an unexpected shape.
    _error -> []
  end

  @impl Lemieux.Provider
  def run(%State{route: route, options: options} = state, %Request{} = request, emit)
      when not is_nil(route) do
    with {:ok, {target, options}} <-
           Route.target(route, request, Keyword.merge(options, request.params)) do
      stream_at(
        request,
        target,
        put_tools(request_options(options), request.tools),
        emit,
        route,
        state.response_metadata
      )
    end
  end

  def run(provider_state, %Request{} = request, emit) do
    state = normalize_state(provider_state)

    with {:ok, model} <- model(request.model),
         {:ok, options} <- options_for_model(state, model),
         :ok <- check_key(model, options),
         :ok <- check_route_key(model, options),
         :ok <- check_tools(model, request, options) do
      stream(request, model, options, emit, state)
    end
  end

  @doc false
  @spec request_target(spec :: String.t(), options :: keyword()) ::
          {:ok, {ReqLLM.model_input(), keyword()}} | {:error, term()}
  def request_target(spec, options) when is_binary(spec) and is_list(options) do
    routes = Keyword.get(options, :transport_routes, %{})
    options = request_options(options)

    case ModelSpec.split(spec) do
      {:ok, {provider, model_id}} ->
        request_target(spec, model_id, Map.get(routes, provider), options)

      :error ->
        {:error, {:invalid_model_spec, spec}}
    end
  end

  defp request_target(spec, _model_id, nil, options), do: {:ok, {spec, options}}

  defp request_target(spec, model_id, route, options) when is_list(route) do
    with target_provider when is_binary(target_provider) <- Keyword.get(route, :provider),
         {:ok, logical_model} <- ReqLLM.model(spec),
         {:ok, key} <- route_api_key(logical_model, route, options),
         {:ok, target} <- transport_target(target_provider, model_id, route) do
      routed_options =
        route
        |> Keyword.drop([:provider, :credential_provider, :wire_protocol])
        |> Keyword.merge(options)
        |> Keyword.put(:api_key, key)

      {:ok, {target, routed_options}}
    else
      nil -> {:error, {:invalid_transport_route, spec}}
      {:error, error} -> {:error, error}
    end
  end

  defp request_target(spec, _model_id, _route, _options),
    do: {:error, {:invalid_transport_route, spec}}

  defp transport_target(provider, model_id, route) do
    case Keyword.get(route, :wire_protocol) do
      nil ->
        {:ok, ModelSpec.join(provider, model_id)}

      protocol when provider == "openai" and protocol in ["openai_chat", "openai_responses"] ->
        with {:ok, model} <- ReqLLM.model(ModelSpec.join(provider, model_id)) do
          extra = Map.put(model.extra || %{}, :wire, %{protocol: protocol})
          ReqLLM.model(%{model | extra: extra})
        end

      _ ->
        {:error, {:invalid_transport_route, ModelSpec.join(provider, model_id)}}
    end
  end

  @impl Lemieux.Provider
  def estimate_cost(%State{route: route}, %Request{} = request) when not is_nil(route),
    do: Route.estimate_cost(route, request)

  # If LLMDB gains complete conditional tariffs, adapt them at this provider
  # boundary for direct, resolved requests. The same validated price curve
  # should inform both this budget estimate and Session's price preflight;
  # otherwise a long-context request could trigger compaction at one rate but
  # be admitted against a different one. Gateway routes keep their own tariff.
  #
  # A realistic upper estimate, not a worst case. The old one priced every
  # encoded byte as a token and reserved the model's whole output limit — 64K
  # tokens for a Sonnet-class model, about a dollar a request — so
  # `--max-cost-usd 5` stopped a session after two or three turns that had
  # cost cents. Unknown pricing still answers `nil`, and the gate still refuses.
  def estimate_cost(state, %Request{} = request) do
    options = state |> normalize_state() |> Map.fetch!(:options) |> Keyword.merge(request.params)

    with {:ok, model} <- model(request.model),
         output when is_integer(output) and output >= 0 <- output_reservation(request, model) do
      {input, cached} = input_estimate(request)

      usage = %{
        input_tokens: input,
        output_tokens: output,
        cached_tokens: cached,
        cache_creation_tokens: 0,
        input_includes_cached: true
      }

      case ReqLLM.Billing.calculate(usage, model, pricing_context(options)) do
        {:ok, %{total: total}} ->
          total

        {:ok, nil} ->
          list_rate_cost(model, %{
            input: input - cached,
            cached: cached,
            written: 0,
            output: output
          })
      end
    else
      _unknown -> nil
    end
  end

  # A model's catalog tariff is a list of conditional components — tiers by
  # input size, a batch or flex or priority rate, a data-residency surcharge —
  # and `ReqLLM.Billing` prices a request only when it can resolve every
  # component that could apply. For `openai:gpt-6-luna` it cannot: the
  # service-tier modifiers have no condition any pricing context answers, so
  # the calculator answers `nil`, and a session under `:max_cost_usd` stopped
  # before its first request — every metered attempt in a twelve-task
  # benchmark — against a model the catalog does price.
  #
  # The model's flat `cost` rates are its list price: what the standard tier
  # charges, and what the first tier of a long-context tariff charges. When
  # the full tariff cannot be resolved, a request is priced at list rates
  # instead, for the estimate and for the usage a direct request reports
  # (which says so: `pricing.status` is `"list_rates"`), so the gate can run
  # and the measured cost column stays filled. The assumption is the standard
  # tier: a request on a tier priced differently (batch at half, priority at
  # twice) or past a long-context threshold is estimated at list price rather
  # than refused. A model with no rates at all still answers `nil`.
  defp list_rate_cost(%{cost: %{input: input_rate, output: output_rate} = rates}, tokens)
       when is_number(input_rate) and is_number(output_rate) do
    cache_read_rate = rate_or(Map.get(rates, :cache_read), input_rate)
    cache_write_rate = rate_or(Map.get(rates, :cache_write), input_rate)

    cost =
      max(tokens.input, 0) * input_rate + tokens.cached * cache_read_rate +
        tokens.written * cache_write_rate + tokens.output * output_rate

    Float.round(cost / 1_000_000, 6)
  end

  defp list_rate_cost(_model, _tokens), do: nil

  defp rate_or(rate, _fallback) when is_number(rate), do: rate
  defp rate_or(_rate, fallback), do: fallback

  # `req_llm` prices the usage it reports from the same tariff and leaves the
  # cost out (`pricing.status` `"unknown"`) when it cannot resolve it. A direct
  # request to a model with list rates is priced here from those instead, for
  # the reason the estimate is: a session that cannot price what it just spent
  # has unknown spend, and the gate stops it before the next request. Usage
  # `req_llm` did price, and every routed request, is left exactly as reported;
  # a gateway owns its own tariff.
  defp price_usage(emit, request, nil) do
    fn
      {:usage, usage} -> emit.({:usage, list_priced(usage, request)})
      event -> emit.(event)
    end
  end

  defp price_usage(emit, _request, _route), do: emit

  defp list_priced(usage, request) when is_map(usage) do
    if is_number(Usage.cost_usd(usage)) do
      usage
    else
      with {:ok, model} <- ReqLLM.model(request.model),
           cost when is_number(cost) <- list_rate_cost(model, measured_tokens(usage)) do
        usage
        |> Map.put("cost_usd", cost)
        |> Map.put("pricing", %{"status" => "list_rates", "currency" => "USD", "total" => cost})
      else
        _unpriced -> usage
      end
    end
  end

  defp list_priced(usage, _request), do: usage

  # The counts as `json/1` left them: string keys, in the names `req_llm` and
  # the providers use. Output is `output_tokens` alone, as `ReqLLM.Billing`
  # prices it; OpenAI already counts reasoning inside it.
  defp measured_tokens(usage) do
    input = usage_count(usage, ["input_tokens"])
    cached = usage_count(usage, ["cache_read_tokens", "cached_tokens", "cache_read_input_tokens"])

    written =
      usage_count(usage, [
        "cache_write_tokens",
        "cache_creation_tokens",
        "cache_creation_input_tokens"
      ])

    uncached =
      if Map.get(usage, "input_includes_cached") in [true, "true"],
        do: max(input - cached - written, 0),
        else: input

    %{
      input: uncached,
      cached: cached,
      written: written,
      output: usage_count(usage, ["output_tokens"])
    }
  end

  @doc """
  Refuses a request that asks a model for tools it cannot use or whose schemas
  its wire provider cannot accept.

  Public because it is a rule rather than plumbing, and worth testing without
  a network. Checked here rather than left to the provider because the failure
  is otherwise a `400` describing a field name, arriving after the request was
  paid for, on a session whose whole purpose was to run tools.

  A request with no tools passes whatever the model is: a chat-only model
  answering a chat-only session is not an error.

  The public form checks the model's own provider. Normal validation and run
  paths also account for a host's API-compatible transport route.
  """
  @spec check_tools(model :: term(), request :: Request.t()) ::
          :ok
          | {:error, {:tools_unsupported, String.t(), String.t()}}
          | {:error, {:tool_schema_unsupported, String.t(), String.t(), String.t(), String.t()}}
  def check_tools(_model, %Request{tools: []}), do: :ok
  def check_tools(model, %Request{} = request), do: check_tools(model, request, [])

  defp check_tools(model, %Request{tools: tools}, options) do
    with :ok <- check_tool_capability(model, tools) do
      check_tool_schemas(wire_provider(model, options), tools)
    end
  end

  defp check_tool_capability(model, tools) do
    if described?(model) == false or ReqLLM.ModelHelpers.tools_enabled?(model) do
      :ok
    else
      {:error,
       {:tools_unsupported, model.model,
        "#{model.model} does not support tool calling, and this session has " <>
          "#{length(tools)} tools to offer it. Choose a model that does, or run the session " <>
          "with no tools."}}
    end
  end

  defp check_tool_schemas("anthropic", tools) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      case forbidden_top_level_schema_keyword(Tool.schema(tool)) do
        nil ->
          {:cont, :ok}

        keyword ->
          name = Tool.name(tool)

          message =
            "Anthropic cannot accept tool #{inspect(name)} because its input schema uses " <>
              "top-level #{keyword}. Advertise a top-level object schema and enforce " <>
              "alternative argument shapes when the tool executes."

          {:halt, {:error, {:tool_schema_unsupported, "anthropic", name, keyword, message}}}
      end
    end)
  end

  defp check_tool_schemas(_provider, _tools), do: :ok

  defp forbidden_top_level_schema_keyword(schema) do
    Enum.find(@anthropic_forbidden_top_level_schema_keywords, &Map.has_key?(schema, &1))
  end

  defp wire_provider(%{provider: provider}, options) when is_atom(provider) do
    provider = Atom.to_string(provider)
    routes = Keyword.get(options, :transport_routes, %{})
    route = if is_map(routes), do: Map.get(routes, provider)
    routed_provider(route, provider)
  end

  defp wire_provider(_model, _options), do: nil

  defp routed_provider(route, default) when is_list(route) do
    case Keyword.get(route, :provider) do
      provider when is_binary(provider) -> provider
      provider when is_atom(provider) -> Atom.to_string(provider)
      _invalid -> default
    end
  end

  defp routed_provider(_route, default), do: default

  # `req_llm` ships a model database, so the window is a lookup rather than a table
  # lemieux would have to keep current — which is the business the
  # no-provider-adapters decision keeps this library out of. An unknown model
  # answers `nil`, and the session says it is planning against a stated
  # fallback rather than presenting a guess as knowledge.
  #
  # A model the local daemon serves is the exception: its window is a server
  # setting, the catalog's number for it (when there is one) is only what it
  # was trained on, and the daemon is the one thing that can say.
  @impl Lemieux.Provider
  def context_window(%State{route: route}, spec) when not is_nil(route),
    do: Route.context_window(route, spec)

  def context_window(provider_state, spec) do
    state = normalize_state(provider_state)

    case model(spec) do
      {:ok, %{provider: :ollama} = model} -> daemon_window(state, model)
      {:ok, %{limits: %{context: context}}} when is_integer(context) and context > 0 -> context
      _otherwise -> nil
    end
  rescue
    # The model database lives behind an application a low-level caller may
    # not have started yet, and an accounting number is not worth a crash.
    _error -> nil
  end

  defp daemon_window(%State{ollama_window: true, options: options}, model) do
    if local_daemon?(options), do: OllamaWindow.window(daemon_url(model, options), wire_id(model))
  end

  defp daemon_window(_state, _model), do: nil

  # A host may route the `ollama` provider through another wire, in which
  # case what answers is not the daemon this module knows how to ask.
  defp local_daemon?(options) do
    case Keyword.get(options, :transport_routes) do
      routes when is_map(routes) -> not Map.has_key?(routes, "ollama")
      _none -> true
    end
  end

  defp daemon_url(model, options),
    do: ProviderOptions.effective_base_url(OllamaProvider, model, options)

  defp wire_id(model), do: model.provider_model_id || model.id

  @doc """
  Translates a request's transcript into the context `req_llm` will send.

  Public because it is the interesting half of this module and the half worth
  testing without a network: a resumed session is only "exactly where it left
  off" if this function says so.

  Entries that are not part of the conversation — an error, a cancellation —
  produce no message. They stay in the transcript because they are what
  happened; they are not sent because a model cannot act on them.

  Two more rules keep a replayed transcript acceptable to the provider:

    * **An abandoned attempt is not replayed as the last word.** When a request
      dies mid-answer the session keeps what arrived — an assistant entry, then
      the provider's `:error` — and a retry sends the conversation again. Sent,
      that fragment would end the request: a prefill Anthropic continues rather
      than answers (and rejects outright under extended thinking, or with
      trailing whitespace), and a final assistant message Mistral refuses. After
      a successful retry it would sit beside the answer that replaced it. So an
      assistant entry without tool calls is left out when it was an abandoned
      attempt — followed by a provider failure, or marked `"partial"` — and
      nothing a person said came after it. A fragment the person has since
      answered stays, like a cancelled turn's checkpoint: they may be replying
      to it.
    * **Claude is sent no unsigned thinking.** Anthropic rejects a thinking
      block without its signature, and signed thinking travels in
      `reasoning_details`, which req_llm turns back into blocks. Thinking
      *content* — a turn cut off mid-thought, or thinking another provider
      produced before a model switch — carries no signature, so for Claude
      targets it is dropped unless the turn's Anthropic details are signed.
      Other providers still receive it, as their own reasoning content.

  An assistant turn left with nothing but thinking, and no tool calls, is not
  sent at all: it says nothing the conversation needs, and a turn that is only
  thinking cannot carry the cache breakpoint a request's last message gets.
  """
  @spec context(request :: Request.t()) :: Context.t()
  def context(%Request{} = request), do: context(request, request.model)

  @doc """
  Translates a request for an explicit transport model.

  Reasoning retention still follows the logical model in the request. Tool
  error metadata follows the transport because API-compatible routes may
  switch wire formats without changing the model's capabilities.
  """
  @spec context(request :: Request.t(), target_model :: String.t() | LLMDB.Model.t()) ::
          Context.t()
  def context(%Request{} = request, %{provider: provider, id: id}),
    do: context(request, ModelSpec.join(Atom.to_string(provider), id))

  def context(%Request{} = request, target_model) when is_binary(target_model) do
    system = if request.system, do: [Context.system(request.system)], else: []
    thinking = thinking_policy(request.model, target_model)
    media = %{mode: media_mode(target_model), accepts: catalog_modalities(target_model)}

    messages =
      request.entries
      |> without_abandoned_attempts()
      |> Enum.flat_map(&messages(&1, thinking, media))
      |> settle_follow_ups()
      |> tool_error_metadata(target_model)

    Context.new(system ++ messages)
  end

  @doc """
  What `model` can be shown besides text, from the model catalog —
  `[:text, :image, :pdf]` — or `:unknown`.

  A session asks this before a tool attaches an image (see
  `Lemieux.Tool.Attachment`), which is why unknown is its own answer rather
  than a guess either way: an image sent to a model that cannot read it is a
  refusal on every later request that still carries it, and the catalog's
  silence about a model says nothing about its eyes. A routed model answers
  `:unknown`; the route, not this catalog, knows what serves it.
  """
  @impl Lemieux.Provider
  # `term()`, as in the `Lemieux.Provider` callbacks: the adapter's state is
  # private, and a public spec naming it would document a hidden module.
  @spec input_modalities(state :: term(), model :: String.t()) :: [atom()] | :unknown
  def input_modalities(%State{route: route}, _spec) when not is_nil(route), do: :unknown
  def input_modalities(_state, spec) when is_binary(spec), do: catalog_modalities(spec)

  defp catalog_modalities(spec) do
    case model(spec) do
      {:ok, %{modalities: %{input: [_ | _] = input}}} -> input
      _unknown -> :unknown
    end
  rescue
    # The catalog lives behind an application a low-level caller may not have
    # started; not knowing is the honest answer then too.
    _error -> :unknown
  end

  # Where an image or a document from a tool result goes. Claude, Gemini and
  # Bedrock's Converse take them inside the tool result itself, which is where
  # the model looks for what its call returned. OpenAI-compatible chat wires
  # accept images only in a user message — a tool message carrying one is
  # refused — so for every other wire they follow the run of tool results in
  # one user message, the standard workaround, labelled with the call they
  # came from.
  defp media_mode(target_model) do
    cond do
      claude_wire?(target_model) -> :nest
      wire_provider(target_model) in ~w(google google_vertex amazon_bedrock) -> :nest
      true -> :follow
    end
  end

  # Collects each run of tool messages' follow-up attachments into one user
  # message after the run. Tool results must answer the assistant's calls
  # immediately and together, so nothing may come between them.
  defp settle_follow_ups(items), do: settle(items, [], [])

  defp settle([], settled, pending), do: Enum.reverse(follow_up(pending, settled))

  defp settle([{:follow_up, parts} | rest], settled, pending),
    do: settle(rest, settled, pending ++ parts)

  defp settle([%Message{role: :tool} = message | rest], settled, pending),
    do: settle(rest, [message | settled], pending)

  defp settle([message | rest], settled, pending),
    do: settle(rest, [message | follow_up(pending, settled)], [])

  defp follow_up([], settled), do: settled
  defp follow_up(parts, settled), do: [Context.user(parts) | settled]

  # What happens to an assistant turn's thinking content: `:drop` for a model
  # that does not think, `:signed` for a Claude wire (kept only beside signed
  # Anthropic details), `:keep` otherwise. Reasoning follows the logical model;
  # signatures follow the wire, which is what validates them.
  defp thinking_policy(model, target_model) do
    cond do
      not thinks?(model) -> :drop
      claude_wire?(target_model) -> :signed
      true -> :keep
    end
  end

  defp without_abandoned_attempts(entries) do
    {kept, _state} =
      entries
      |> Enum.reverse()
      |> Enum.reduce({[], %{next: :end, failed?: false}}, &abandoned/2)

    kept
  end

  # Read from the end, so each entry knows what follows it: the next
  # conversation entry (`:end` when there is none) and whether a provider
  # failure lies in between. A dropped attempt leaves `next` as it was — what
  # follows it follows the attempt before it too.
  defp abandoned(%Entry{type: :assistant} = entry, {kept, state}) do
    if abandoned_attempt?(entry, state),
      do: {kept, %{state | failed?: false}},
      else: {[entry | kept], %{next: :assistant, failed?: false}}
  end

  defp abandoned(%Entry{type: type} = entry, {kept, _state}) when type in [:user, :tool_result],
    do: {[entry | kept], %{next: type, failed?: false}}

  # A provider failure writes its category beside its reason. A budget or loop
  # stop writes an `:error` too, but ends work rather than abandoning an answer.
  defp abandoned(
         %Entry{type: :error, payload: %{"category" => _category}} = entry,
         {kept, state}
       ),
       do: {[entry | kept], %{state | failed?: true}}

  defp abandoned(entry, {kept, state}), do: {[entry | kept], state}

  defp abandoned_attempt?(%Entry{payload: payload}, %{next: next, failed?: failed?}) do
    next in [:end, :assistant] and not match?(%{"tool_calls" => [_ | _]}, payload) and
      (failed? or match?(%{"partial" => true}, payload))
  end

  defp tool_error_metadata(messages, target_model) do
    # req_llm consumes `:is_error` for Anthropic and its cloud hosts, while its
    # OpenAI-style encoder copies metadata verbatim onto the wire. ZAI rejects that
    # field with HTTP 400 after every denied or failed tool, so only transports that
    # consume the annotation receive it. The textual failure and the durable
    # transcript status remain available everywhere.
    if ModelSpec.provider(target_model) in ~w(anthropic amazon_bedrock google_vertex) do
      messages
    else
      Enum.map(messages, fn
        %Message{role: :tool} = message ->
          %{message | metadata: Map.delete(message.metadata, :is_error)}

        message ->
          message
      end)
    end
  end

  # A transcript outlives the model that produced it: `lmx --resume ID --model
  # openai:gpt-4o-mini` replays a conversation Claude thought its way through. The
  # thinking stays in the transcript because it happened, and is not sent to a
  # model that has no concept of it. Unknown models keep everything — absent
  # capability data is not evidence of an absent capability, and sending too much
  # is a clear provider error while sending too little is a confident wrong answer.
  defp thinks?(spec) do
    case model(spec) do
      {:ok, model} -> described?(model) == false or ReqLLM.ModelHelpers.reasoning_enabled?(model)
      _otherwise -> true
    end
  rescue
    _error -> true
  end

  # Whether the model database has anything to say about this model at all. Every
  # locally-served model answers no: Ollama resolves `ollama:qwen3.8:27b-mxfp8`
  # happily and reports `capabilities: nil`, because nobody published a datasheet
  # for last night's quantisation. Reading that absence as "cannot use tools, does
  # not think" makes every local model useless through checks meant to help, so the
  # capability checks act only on data that exists.
  defp described?(%{capabilities: capabilities}) when is_map(capabilities),
    do: map_size(capabilities) > 0

  defp described?(_model), do: false

  defp effort_values(%{capabilities: capabilities} = model) when is_map(capabilities) do
    case get_in(capabilities, [:reasoning, :effort, :values]) do
      values when is_list(values) and values != [] -> clean_efforts(values)
      _missing -> extra_effort_values(model)
    end
  end

  defp effort_values(model), do: extra_effort_values(model)

  # Some catalog sources have not promoted their effort list into the canonical
  # capability map — OpenAI GPT-5 in llm_db 2026.7.5 says reasoning is enabled
  # there while `reasoning_options` carries the actual choices. Reading the generic
  # metadata keeps the rule capability-shaped rather than provider-name-shaped.
  defp extra_effort_values(%{extra: extra}) when is_map(extra) do
    options = Map.get(extra, "reasoning_options") || Map.get(extra, :reasoning_options) || []

    Enum.find_value(options, [], fn
      %{"type" => "effort", "values" => values} when is_list(values) -> clean_efforts(values)
      %{type: "effort", values: values} when is_list(values) -> clean_efforts(values)
      _other -> nil
    end)
  end

  defp extra_effort_values(_model), do: []

  defp clean_efforts(values),
    do: values |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()

  defp with_default_effort([]), do: []
  defp with_default_effort(values), do: Enum.uniq(["default" | values])

  defp messages(entry, thinking, media)

  # An attachment-bearing turn is one user message with several content parts, and
  # `req_llm` turns each into whatever the selected provider calls it. Doing that
  # translation here would be the hand-rolled provider adapter this module exists
  # not to be. Matched above the plain clause on purpose: `%{"text" => text}` is a
  # subset match and would shadow this one, dropping every attachment silently.
  defp messages(
         %Entry{type: :user, payload: %{"text" => text, "attachments" => [_ | _] = attachments}},
         _thinking,
         media
       ),
       do: [
         Context.user([
           ContentPart.text(text) | Enum.flat_map(attachments, &attachment(&1, media))
         ])
       ]

  defp messages(%Entry{type: :user, payload: %{"text" => text}}, _thinking, _media),
    do: [Context.user(text)]

  defp messages(%Entry{type: :system, payload: %{"text" => text}}, _thinking, _media),
    do: [Context.system(text)]

  defp messages(
         %Entry{type: :assistant, payload: %{"content" => parts} = payload},
         thinking,
         _media
       ) do
    # The reasoning details have to come along for a model that thinks: they
    # are what the next request replays, and a provider that receives an
    # assistant turn whose thinking has gone missing rejects the whole
    # conversation.
    assistant(sendable_thinking(parts, payload, thinking), payload, thinking != :drop)
  end

  defp messages(%Entry{type: :tool_result, payload: payload}, _thinking, media) do
    # Anthropic has a first-class `is_error` bit on tool results. Dropping the
    # transcript's error status here made a failed call indistinguishable from
    # a successful one after resume, and made a blank failure look exactly like
    # an empty success even in the request immediately following the call.
    metadata = if payload["error"] == true, do: %{is_error: true}, else: %{}

    # An attachment this model cannot take comes back as a sentence saying so,
    # which belongs with the result's text rather than in a message of its own.
    {notes, parts} =
      payload
      |> Map.get("attachments", [])
      |> Enum.flat_map(&attachment(&1, media))
      |> Enum.split_with(&(&1.type == :text))

    output = Enum.join([tool_result_output(payload) | Enum.map(notes, & &1.text)], "\n")

    tool_result(payload, output, metadata, parts, media.mode)
  end

  defp messages(%Entry{}, _thinking, _media), do: []

  defp tool_result(payload, output, metadata, [], _mode),
    do: [Context.tool_result_message(payload["name"], payload["call_id"], output, metadata)]

  defp tool_result(payload, output, metadata, parts, :nest) do
    content = [ContentPart.text(output) | parts]
    [Context.tool_result_message(payload["name"], payload["call_id"], content, metadata)]
  end

  defp tool_result(payload, output, metadata, parts, :follow) do
    label =
      ContentPart.text("[attached by the #{payload["name"]} call above (#{payload["call_id"]})]")

    [
      Context.tool_result_message(payload["name"], payload["call_id"], output, metadata),
      {:follow_up, [label | parts]}
    ]
  end

  defp sendable_thinking(parts, _payload, :keep), do: parts
  defp sendable_thinking(parts, _payload, :drop), do: Enum.reject(parts, &thinking_part?/1)

  defp sendable_thinking(parts, payload, :signed) do
    if signed_anthropic_thinking?(payload),
      do: parts,
      else: Enum.reject(parts, &thinking_part?/1)
  end

  defp thinking_part?(part), do: part["type"] == "thinking"

  # What req_llm's Anthropic encoder will turn into thinking blocks: a detail
  # from Anthropic carrying its signature, or its redacted form. Details from
  # any other provider are skipped by that encoder, which then falls back to
  # the thinking content — unsigned, and refused.
  defp signed_anthropic_thinking?(%{"reasoning_details" => details}) when is_list(details) do
    Enum.any?(details, fn detail ->
      is_map(detail) and detail["provider"] in ["anthropic", :anthropic] and
        (signed?(detail["signature"]) or redacted?(detail))
    end)
  end

  defp signed_anthropic_thinking?(_payload), do: false

  defp signed?(signature), do: is_binary(signature) and signature != ""

  defp redacted?(%{"encrypted?" => true, "provider_data" => %{"data" => data}}),
    do: is_binary(data) and data != ""

  defp redacted?(_detail), do: false

  defp tool_result_output(%{"error" => true} = payload) do
    case payload["output"] do
      output when is_binary(output) ->
        if String.trim(output) == "",
          do: "[tool failed without an error message]",
          else: output

      _missing ->
        "[tool failed without an error message]"
    end
  end

  defp tool_result_output(payload), do: payload["output"]

  # An assistant turn stripped down to nothing is dropped rather than sent
  # empty: providers reject a contentless assistant message as readily as they
  # reject thinking they do not understand, and a turn that was only thinking
  # said nothing the conversation needs — nor can it be a request's last
  # message, whose final block carries Anthropic's cache breakpoint and a
  # thinking block may not.
  defp assistant(parts, payload, thinks?) do
    calls = tool_calls(payload)

    cond do
      is_nil(calls) and Enum.all?(parts, &thinking_part?/1) ->
        []

      parts == [] ->
        [Context.assistant([], tool_calls: calls)]

      true ->
        message = Context.assistant(Enum.map(parts, &content_part/1), tool_calls: calls)
        [%{message | reasoning_details: if(thinks?, do: reasoning_details(payload))}]
    end
  end

  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    Enum.map(calls, &{&1["name"], &1["arguments"] || %{}, [id: &1["id"]]})
  end

  defp tool_calls(_payload), do: nil

  # An attachment whose shape this build does not recognise is dropped rather than
  # sent. Transcripts are forward-compatible within a schema version, so a newer
  # lemieux may have written a kind this one has no part type for, and a message
  # assembled out of `nil` is a provider 400 on a turn whose text was fine.
  # An image for a model the catalog says cannot view images is a refusal of the
  # whole request, and of every later one, since the transcript keeps it: a
  # `/model` switch from Claude to a text-only model would otherwise end the
  # session. So it is described instead. Only a known absence counts — a model
  # the catalog has no data for keeps receiving what the person attached, as it
  # always did. Documents are left alone: the catalog is patchier about PDFs
  # than images, and one wrongly withheld is a file the person asked about.
  defp attachment(%{"kind" => "image"} = attachment, %{accepts: [_ | _] = accepts}) do
    if :image in accepts,
      do: attachment(attachment),
      else: [ContentPart.text(unsent(attachment))]
  end

  defp attachment(attachment, _media), do: attachment(attachment)

  defp unsent(%{"path" => path}) when is_binary(path) and path != "",
    do: "[the image #{path} is not shown: the current model cannot view images]"

  defp unsent(_attachment), do: "[an image is not shown: the current model cannot view images]"

  defp attachment(%{"kind" => "image", "data" => data, "media_type" => media_type}),
    do: decoded(data, &ContentPart.image(&1, media_type))

  defp attachment(%{"kind" => "document", "data" => data} = binary),
    do: decoded(data, &ContentPart.file(&1, file_name(binary), binary["media_type"]))

  defp attachment(%{"text" => text}) when is_binary(text), do: [ContentPart.text(text)]
  defp attachment(_unknown), do: []

  # A provider that takes a document by name (OpenAI's `input_file`) wants one;
  # an MCP server's embedded resource may not have given it any.
  defp file_name(%{"path" => path}) when is_binary(path) and path != "", do: Path.basename(path)
  defp file_name(%{"media_type" => "application/pdf"}), do: "document.pdf"
  defp file_name(_binary), do: "document"

  # Base64 in the transcript, raw in the content part: every provider encoder
  # in `req_llm` calls `Base.encode64/1` on `:data` itself, so handing it
  # already-encoded bytes would send a base64 of a base64. A blob that will
  # not decode is dropped for the same reason an unknown kind is.
  defp decoded(data, build) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> [build.(bytes)]
      :error -> []
    end
  end

  defp decoded(_data, _build), do: []

  defp content_part(%{"type" => "text", "text" => text}), do: ContentPart.text(text)
  defp content_part(%{"type" => "thinking", "text" => text}), do: ContentPart.thinking(text)

  defp reasoning_details(%{"reasoning_details" => details}) when is_list(details) do
    Enum.map(details, fn detail ->
      %ReasoningDetails{
        text: detail["text"],
        signature: detail["signature"],
        encrypted?: detail["encrypted?"] == true,
        provider: provider_atom(detail["provider"]),
        format: detail["format"],
        index: detail["index"] || 0,
        provider_data: detail["provider_data"] || %{}
      }
    end)
  end

  defp reasoning_details(_payload), do: nil

  # Provider names are `req_llm`'s own atoms, so they already exist by the
  # time a transcript is read back. A name this build has never heard of
  # becomes nil rather than a new atom minted from a file.
  defp provider_atom(nil), do: nil
  defp provider_atom(name) when is_atom(name), do: name

  defp provider_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp model(spec) do
    case ReqLLM.model(spec) do
      {:ok, model} -> {:ok, model}
      {:error, error} -> {:error, {:unknown_model, spec, error}}
    end
  end

  defp build_state(opts) do
    route = route!(opts)

    if Keyword.has_key?(opts, :api_keys) and Keyword.has_key?(opts, :api_key) do
      raise ArgumentError, ":api_keys and :api_key are mutually exclusive"
    end

    if Keyword.has_key?(opts, :api_key_provider) and not Keyword.has_key?(opts, :api_key) do
      raise ArgumentError, ":api_key_provider requires :api_key"
    end

    %State{
      route: route,
      response_metadata: ResponseMetadata.options!(Keyword.get(opts, :response_metadata, [])),
      options:
        opts
        |> Keyword.drop([
          :api_keys,
          :api_key_defaults,
          :api_key_provider,
          :route,
          :response_metadata
          | @adapter_options
        ])
        |> Keyword.put_new(:receive_timeout, @default_receive_timeout),
      api_key_defaults: normalize_api_keys(Keyword.get(opts, :api_key_defaults)),
      api_keys: normalize_api_keys(Keyword.get(opts, :api_keys)),
      api_key_provider: normalize_provider_name(Keyword.get(opts, :api_key_provider)),
      local_max_tokens: optional_positive(opts, :local_max_tokens, @local_max_tokens),
      local_idle_timeout: optional_positive(opts, :local_idle_timeout, @local_idle_timeout),
      ollama_window: Keyword.get(opts, :ollama_window, true) == true
    }
  end

  defp optional_positive(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_nil(value) or (is_integer(value) and value > 0) ->
        value

      invalid ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer or nil, got: #{inspect(invalid)}"
    end
  end

  @direct_only [
    :base_url,
    :api_key,
    :api_keys,
    :api_key_defaults,
    :api_key_provider,
    :transport_routes
  ]

  # Unknown options are forwarded to req_llm on every request, so an `:ixway`
  # that was quietly forwarded would build a direct provider with no key and the
  # gateway settings lost. Refused by name, pointing at the replacement.
  defp route!(opts) do
    if Keyword.has_key?(opts, :ixway) do
      raise ArgumentError,
            ":ixway is not an option of #{inspect(__MODULE__)}.new/1. Build a gateway-routed " <>
              "provider with Lemieux.Ixway.provider/2, or pass route: {module, state} for any " <>
              "Lemieux.Provider.Route"
    end

    case Keyword.get(opts, :route) do
      nil ->
        nil

      {module, _state} = route when is_atom(module) ->
        if Enum.any?(@direct_only, &Keyword.has_key?(opts, &1)) do
          raise ArgumentError,
                ":route cannot be combined with direct-provider routing or credentials"
        end

        route

      other ->
        raise ArgumentError,
              ":route must be a {module, state} pair implementing Lemieux.Provider.Route, got: " <>
                inspect(other)
    end
  end

  defp normalize_state(%State{} = state), do: state

  # The callback module and its keyword state predate State. Keep accepting the
  # old shape because host provider wrappers delegate directly to these
  # callbacks as well as constructing providers through new/1.
  defp normalize_state(opts) when is_list(opts), do: build_state(opts)

  defp normalize_api_keys(nil), do: nil

  defp normalize_api_keys(keys) when is_map(keys) do
    Enum.reduce(keys, %{}, fn
      {provider, key}, normalized when is_binary(key) and key != "" ->
        Map.put(normalized, normalize_provider_name(provider), key)

      {_provider, key}, normalized when key in [nil, ""] ->
        normalized

      {provider, _key}, _normalized ->
        raise ArgumentError, "API key for #{inspect(provider)} must be a string"
    end)
  end

  defp normalize_api_keys(_other), do: raise(ArgumentError, ":api_keys must be a map")

  defp normalize_provider_name(nil), do: nil
  defp normalize_provider_name(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp normalize_provider_name(provider) when is_binary(provider) do
    case provider |> String.trim() |> String.downcase() do
      "" -> raise ArgumentError, "provider name cannot be empty"
      normalized -> normalized
    end
  end

  defp normalize_provider_name(provider) do
    raise ArgumentError, "provider name must be an atom or string, got: #{inspect(provider)}"
  end

  defp discover_models(%State{api_keys: keys} = state, opts) when is_map(keys) do
    query_opts = Keyword.merge(state.options, opts)

    keys
    |> Enum.sort()
    |> Enum.flat_map(fn {provider, key} ->
      if requested_provider?(query_opts, provider) do
        discover_provider(state, opts, provider, api_key: key)
      else
        []
      end
    end)
    |> Enum.uniq()
  end

  defp discover_models(%State{api_key_provider: provider} = state, opts)
       when is_binary(provider) do
    query_opts = Keyword.merge(state.options, opts)

    if requested_provider?(query_opts, provider),
      do: discover_provider(state, opts, provider),
      else: []
  end

  defp discover_models(%State{options: options} = state, opts) do
    if Keyword.has_key?(options, :api_key) do
      case Keyword.get(Keyword.merge(options, opts), :scope) do
        provider when is_atom(provider) and provider != :all ->
          discover_provider(state, opts, Atom.to_string(provider))

        # A scalar key carries no provider identity. Treating it as an
        # all-provider credential is what produced the enormous, unusable
        # picker; require a scoped query while old callers migrate.
        _unscoped ->
          []
      end
    else
      options = Keyword.merge(state.options, opts)
      ordinary = options |> request_options() |> ReqLLM.available_models()

      Enum.uniq(ordinary ++ discover_routed_models(options) ++ discover_default_keys(state, opts))
    end
  end

  defp discover_default_keys(%State{api_key_defaults: nil}, _opts), do: []

  defp discover_default_keys(state, opts) do
    Enum.flat_map(state.api_key_defaults, fn {provider, _key} ->
      with true <- requested_provider?(opts, provider),
           atom when not is_nil(atom) <- provider_atom(provider),
           {:ok, options} <- default_key_options(state.options, state.api_key_defaults, atom),
           {:ok, key, _source} <- ReqLLM.Keys.get(atom, options) do
        discover_provider(state, opts, provider, api_key: key)
      else
        _unavailable -> []
      end
    end)
  end

  defp discover_routed_models(options) do
    options
    |> Keyword.get(:transport_routes, %{})
    |> Enum.sort()
    |> Enum.flat_map(fn {provider, route} ->
      discover_routed_provider(options, provider, route)
    end)
  end

  defp discover_routed_provider(options, provider, route) when is_list(route) do
    with true <- requested_provider?(options, provider),
         provider_atom when is_atom(provider_atom) <- provider_atom(provider),
         {:ok, key} <- route_api_key(provider_atom, route, options) do
      options
      |> request_options()
      |> Keyword.put(:scope, provider_atom)
      |> Keyword.put(:api_key, key)
      |> ReqLLM.available_models()
    else
      _unavailable -> []
    end
  end

  defp discover_routed_provider(_options, _provider, _route), do: []

  defp discover_provider(state, opts, provider, extra \\ []) do
    case provider_atom(provider) do
      nil ->
        []

      provider_atom ->
        state.options
        |> Keyword.merge(opts)
        |> Keyword.merge(extra)
        |> Keyword.put(:scope, provider_atom)
        |> request_options()
        |> ReqLLM.available_models()
    end
  end

  defp requested_provider?(opts, provider) do
    case Keyword.get(opts, :scope, :all) do
      :all -> true
      requested when is_atom(requested) -> Atom.to_string(requested) == provider
      requested when is_binary(requested) -> String.downcase(requested) == provider
      _invalid -> false
    end
  end

  defp options_for_model(%State{api_keys: keys} = state, model) when is_map(keys) do
    provider = Atom.to_string(model.provider)

    case Map.fetch(keys, provider) do
      {:ok, key} ->
        {:ok, Keyword.put(state.options, :api_key, key)}

      :error ->
        missing_scoped_key(state.options, model, ":api_keys has no #{provider} entry")
    end
  end

  defp options_for_model(%State{api_key_provider: provider} = state, model)
       when is_binary(provider) do
    if Atom.to_string(model.provider) == provider do
      {:ok, state.options}
    else
      missing_scoped_key(
        state.options,
        model,
        "the scalar :api_key belongs to #{provider}, not #{model.provider}"
      )
    end
  end

  defp options_for_model(%State{api_key_defaults: defaults} = state, model)
       when is_map(defaults) do
    case ReqLLM.Keys.get(model, state.options) do
      {:ok, _key, _source} ->
        {:ok, state.options}

      {:error, _} ->
        default_key_options(state.options, defaults, model.provider)
    end
  end

  defp options_for_model(%State{} = state, _model), do: {:ok, state.options}

  defp default_key_options(options, defaults, provider) do
    # An explicitly empty ambient credential disables access; it must not
    # silently revive a saved key. Only absence permits a personal fallback.
    ambient =
      System.get_env(ReqLLM.Keys.env_var_name(provider)) ||
        Application.get_env(:req_llm, ReqLLM.Keys.config_key(provider))

    key = if is_nil(ambient), do: Map.get(defaults, Atom.to_string(provider))
    {:ok, if(key, do: Keyword.put(options, :api_key, key), else: options)}
  end

  defp missing_scoped_key(options, model, hint) do
    if credential_required?(model.provider) do
      {:error, {:missing_api_key, model.provider, hint}}
    else
      # Local and other credential-free providers remain usable alongside a
      # map of remote credentials.
      {:ok, Keyword.delete(options, :api_key)}
    end
  end

  defp credential_required?(provider) do
    case ReqLLM.provider(provider) do
      {:ok, module} -> function_exported?(module, :default_env_key, 0)
      {:error, _reason} -> false
    end
  end

  # A missing key is the most common way a first run fails, and not worth a round
  # trip to discover — but only for a provider that wants one. Ollama runs on the
  # machine and has nothing to authenticate to, and `req_llm` says so by declaring
  # no environment variable for it.
  defp check_key(model, opts) do
    with {:ok, provider} <- ReqLLM.provider(model.provider),
         true <- function_exported?(provider, :default_env_key, 0),
         {:error, hint} <- ReqLLM.Keys.get(model, opts) do
      {:error, {:missing_api_key, model.provider, hint}}
    else
      _otherwise -> :ok
    end
  end

  defp check_route_key(model, options) do
    routes = Keyword.get(options, :transport_routes, %{})

    case Map.get(routes, Atom.to_string(model.provider)) do
      nil ->
        :ok

      route when is_list(route) ->
        route_api_key(model, route, options) |> route_key_result()

      _invalid ->
        {:error,
         {:invalid_transport_route, ModelSpec.join(Atom.to_string(model.provider), model.id)}}
    end
  end

  defp route_key_result({:ok, _key}), do: :ok
  defp route_key_result({:error, _reason} = error), do: error

  defp route_api_key(logical_provider_or_model, route, options) do
    logical_provider = logical_provider(logical_provider_or_model)

    with {:ok, credential_provider} <- credential_provider(logical_provider_or_model, route),
         {:ok, key, _source} <- ReqLLM.Keys.get(credential_provider, options) do
      {:ok, key}
    else
      {:error, {:invalid_transport_route, _spec}} = error -> error
      {:error, hint} -> {:error, {:missing_api_key, logical_provider, hint}}
    end
  end

  defp credential_provider(logical_provider_or_model, route) do
    case Keyword.get(route, :credential_provider) do
      nil -> {:ok, logical_provider_or_model}
      provider when is_atom(provider) -> {:ok, provider}
      provider when is_binary(provider) -> credential_provider_atom(provider)
      _invalid -> {:error, {:invalid_transport_route, logical_spec(logical_provider_or_model)}}
    end
  end

  defp credential_provider_atom(provider) do
    case provider_atom(provider) do
      nil -> {:error, {:invalid_transport_route, provider}}
      provider -> {:ok, provider}
    end
  end

  defp logical_provider(%LLMDB.Model{provider: provider}), do: provider
  defp logical_provider(provider) when is_atom(provider), do: provider

  defp logical_spec(%LLMDB.Model{provider: provider, id: id}),
    do: ModelSpec.join(Atom.to_string(provider), id)

  defp logical_spec(provider) when is_atom(provider), do: Atom.to_string(provider)

  defp stream(request, model, provider_options, emit, %State{} = state) do
    options =
      provider_options
      |> Keyword.merge(request.params)
      |> put_local_max_tokens(model, state.local_max_tokens)
      |> wait_for_local_model(model, state.local_idle_timeout)
      |> put_pricing_context(request)
      |> Keyword.put(:transport_routes, Keyword.get(provider_options, :transport_routes, %{}))
      |> put_tools(request.tools)

    with {:ok, {target, options}} <- request_target(request.model, options) do
      stream_at(
        request,
        target,
        options,
        emit,
        nil,
        state.response_metadata,
        served_window(state, model, provider_options)
      )
    end
  end

  # Only a model the person's own daemon serves: the moduledoc says why every
  # other model is left to its server. A limit already set wins, and so does
  # one the catalog publishes, which `req_llm` would send itself.
  defp put_local_max_tokens(options, %{provider: :ollama} = model, cap) when is_integer(cap) do
    if local_daemon?(options) and not output_limited?(options) and not published_limit?(model),
      do: Keyword.put(options, :max_tokens, cap),
      else: options
  end

  defp put_local_max_tokens(options, _model, _cap), do: options

  # Where `req_llm` itself looks before applying a catalog limit: the request
  # options, or the provider options in either key form.
  defp output_limited?(options) do
    nested = Keyword.get(options, :provider_options)
    Enum.any?(@output_limits, &(Keyword.has_key?(options, &1) or nested_limit?(nested, &1)))
  end

  defp nested_limit?(nested, key) when is_list(nested),
    do: Keyword.keyword?(nested) and Keyword.has_key?(nested, key)

  defp nested_limit?(nested, key) when is_map(nested),
    do: Map.has_key?(nested, key) or Map.has_key?(nested, Atom.to_string(key))

  defp nested_limit?(_nested, _key), do: false

  defp published_limit?(model) do
    case get_in(model.limits || %{}, [:output]) do
      limit when is_integer(limit) and limit > 0 -> true
      _unpublished -> false
    end
  end

  # Raised, never lowered: a host that allows a longer silence keeps it.
  # `:stream_idle_timeout` may come from the application environment instead
  # of an option, and `req_llm` would read it there.
  defp wait_for_local_model(options, %{provider: :ollama}, wait) when is_integer(wait) do
    if local_daemon?(options) do
      idle =
        Keyword.get_lazy(options, :stream_idle_timeout, fn ->
          Application.get_env(:req_llm, :stream_idle_timeout)
        end)

      options
      |> at_least(:receive_timeout, Keyword.get(options, :receive_timeout), wait)
      |> at_least(:stream_idle_timeout, idle, wait)
    else
      options
    end
  end

  defp wait_for_local_model(options, _model, _wait), do: options

  defp at_least(options, key, current, wait) when is_integer(current) and current < wait,
    do: Keyword.put(options, key, wait)

  defp at_least(options, _key, _current, _wait), do: options

  # Asked after the answer, when this request has loaded the model the way
  # every later request will find it: a `/v1` request carries no window, so
  # it gets the daemon's own, whatever another client loaded the model with.
  defp served_window(%State{ollama_window: true}, %{provider: :ollama} = model, options) do
    if local_daemon?(options) do
      url = daemon_url(model, options)
      id = wire_id(model)
      fn -> OllamaWindow.loaded(url, id) end
    end
  end

  defp served_window(_state, _model, _options), do: nil

  defp report_served_window(nil, _emit), do: :ok

  defp report_served_window(lookup, emit) do
    case lookup.() do
      window when is_integer(window) and window > 0 -> emit.({:context_window, window})
      _unknown -> :ok
    end
  end

  # Direct calls stream a response rather than submit a batch. Leaving this
  # known field absent makes a catalog's batch discount unresolved, turning
  # both budget estimates and reported costs into unknown pricing. Preserve
  # explicit host context, including an intentionally incomplete one.
  defp pricing_context(options),
    do: Keyword.get(options, :pricing_context, %{api: "realtime"})

  # stream_object/4 prepares a Req request before stripping stream-only
  # options in ReqLLM 1.26; adding pricing_context there raises an unknown
  # option error. Direct text calls accept this default; routes own theirs.
  defp put_pricing_context(options, %Request{output_schema: nil}),
    do: Keyword.put_new(options, :pricing_context, pricing_context([]))

  defp put_pricing_context(options, %Request{}), do: options

  # `route` is nil on the direct path; the route hooks are identity for it.
  # `served`, also direct-only, asks what window the answer was served with.
  defp stream_at(request, target, options, emit, route, metadata_options, served \\ nil) do
    options = with_prompt_cache(options, target, route)
    emit = price_usage(emit, request, route)
    # Private to this request: a route's own stream bookkeeping uses another
    # reference, and must never receive these messages as its own.
    facts = make_ref()

    {outcome, metadata, reference} =
      case stream_response(request, target, options) do
        {:ok, response} ->
          {{result, reference}, metadata} =
            ResponseMetadata.capture(
              response,
              metadata_options,
              &process(&1, emit, route, facts)
            )

          {result, metadata, reference}

        {:error, _reason} = error ->
          {error, %{}, nil}
      end

    # Drained either way, so nothing is left in a caller's mailbox. A route owns
    # the shape of the stream it relays — a gateway may re-frame it — so only a
    # request this adapter sent directly is judged by it.
    observed = stream_facts(facts)
    stream = if is_nil(route), do: observed, else: :routed
    emit.(ResponseMetadata.event(request, metadata, outcome, metadata_options))

    with {:ok, result} <- outcome,
         :ok <- judged_complete(result, stream, target, emit),
         {:ok, result} <- structured_response(request, result, emit),
         :ok <- check_answered(result, request.model) do
      Enum.each(calls(result.message, request.tools), &emit.({:tool_call, &1}))
      message = Route.annotate_message(route, payload(result.message), result)
      emit.({:message, message})
      if result.usage, do: emit.({:usage, json(result.usage)})
      report_served_window(served, emit)
      emit.({:done, result.finish_reason || :stop})
      if reference, do: Route.after_stream(route, request, reference)
      :ok
    else
      {:error, error} ->
        {:error,
         error
         |> stream_error(stream, target)
         |> ProviderError.recognize_overflow(wire_provider(target))}
    end
  end

  # ReqLLM reports an OpenAI-compatible server's error event — sent inside a
  # `200` stream, mid-answer — as the bare sentence, which classified as
  # `:other` and was never retried. `process/4` saw the event itself, so the
  # sentence is known to be the provider breaking off, not an untyped mystery.
  defp stream_error(detail, %{error: detail}, target) when is_binary(detail),
    do: %Interrupted{provider: wire_provider(target), finish_reason: :error, detail: detail}

  defp stream_error(error, _stream, _target), do: error

  defp judged_complete(_result, :routed, _target, _emit), do: :ok

  defp judged_complete(result, stream, target, emit),
    do: check_complete(result, stream, target, emit)

  # An agent loop resends its whole prefix on every request, and Anthropic bills
  # a cached prefix at a tenth of the input price — so without caching a long
  # session pays full price for the same system prompt, tools and history
  # dozens of times over, and waits longer for each first token. ReqLLM leaves
  # it off. Here it is on for every Claude target the adapter sends directly:
  # breakpoints on the tools and the system prompt, and a rolling one on the
  # last message, so each request reads what the previous one wrote. An
  # explicit `anthropic_prompt_cache: false` — in provider options or request
  # params — turns it off. A route owns its own request shape, so routed
  # requests are left exactly as the route sent them.
  defp with_prompt_cache(options, _target, route) when not is_nil(route), do: options

  defp with_prompt_cache(options, target, nil) do
    if claude_wire?(target) do
      options
      |> Keyword.put_new(:anthropic_prompt_cache, true)
      |> with_rolling_breakpoint()
    else
      options
    end
  end

  defp with_rolling_breakpoint(options) do
    case Keyword.fetch(options, :anthropic_prompt_cache) do
      {:ok, true} -> Keyword.put_new(options, :anthropic_cache_messages, -1)
      _disabled -> options
    end
  end

  # Claude, spoken in Anthropic's own wire format: directly, or through a cloud
  # that hosts it. ReqLLM accepts the caching options for exactly these; any
  # other provider would reject them as unknown options.
  defp claude_wire?(target) do
    case {wire_provider(target), wire_model_id(target)} do
      {"anthropic", _model_id} ->
        true

      {provider, model_id}
      when provider in ~w(amazon_bedrock google_vertex azure) and is_binary(model_id) ->
        model_id |> String.downcase() |> String.contains?("claude")

      _other ->
        false
    end
  end

  defp wire_provider(target) when is_binary(target), do: ModelSpec.provider(target)

  defp wire_provider(%{provider: provider}) when is_atom(provider) and not is_nil(provider),
    do: Atom.to_string(provider)

  defp wire_provider(_target), do: nil

  defp wire_model_id(target) when is_binary(target), do: ModelSpec.model_id(target)
  defp wire_model_id(%{id: id}) when is_binary(id), do: id
  defp wire_model_id(_target), do: nil

  # What the stream said about itself while it ran: whether the provider sent
  # the terminal marker a finished answer carries, and the sentence of an error
  # it reported inside a successful response. Gathered from the process's own
  # mailbox, where `process/4` left them.
  defp stream_facts(facts, acc \\ %{terminal?: false, error: nil}) do
    receive do
      {^facts, :terminal} -> stream_facts(facts, %{acc | terminal?: true})
      {^facts, :error, detail} -> stream_facts(facts, %{acc | error: acc.error || detail})
    after
      0 -> acc
    end
  end

  @doc """
  Refuses to report a stream that broke off as a finished answer.

  Two failures reach this adapter as success. An OpenAI-compatible server that
  fails mid-answer sends an error event inside its `200` stream, which ReqLLM
  turns into a response with finish reason `:error` — and, when some text had
  already arrived, `check_answered/2` would accept it. Anthropic sends
  `event: error` and closes the stream, which ReqLLM's decoder skips: the
  response just ends, without the `message_delta`/`message_stop` every
  complete Anthropic answer carries. Either way the transcript would record a
  truncated answer as whole, and nothing would retry it.

  So both become a `Lemieux.Provider.Interrupted`, which
  `Lemieux.Provider.Error` classifies as `:server`, like a `5xx`. What did
  arrive is emitted first as a `{:message, payload}` marked `"partial"`, with
  any usage the provider reported: the fragment keeps the signatures of the
  thinking blocks that completed, which the deltas alone cannot, and the
  tokens were billed whether or not the answer finished.

  The missing-terminal rule applies only to Claude's wire format, where ReqLLM
  is known to emit the marker. Elsewhere its absence says nothing, and a
  provider that never sends one must not have every answer called broken.
  """
  @spec check_complete(
          result :: map(),
          stream :: %{terminal?: boolean(), error: String.t() | nil},
          target :: ReqLLM.model_input(),
          emit :: Lemieux.Provider.emit()
        ) :: :ok | {:error, Interrupted.t()}
  def check_complete(result, stream, target, emit) do
    case interruption(result, stream, target) do
      nil ->
        :ok

      interrupted ->
        keep_partial(result, emit)
        {:error, interrupted}
    end
  end

  defp interruption(%{finish_reason: :error}, stream, target),
    do: %Interrupted{provider: wire_provider(target), finish_reason: :error, detail: stream.error}

  defp interruption(result, %{error: detail}, target) when is_binary(detail),
    do: %Interrupted{
      provider: wire_provider(target),
      finish_reason: Map.get(result, :finish_reason),
      detail: detail
    }

  # ReqLLM calls a stream that ended without its terminal event `:incomplete`.
  # For Claude that is the dropped error event; elsewhere it is left to
  # `check_answered/2`, which turns an empty `:incomplete` into an
  # `{:unanswered, model, finish}` failure that `Lemieux.Provider.Error`
  # files, like this one, under `:server`.
  defp interruption(%{finish_reason: finish}, %{terminal?: false}, target)
       when finish in [nil, :unknown, :incomplete] do
    if claude_wire?(target),
      do: %Interrupted{provider: wire_provider(target), finish_reason: finish}
  end

  defp interruption(_result, _stream, _target), do: nil

  defp keep_partial(result, emit) do
    case partial_payload(result) do
      nil -> :ok
      payload -> emit.({:message, Map.put(payload, "partial", true)})
    end

    if Map.get(result, :usage), do: emit.({:usage, json(result.usage)})
    :ok
  end

  defp partial_payload(%{message: %Message{} = message}) do
    payload = payload(message)
    if payload["content"] != [] or Map.has_key?(payload, "reasoning_details"), do: payload
  end

  defp partial_payload(_result), do: nil

  defp stream_response(%Request{output_schema: nil} = request, target, options),
    do: ReqLLM.stream_text(target, context(request, target), options)

  defp stream_response(%Request{} = request, target, options),
    do: ReqLLM.stream_object(target, context(request, target), request.output_schema, options)

  defp structured_response(%Request{output_schema: nil}, result, _emit), do: {:ok, result}

  defp structured_response(request, result, emit) do
    # ReqLLM's tool-based object mode retains a synthetic structured_output
    # call in the complete message. It is the requested answer, not a harness
    # tool: dispatching it produced an unavailable-tool error and spent the
    # research pipeline's only turn. Validate through ReqLLM before converting
    # it to the same JSON content its native object mode already supplies.
    structured_call(calls(result.message), request.output_schema, result, emit)
  end

  defp structured_call(
         [%{name: "structured_output", argument_error: reason}],
         _schema,
         _result,
         _emit
       ),
       do: {:error, {:invalid_structured_output, reason}}

  defp structured_call([%{name: "structured_output", arguments: object}], schema, result, emit) do
    with {:ok, _validated} <- ReqLLM.Schema.validate(object, ReqLLM.Schema.to_json(schema)) do
      text = JSON.encode!(object)
      thinking = Enum.filter(result.message.content, &(&1.type == :thinking))

      message = %{
        result.message
        | content: thinking ++ [ContentPart.text(text)],
          tool_calls: []
      }

      finish = if result.finish_reason == :tool_calls, do: :stop, else: result.finish_reason
      emit.({:text_delta, text})
      {:ok, %{result | message: message, object: object, finish_reason: finish}}
    end
  end

  defp structured_call(_calls, _schema, result, _emit), do: {:ok, result}

  @doc """
  Refuses to report a request that produced nothing as a completed turn.

  Found live against OpenAI, and it is the kind of failure worth a rule. A
  request that the provider refused — no credit on the account — came back
  through the streaming path as `{:ok, response}` with an empty stream, no
  usage and a finish reason of `:incomplete`. Nothing in the response says why:
  the same request made non-streaming reports a `429` and a sentence about
  billing, but the streamed one arrives looking like a model that chose to say
  nothing.

  Reported as a finish, that is a session that answers with a blank line and
  goes idle, and a person with no idea their account is empty. So a turn with
  **no content, no tool calls, and a finish reason that is not a normal stop**
  is an error instead.

  Deliberately narrow. A model that stops with `:stop` and says nothing is odd
  but not broken; a truncated answer has content, and keeps it.

  The failure is `{:unanswered, model, finish_reason}`, which
  `Lemieux.Provider.Error.category/1` files under `:server` when the finish is
  `:incomplete` or `:unknown`, so the session's bounded retry asks again. It
  was `:other` — the OpenAI case above is a refusal, and a refusal is not
  retried — until a gateway behind a CDN closed a `200` stream with nothing
  in it, once in an 89-task benchmark, and the attempt was recorded as the
  model failing. The response does not say which of the two happened. A
  refusal that repeats fails every retry with the same sentence, which still
  names credit, quota and request validity; a cut stream is answered on the
  next try. `:length` and `:content_filter` with nothing in them stay
  `:other`: the provider finished on purpose and said so.
  """
  @spec check_answered(result :: map(), model :: String.t()) ::
          :ok | {:error, {:unanswered, String.t(), term()}}
  def check_answered(result, model) do
    if answered?(result), do: :ok, else: {:error, unanswered(result, model)}
  end

  defp answered?(%{message: %Message{} = message} = result) do
    content?(message) or calls(message) != [] or result.finish_reason in [:stop, :end_turn, nil]
  end

  defp answered?(_result), do: true

  defp content?(%Message{content: content}) when is_list(content) do
    Enum.any?(content, &content_part?/1)
  end

  defp content?(_message), do: false

  defp content_part?(%{type: :object, object: object}) when is_map(object), do: true
  defp content_part?(%{text: text}) when is_binary(text), do: text != ""
  defp content_part?(_part), do: false

  defp unanswered(result, model) do
    {:unanswered, model, result.finish_reason}
  end

  defp put_tools(options, []), do: options
  defp put_tools(options, tools), do: Keyword.put(options, :tools, Enum.map(tools, &tool/1))

  defp request_options(options) do
    options
    |> OpenTelemetry.inject_req_options()
    |> Keyword.drop([:transport_routes, :catalog_fallbacks, :response_metadata])
    |> normalize_reasoning_effort()
  end

  defp normalize_reasoning_effort(options) do
    case Keyword.fetch(options, :reasoning_effort) do
      {:ok, effort} ->
        Keyword.put(
          options,
          :reasoning_effort,
          Reasoning.normalize_effort(effort)
        )

      :error ->
        options
    end
  end

  defp tool(tool) do
    ReqLLM.Tool.new!(
      name: Tool.name(tool),
      description: Tool.description(tool),
      parameter_schema: Tool.schema(tool),
      # req_llm can execute tools itself; lemieux does not let it. Execution goes
      # through `Lemieux.Tools.run/4`, which is where hooks, the transcript entry and
      # the crash handling live. The callback exists because the struct requires one,
      # and reaching it means something bypassed the loop.
      callback: fn _args ->
        raise "lemieux executes its own tools; req_llm should never call this"
      end
    )
  end

  # About four bytes to a token for text, code and the JSON around them. Tool
  # descriptions and schemas are counted too: they are part of the request even
  # though they are not transcript entries.
  @bytes_per_token 4

  # What a turn is assumed to write when nothing better is known: enough for a
  # long answer or a substantial file, far below the 64K or 128K output limits
  # of current models, which almost no agent turn approaches.
  @output_reservation 8_192

  # The input the request will be billed for, and how much of it the provider
  # will likely read from cache. The last request that reported usage is the
  # best evidence there is: its measured input, plus the answer it produced
  # (now part of the conversation), plus whatever was added after it. With no
  # measurement yet, the whole request is estimated from its bytes and nothing
  # is assumed cached. The cache share is the one that request observed —
  # reads only, so a prefix that was being written rather than read is still
  # priced as ordinary input.
  defp input_estimate(%Request{} = request) do
    case last_measured(request.entries) do
      {usage, after_anchor} ->
        measured = measured_input(usage)
        # The measurement already paid for the system prompt and the tools.
        added_only = %{request | entries: after_anchor, system: nil, tools: []}
        added = div(Request.input_bytes(added_only), @bytes_per_token)
        input = max(measured.total + measured.output + added, 1)
        cached = if measured.total > 0, do: div(input * measured.cached, measured.total), else: 0
        {input, min(cached, input)}

      nil ->
        {max(div(Request.input_bytes(request), @bytes_per_token), 1), 0}
    end
  end

  defp last_measured(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Entry{type: :assistant, usage: usage}, index} when is_map(usage) ->
        if measured_input(usage).total > 0, do: {usage, Enum.drop(entries, index + 1)}

      _other ->
        nil
    end)
  end

  # Anthropic reports cache reads and writes beside `input_tokens`; OpenAI
  # counts cached tokens inside it. `input_includes_cached` says which, as it
  # does for `Lemieux.Context`.
  defp measured_input(usage) do
    input = usage_count(usage, ["input_tokens"])
    cached = usage_count(usage, ["cache_read_tokens", "cached_tokens"])
    written = usage_count(usage, ["cache_write_tokens", "cache_creation_tokens"])

    uncached =
      if Map.get(usage, "input_includes_cached") in [true, "true"],
        do: max(input - cached - written, 0),
        else: input

    %{
      total: uncached + cached + written,
      cached: cached,
      output: usage_count(usage, ["output_tokens"]) + usage_count(usage, ["reasoning_tokens"])
    }
  end

  defp usage_count(usage, keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(usage, key) do
        count when is_integer(count) and count >= 0 -> count
        _absent -> nil
      end
    end)
  end

  # An explicit `max_tokens` is the host's own cap and the true ceiling. Without
  # one, the reservation is realistic: twice the largest answer this
  # conversation has produced, at least `@output_reservation`, never above what
  # the model can emit.
  defp output_reservation(request, model) do
    case Keyword.get(request.params, :max_tokens) do
      max_tokens when is_integer(max_tokens) ->
        max_tokens

      _unset ->
        observed = 2 * largest_output(request.entries)
        reservation = max(@output_reservation, observed)

        case get_in(model.limits || %{}, [:output]) do
          limit when is_integer(limit) and limit > 0 -> min(reservation, limit)
          _unknown -> reservation
        end
    end
  end

  defp largest_output(entries) do
    entries
    |> Enum.flat_map(fn
      %Entry{type: :assistant, usage: usage} when is_map(usage) -> [measured_input(usage).output]
      _other -> []
    end)
    |> Enum.max(fn -> 0 end)
  end

  defp calls(%Message{tool_calls: tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.reject(&ReqLLM.ToolCall.builtin?/1)
    |> Enum.map(fn call ->
      arguments = call.function[:arguments] || call.function["arguments"]

      %{
        id: call.id,
        name: call.function[:name] || call.function["name"],
        arguments: normalized_arguments(arguments)
      }
      |> put_argument_error(arguments)
    end)
  end

  defp calls(_message), do: []

  # Models fill optional parameters they mean to leave out with `null` or `""`:
  # `bash` handed a command beside `task_id: null` refused it as asking for two
  # things at once. A declared, optional property set to either is dropped
  # here, once, for every tool, rather than each tool learning to ignore it.
  # Required properties are left alone — `""` is a real value for `edit`'s `new`
  # — and so are properties the schema does not declare, which the tool itself
  # should refuse rather than have silently disappear.
  defp calls(message, tools) do
    optional = optional_properties(tools)
    message |> calls() |> Enum.map(&without_absent(&1, Map.get(optional, &1.name)))
  end

  defp without_absent(call, nil), do: call

  defp without_absent(%{arguments: arguments} = call, optional) do
    kept =
      Map.reject(arguments, fn {key, value} ->
        value in [nil, ""] and MapSet.member?(optional, key)
      end)

    %{call | arguments: kept}
  end

  defp optional_properties(tools) do
    Map.new(tools, &{Tool.name(&1), optional_keys(Tool.schema(&1))})
  end

  defp optional_keys(schema) when is_map(schema) do
    case Map.get(schema, "properties") || Map.get(schema, :properties) do
      properties when is_map(properties) ->
        required = Map.get(schema, "required") || Map.get(schema, :required) || []

        properties
        |> Map.keys()
        |> MapSet.new(&to_string/1)
        |> MapSet.difference(MapSet.new(List.wrap(required), &to_string/1))

      _none ->
        MapSet.new()
    end
  end

  @doc """
  Decodes the arguments exactly as the provider supplied them.

  Kept public because malformed calls are an observable provider-boundary
  contract and embedders need to test it without constructing a live stream.
  A non-object JSON value is invalid for a tool even though it is valid JSON.
  """
  @spec decode_arguments(arguments :: term()) :: {:ok, map()} | {:error, term()}
  def decode_arguments(arguments) when is_map(arguments), do: {:ok, arguments}

  def decode_arguments(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, arguments} when is_map(arguments) -> {:ok, arguments}
      {:ok, other} -> {:error, {:expected_object, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  def decode_arguments(other), do: {:error, {:expected_object, other}}

  defp normalized_arguments(arguments) do
    case decode_arguments(arguments) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> %{}
    end
  end

  defp put_argument_error(call, arguments) do
    case decode_arguments(arguments) do
      {:ok, _decoded} -> call
      {:error, reason} -> Map.put(call, :argument_error, reason)
    end
  end

  defp process(response, emit, route, facts) do
    reference = make_ref()
    response = Route.observe_stream(route, response, reference)

    result =
      StreamResponse.process_stream(response,
        on_result: &emit.({:text_delta, &1}),
        on_thinking: &emit.({:thinking_delta, &1}),
        # A tool call's name arrives when the provider opens it and its arguments arrive
        # as `tool_call_args` fragments on meta chunks. Neither is the call — `calls/1`
        # reads the assembled message for that — but together they are the only sign of
        # life while a model writes a long file.
        on_tool_call: &emit.({:tool_call_delta, call_opened(&1)}),
        on_meta: fn chunk ->
          note_stream_fact(chunk, facts)
          emit_argument_fragment(chunk, emit)
        end
      )

    {Route.finish_stream(route, result, reference), reference}
  end

  # Callbacks run in this process while it consumes the stream, so what they
  # notice is sent to the process itself and read back, in order, once the
  # stream is over — the same way `Lemieux.Session` drains a summary.
  defp note_stream_fact(%{metadata: metadata}, facts) when is_map(metadata) do
    if (metadata[:terminal?] || metadata["terminal?"]) == true,
      do: send(self(), {facts, :terminal})

    case metadata[:error] || metadata["error"] do
      detail when is_binary(detail) and detail != "" -> send(self(), {facts, :error, detail})
      _none -> :ok
    end
  end

  defp note_stream_fact(_chunk, _facts), do: :ok

  defp call_opened(chunk) do
    index = chunk.metadata[:index] || chunk.metadata["index"]
    delta = %{name: chunk.name}
    if is_integer(index), do: Map.put(delta, :index, index), else: delta
  end

  defp emit_argument_fragment(%{metadata: %{tool_call_args: %{fragment: fragment} = args}}, emit)
       when is_binary(fragment) and fragment != "" do
    delta = %{fragment: fragment}
    index = args[:index]

    emit.(
      {:tool_call_delta, if(is_integer(index), do: Map.put(delta, :index, index), else: delta)}
    )
  end

  defp emit_argument_fragment(_chunk, _emit), do: :ok

  defp payload(%Message{content: content} = message) when is_list(content) do
    parts = %{"content" => Enum.flat_map(content, &part/1)}

    case message.reasoning_details do
      details when is_list(details) and details != [] ->
        Map.put(parts, "reasoning_details", json(details))

      _absent ->
        parts
    end
  end

  defp payload(_message), do: %{"content" => []}

  defp part(%ContentPart{type: :text, text: text}) when is_binary(text) do
    [%{"type" => "text", "text" => text}]
  end

  defp part(%ContentPart{type: :thinking, text: text}) when is_binary(text) do
    [%{"type" => "thinking", "text" => text}]
  end

  # ReqLLM 1.21 materializes complete JSON text as an object part, even for
  # stream_text. Dropping it erased valid public advice when the final message
  # replaced the streamed deltas. Serialize the public object at our boundary;
  # never substitute reasoning or relax the guide's semantic validation.
  defp part(%{type: :object, object: object}) when is_map(object) do
    [%{"type" => "text", "text" => JSON.encode!(object)}]
  end

  defp part(_other), do: []

  # req_llm speaks in atom-keyed maps; entries are JSON all the way down (see
  # `Lemieux.Entry`), so everything crossing this boundary is converted rather
  # than trusted to survive a round trip through a file.
  defp json(value) when is_struct(value), do: value |> Map.from_struct() |> json()

  defp json(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {to_string(key), json(inner)} end)
  end

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)

  defp json(value) when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    to_string(value)
  end

  defp json(value), do: value

  # Provider errors stay typed. Formatting belongs at the subscriber or
  # transcript presentation boundary; retaining the struct here is what lets
  # the session honor retry-after and recognize a context-window overflow.
  defdelegate message(error), to: ProviderError
end
