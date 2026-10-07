defmodule Lemieux.Ixway do
  @moduledoc """
  Optional first-party Ixway discovery and inference policy for ReqLLM.

  `new/1` builds private host state without I/O; `provider/2` wraps it in a
  `Lemieux.Providers.ReqLLM` that routes through it. This module is the
  shipped `Lemieux.Provider.Route`: the adapter asks it which models exist,
  where a request goes and what the response disclosed, and never names it.
  `discover/1` reads the public instance descriptor and key-authenticated
  model catalogue, without calling a model. Rebuild/discover the connection
  after a key or profile change or reconnect.

  Failures on this side of a request are `Lemieux.Ixway.Error` values:
  typed, so a host matches on `reason`, and self-describing, so
  `Lemieux.Provider.Error.message/1` renders the sentence without knowing
  this gateway exists.

  Models use `ixway:ID`, preserving operator profile and alias identities.
  `ixway:@default` is a selection instruction; `select_model/2` resolves it
  before a CLI session persists its configuration. Defaults come from the
  authenticated policy, never from array order or a guessed profile name.

  The host-facing half of that — readying the catalogue before a model is
  chosen, resolving the default — is `c:Lemieux.Provider.Route.ready/1` and
  `c:Lemieux.Provider.Route.default_model/1`, implemented here, so that
  `Lemieux.Provider.Route.prepare/2` prepares this route exactly as it
  prepares one an extension registered (`Lemieux.Extension.Routes`). `lmx`
  registers this gateway under the name `ixway` through `Lemieux.CLI.Routes`
  like any other route; `prepare/2` and `discover_provider/1` remain as the
  shorthand an embedding host already calls.

  This module does not implement an inference protocol. ReqLLM's OpenAI chat
  transport owns encoding, tools, structured output, streaming and errors.
  An inline model pins that grammar even for IDs such as `gpt-5`, which would
  otherwise silently select ReqLLM's Responses transport. Ixway owns upstream
  selection and credentials. No direct-provider fallback is permitted.

  Catalogue limits describe the smallest target ceiling. Catalogue entries
  are not entitlement or availability guarantees; gateway admission remains
  authoritative. Prices cannot be inferred from an alias or the requested
  concrete model because policy can route elsewhere. Local monetary budgets
  therefore fail closed on unknown estimates; use Ixway key budgets and
  routing cost constraints for managed pools.
  """

  alias Lemieux.Ixway.LogFilter
  alias Lemieux.Ixway.Receipt
  alias Lemieux.ModelSpec
  alias Lemieux.Provider.Route
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Request
  alias ReqLLM.StreamResponse.MetadataHandle

  @behaviour Lemieux.Provider.Route

  defmodule Error do
    @moduledoc """
    A failure on the gateway side of a request — discovery, credentials,
    selection or capability — never inference itself, which arrives as
    `req_llm`'s own typed exceptions.

    Typed, so policy matches on `reason`; an exception, so the sentence a
    person reads comes from `message/1`. These sentences lived in
    `Lemieux.Provider.Error` before, one clause per reason, which made the
    module that is meant to know no vendor the one every new gateway reason
    had to edit. `Lemieux.Provider.Error.message/1` now renders this like any
    other exception and classifies it as `:other`: none of these carry an
    HTTP status or a retry-after, and a discovery request that failed is not
    one a session would send again.
    """

    defexception [:reason]

    @type reason ::
            :api_key_required
            | :model_choice_required
            | :model_not_available
            | :tools_unsupported
            | :connection_failed
            | :credential_log_filter_unavailable
            | :incompatible_instance
            | :provider_error_redacted
            | :invalid_catalogue
            | {:http_status, non_neg_integer()}

    @type t :: %__MODULE__{reason: reason()}

    @impl Exception
    def message(%__MODULE__{reason: :api_key_required}),
      do: "Ixway requires IXWAY_API_KEY (a gateway model key)."

    def message(%__MODULE__{reason: :model_choice_required}),
      do:
        "Ixway has no available compatible default. Choose an advertised model with --model ixway:ID."

    def message(%__MODULE__{reason: :model_not_available}),
      do:
        "Choose an ixway:ID advertised by this gateway key for OpenAI chat. Direct-provider models are unavailable in Ixway mode."

    def message(%__MODULE__{reason: :tools_unsupported}),
      do: "This Ixway model does not support the session's tools. Choose a tool-capable profile."

    def message(%__MODULE__{reason: :connection_failed}),
      do: "Cannot reach Ixway discovery. Check the instance URL and network connection."

    def message(%__MODULE__{reason: :credential_log_filter_unavailable}),
      do: "Cannot protect Ixway response credentials in provider logs."

    def message(%__MODULE__{reason: :provider_error_redacted}),
      do: "Ixway inference failed; the provider error contained private response credentials."

    def message(%__MODULE__{reason: {:http_status, status}}),
      do: "Ixway discovery returned HTTP #{status}. Check the gateway key and access policy."

    def message(%__MODULE__{reason: reason}) when is_atom(reason),
      do: "Ixway discovery failed: #{reason}."

    def message(%__MODULE__{reason: reason}), do: "Ixway discovery failed: #{inspect(reason)}."
  end

  @derive {Inspect, only: []}
  defstruct [:endpoint, :api_key, :models, :client_policy, headers: [], discovery_options: []]

  @type t :: %__MODULE__{
          endpoint: String.t(),
          api_key: String.t() | nil,
          models: [map()] | nil,
          client_policy: map() | nil,
          headers: [{String.t(), String.t()}],
          discovery_options: keyword()
        }

  @doc """
  Builds runtime policy. Requires an instance origin (`:endpoint`, without
  `/v1`); accepts `:api_key`, `:headers` for Ixway constraints/attribution and
  `:discovery_options` for Req transport options. No ambient key is read by
  this library API. The CLI explicitly supplies `IXWAY_API_KEY`.
  """
  @spec new(options :: keyword() | t()) :: t()
  def new(%__MODULE__{} = connection), do: connection

  def new(options) when is_list(options) do
    endpoint = Keyword.fetch!(options, :endpoint)

    unless valid_endpoint?(endpoint),
      do:
        raise(
          ArgumentError,
          "Ixway endpoint must be an http(s) origin without /v1, credentials, query or fragment"
        )

    headers = Keyword.get(options, :headers, [])
    validate_headers!(headers)

    struct!(__MODULE__, Keyword.put(options, :endpoint, String.trim_trailing(endpoint, "/")))
  end

  @doc "Checks whether a value is an unambiguous Ixway instance origin."
  @spec valid_endpoint?(value :: term()) :: boolean()
  def valid_endpoint?(value) when is_binary(value) do
    case URI.new(value) do
      {:ok,
       %URI{scheme: scheme, host: host, path: path, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        true

      _ ->
        false
    end
  end

  def valid_endpoint?(_value), do: false

  @doc "Refreshes the key-scoped catalogue through non-billable GET requests."
  @spec discover(connection :: t()) :: {:ok, t()} | {:error, term()}
  def discover(%__MODULE__{} = connection) do
    with :ok <- check_key(connection),
         {:ok, instance} <- get(connection, "/.well-known/ixway", false),
         :ok <- instance_contract(instance),
         {:ok, catalogue} <- get(connection, "/v1/models", true),
         {:ok, models} <- catalogue_models(catalogue) do
      {:ok, %{connection | models: models, client_policy: catalogue["ixway_client"]}}
    end
  end

  @doc """
  Discovers the catalogue when the connection has none, and returns a
  connection that has one unchanged: `c:Lemieux.Provider.Route.ready/1`.
  """
  @impl Lemieux.Provider.Route
  @spec ready(connection :: t()) :: {:ok, t()} | {:error, term()}
  def ready(%__MODULE__{models: nil} = connection), do: discover(connection)
  def ready(%__MODULE__{} = connection), do: {:ok, connection}

  @doc "Loads a provider's Ixway catalogue without selecting a model."
  @spec discover_provider(provider :: Lemieux.Provider.t()) ::
          {:ok, Lemieux.Provider.t()} | {:error, term()}
  def discover_provider({module, %{route: {__MODULE__, connection}} = state}) do
    with {:ok, connection} <- ready(connection) do
      {:ok, {module, %{state | route: {__MODULE__, connection}}}}
    end
  end

  @doc "Returns compatible model specifications, optionally scoped to the Ixway provider."
  @spec available_models(connection :: t(), options :: keyword()) :: [String.t()]
  @impl Lemieux.Provider.Route
  def available_models(connection, options) do
    with true <- Keyword.get(options, :provider) in [nil, :ixway, "ixway"],
         true <- Keyword.get(options, :scope) in [nil, :all, :ixway, "ixway"],
         {:ok, connection} <- ready(connection) do
      connection.models
      |> Enum.reject(&unsupported?(&1, Keyword.get(options, :require, [])))
      |> Enum.map(&ModelSpec.join("ixway", &1["id"]))
    else
      _ -> []
    end
  end

  @doc "Returns the gateway's routing labels for picker display only."
  @impl Lemieux.Provider.Route
  @spec model_metadata(connection :: t()) :: %{optional(String.t()) => map()}
  def model_metadata(%__MODULE__{models: models}) when is_list(models) do
    Map.new(models, fn entry ->
      id = entry["id"]
      provider = entry["ixway_provider"]

      route =
        case String.split(id, ":", parts: 2) do
          [^provider, base] when is_binary(provider) and base != "" -> provider
          _other -> "Automatic"
        end

      metadata = %{kind: entry["ixway_model_kind"], route: route}

      metadata =
        case entry["ixway_release_date"] do
          date when is_binary(date) -> Map.put(metadata, :release_date, date)
          _missing -> metadata
        end

      {ModelSpec.join("ixway", id), metadata}
    end)
  end

  def model_metadata(%__MODULE__{}), do: %{}

  @doc "Resolves an explicit model or the authenticated default; never guesses a profile."
  @spec select_model(connection :: t(), spec :: String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def select_model(connection, "ixway:@default") do
    with {:ok, connection} <- ready(connection), do: default_model(connection)
  end

  def select_model(connection, spec) do
    with {:ok, _entry} <- entry(connection, spec), do: {:ok, spec}
  end

  @doc """
  The gateway's advertised default, `ixway:ID`:
  `c:Lemieux.Provider.Route.default_model/1`.

  From the authenticated key policy, else the one catalogue entry marked as
  the default for OpenAI chat; an unavailable configured default or an
  ambiguous recommendation is `:model_choice_required`, never a guess.
  """
  @impl Lemieux.Provider.Route
  @spec default_model(connection :: t()) :: {:ok, String.t()} | {:error, term()}
  def default_model(connection) do
    with {:ok, connection} <- ready(connection),
         id when is_binary(id) <- default_id(connection),
         {:ok, _entry} <- entry(connection, ModelSpec.join("ixway", id)) do
      {:ok, ModelSpec.join("ixway", id)}
    else
      {:error, _} = error -> error
      _ -> error(:model_choice_required)
    end
  end

  @doc false
  @spec entry(connection :: t(), spec :: String.t()) :: {:ok, map()} | {:error, term()}
  def entry(connection, "ixway:" <> id) do
    with {:ok, connection} <- ready(connection),
         %{} = entry <- Enum.find(connection.models, &(&1["id"] == id)) do
      {:ok, entry}
    else
      nil -> error(:model_not_available)
      {:error, _} = error -> error
    end
  end

  def entry(_connection, _spec), do: error(:model_not_available)

  @impl Lemieux.Provider.Route
  @spec validate_model(connection :: t(), spec :: String.t(), tools :: [term()]) ::
          :ok | {:error, term()}
  def validate_model(connection, spec, tools) do
    with :ok <- check_key(connection),
         {:ok, entry} <- entry(connection, spec) do
      if tools != [] and unsupported?(entry, [:tools]),
        do: error(:tools_unsupported),
        else: :ok
    end
  end

  @impl Lemieux.Provider.Route
  @spec context_window(connection :: t(), spec :: String.t()) :: pos_integer() | nil
  def context_window(connection, spec) do
    with {:ok, entry} <- entry(connection, spec),
         limit when is_integer(limit) and limit > 0 <- entry["max_input_tokens"] do
      limit
    else
      _ -> nil
    end
  end

  # The catalogue publishes the levels an entry accepts, least effort first, and for
  # an alias that is the intersection across every target it may route to — the same
  # conservatism `context_window/2` gets from the smallest ceiling. An absent key
  # means the gateway is not saying, which is what an older instance and a family
  # with no effort scale both give; both become no menu rather than a menu invented
  # here. Advisory, like every catalogue field: gateway admission stays
  # authoritative.
  @impl Lemieux.Provider.Route
  @spec reasoning_efforts(connection :: t(), spec :: String.t()) :: [String.t()]
  def reasoning_efforts(connection, spec) do
    with {:ok, entry} <- entry(connection, spec),
         values when is_list(values) <- entry["ixway_reasoning_effort"] do
      Enum.filter(values, &(is_binary(&1) and &1 != ""))
    else
      _ -> []
    end
  end

  # Prices cannot be inferred from an alias or the requested concrete model,
  # because policy can route elsewhere. `nil` is the honest answer, and a local
  # cost cap fails closed on it rather than counting the request as free.
  @impl Lemieux.Provider.Route
  @spec estimate_cost(connection :: t(), request :: Request.t()) :: nil
  def estimate_cost(_connection, _request), do: nil

  @impl Lemieux.Provider.Route
  @spec target(connection :: t(), request :: Request.t(), options :: keyword()) ::
          {:ok, {LLMDB.Model.t(), keyword()}} | {:error, term()}
  def target(connection, request, options) do
    with :ok <- validate_model(connection, request.model, request.tools),
         :ok <- protect_logs(),
         {:ok, model} <-
           ReqLLM.model(%{
             provider: :openai,
             id: ModelSpec.model_id(request.model),
             extra: %{wire: %{protocol: "openai_chat"}}
           }) do
      # Generation params are durable/user-controlled; they cannot replace the
      # host's destination, key, headers, authentication or transport options.
      options =
        Keyword.take(options, [
          :temperature,
          :max_tokens,
          :top_p,
          :reasoning_effort,
          :receive_timeout,
          :stream_idle_timeout,
          :total_timeout,
          :max_retries,
          :propagate_trace_context
        ])

      {:ok,
       {model,
        Keyword.put_new(options, :propagate_trace_context, true) ++
          [
            base_url: connection.endpoint <> "/v1",
            api_key: connection.api_key,
            req_http_options: [headers: request_headers(connection, request)]
          ]}}
    end
  end

  defp protect_logs do
    case LogFilter.install() do
      :ok -> :ok
      {:error, _reason} -> error(:credential_log_filter_unavailable)
    end
  end

  @doc """
  Discovers a provider connection and resolves a startup selection without
  inference: `Lemieux.Provider.Route.prepare/2` over this route, kept as the
  shorthand a host that holds an Ixway provider calls. Any other provider is
  returned as it is.
  """
  @spec prepare(provider :: Lemieux.Provider.t(), model :: String.t()) ::
          {:ok, Lemieux.Provider.t(), String.t()} | {:error, term()}
  def prepare({module, %{route: {__MODULE__, connection}} = state}, model) do
    with {:ok, route, model} <- Route.prepare({__MODULE__, connection}, model) do
      {:ok, {module, %{state | route: route}}, model}
    end
  end

  def prepare(provider, model), do: {:ok, provider, model}

  @doc """
  Builds a `Lemieux.Providers.ReqLLM` routed through this gateway.

  `connection` is a connection from `new/1` or its options; `options` are the
  adapter's own, such as `:receive_timeout`, and may not include direct
  provider credentials or URLs. This is the sugar the adapter's former
  `new(ixway: connection)` provided, moved here so the adapter need not know
  this module's name: the adapter is the thing that must not depend on any
  one gateway, and this module already depends on the adapter.
  """
  @spec provider(connection :: t() | keyword(), options :: keyword()) :: Lemieux.Provider.t()
  def provider(connection, options \\ []) when is_list(options) do
    Adapter.new(Keyword.put(options, :route, {__MODULE__, new(connection)}))
  end

  @doc "The connection a provider routes through, or `nil` for one that does not route here."
  @spec connection(provider :: Lemieux.Provider.t()) :: t() | nil
  def connection({_module, %{route: {__MODULE__, %__MODULE__{} = connection}}}), do: connection
  def connection(_provider), do: nil

  @impl Lemieux.Provider.Route
  @spec observe_stream(
          connection :: t(),
          response :: ReqLLM.StreamResponse.t(),
          reference :: reference()
        ) :: ReqLLM.StreamResponse.t()
  def observe_stream(_connection, response, reference) do
    # Read the public metadata handle after consumption, before process_stream
    # closes it. No SSE parser or second consumer competes with ReqLLM.
    tail =
      Stream.flat_map([:complete], fn _ ->
        metadata = MetadataHandle.await(response.metadata_handle)
        headers = metadata[:headers] || []
        send(self(), {reference, disclosure(headers)})
        send(self(), {reference, :receipt, Receipt.headers(headers)})
        []
      end)

    %{response | stream: Stream.concat(response.stream, tail)}
  end

  @impl Lemieux.Provider.Route
  @spec finish_stream(
          connection :: t(),
          result :: Lemieux.Provider.Route.result(),
          reference :: reference()
        ) :: Lemieux.Provider.Route.result()
  def finish_stream(connection, result, reference) do
    disclosure =
      receive do
        {^reference, headers} -> headers
      after
        0 -> %{}
      end

    result |> sanitize_stream_error(connection) |> attach_disclosure(disclosure)
  end

  defp sanitize_stream_error(
         {:error, %ReqLLM.Error.API.Stream{cause: %ReqLLM.Error.API.Request{} = cause} = stream},
         connection
       ) do
    {cause, secrets} = strip_private_headers(cause, connection.api_key)
    stream = %{stream | cause: cause, reason: "Stream failed: #{inspect(cause)}"}
    private_error_result(stream, secrets)
  end

  defp sanitize_stream_error({:error, %{headers: headers} = reason}, connection)
       when is_list(headers) do
    {reason, secrets} = strip_private_headers(reason, connection.api_key)
    private_error_result(reason, secrets)
  end

  defp sanitize_stream_error({:error, reason}, connection),
    do: private_error_result(reason, [connection.api_key])

  defp sanitize_stream_error(result, _connection), do: result

  defp strip_private_headers(%{headers: headers} = reason, key) do
    headers = List.wrap(headers)

    private =
      Enum.filter(headers, fn
        {name, _value} when is_binary(name) ->
          String.downcase(name) in ~w(x-ixway-key x-ixway-receipt-url x-ixway-receipt-token)

        _ ->
          false
      end)

    {Map.put(reason, :headers, headers -- private), [key | Enum.map(private, &elem(&1, 1))]}
  end

  defp private_error_result(reason, secrets) do
    if Enum.any?(
         secrets,
         &(is_binary(&1) and &1 != "" and String.contains?(inspect(reason), &1))
       ),
       do: error(:provider_error_redacted),
       else: {:error, reason}
  end

  @impl Lemieux.Provider.Route
  @spec after_stream(connection :: t(), request :: Request.t(), reference :: reference()) :: :ok
  def after_stream(connection, request, reference) do
    headers =
      receive do
        {^reference, :receipt, headers} -> headers
      after
        0 -> %{}
      end

    Receipt.start(connection, headers, request.context)
  end

  # The requested identity stays the transcript's model; what actually served
  # it is recorded beside the message under this route's own key, so a reader
  # can tell the two apart later.
  @impl Lemieux.Provider.Route
  @spec annotate_message(connection :: t(), message :: map(), response :: ReqLLM.Response.t()) ::
          map()
  def annotate_message(_connection, message, response),
    do: Map.put(message, "ixway", response.provider_meta[:ixway] || %{})

  defp attach_disclosure({:ok, result}, disclosure) do
    usage =
      if result.usage do
        result.usage
        |> Map.drop([
          :cost,
          :total_cost,
          :cost_usd,
          :input_cost,
          :output_cost,
          "cost",
          "total_cost",
          "cost_usd",
          "input_cost",
          "output_cost"
        ])
        |> Map.put(:ixway, disclosure)
      end

    {:ok,
     %{result | usage: usage, provider_meta: Map.put(result.provider_meta, :ixway, disclosure)}}
  end

  defp attach_disclosure(error, _disclosure), do: error

  defp disclosure(headers) do
    allowed =
      ~w(session-id resolved-model resolved-backend policy resolution-reason decision-id request-id)

    Map.new(
      Enum.flat_map(headers, fn {name, value} ->
        name = String.downcase(name)
        key = String.replace_prefix(name, "x-ixway-", "")

        if String.starts_with?(name, "x-ixway-") and key in allowed,
          do: [{String.replace(key, "-", "_"), value}],
          else: []
      end)
    )
  end

  defp request_headers(connection, request) do
    headers =
      [{"user-agent", "Lemieux-Ixway/1"}, {"x-ixway-application", "lemieux"}] ++
        connection.headers

    headers = if request.tools == [], do: headers, else: require_tools(headers)

    # `:session_id` is the conversation and carries the *root* on a child, so a
    # delegated actor lands inside the session that spawned it rather than beside it.
    # A host may explicitly supply x-ixway-session-id for a larger experiment
    # (ixbench does this for exact ledger attribution). Keep that host-owned
    # join key while x-ixway-conversation-id still names Lemieux's own root.
    # `:agent_id` and `:parent_agent_id` are what make a subagent visible as a second
    # actor at all: without them a gateway sees one agent making more requests.
    Enum.reduce(
      [
        session_id: "x-ixway-session-id",
        session_id: "x-ixway-conversation-id",
        agent_id: "x-ixway-agent-id",
        parent_agent_id: "x-ixway-parent-agent-id"
      ],
      headers,
      fn {key, header}, acc ->
        case Map.get(request.context, key) do
          value when is_binary(value) ->
            put_context_header(acc, header, value)

          _ ->
            acc
        end
      end
    )
  end

  defp put_context_header(headers, "x-ixway-session-id" = name, value) do
    if List.keymember?(headers, name, 0),
      do: headers,
      else: List.keystore(headers, name, 0, {name, value})
  end

  defp put_context_header(headers, name, value),
    do: List.keystore(headers, name, 0, {name, value})

  defp require_tools(headers) do
    existing = headers |> List.keyfind("x-ixway-required-capabilities", 0, {nil, ""}) |> elem(1)
    required = String.split(existing, ",", trim: true) |> Enum.map(&String.trim/1)

    List.keystore(
      headers,
      "x-ixway-required-capabilities",
      0,
      {"x-ixway-required-capabilities", Enum.join(Enum.uniq(required ++ ["tools"]), ",")}
    )
  end

  # `:require` is a keyword list everywhere it is produced, and this read it as a
  # bare list of names — which is only what the one internal caller below passes.
  # `to_string({:chat, true})` then raised, and because model discovery runs while
  # the TUI is starting, an Ixway-configured host could not open a session at all.
  # Both shapes are accepted, and a capability marked `false` is not required rather
  # than required to be absent.
  defp unsupported?(entry, requirements) do
    requirements
    |> Enum.flat_map(&required_capability/1)
    |> Enum.any?(fn capability ->
      get_in(entry, ["ixway_capabilities", capability, "status"]) == "unsupported"
    end)
  end

  defp required_capability({_capability, false}), do: []
  defp required_capability({capability, _required}), do: [to_string(capability)]
  defp required_capability(capability), do: [to_string(capability)]

  defp error(reason), do: {:error, %Error{reason: reason}}

  defp check_key(%{api_key: key}) when is_binary(key) and byte_size(key) > 0, do: :ok
  defp check_key(_connection), do: error(:api_key_required)

  defp get(connection, path, authenticated?) do
    headers = [{"user-agent", "Lemieux-Ixway/1"}]

    headers =
      if authenticated?,
        do: [{"authorization", "Bearer " <> connection.api_key} | headers],
        else: headers

    options =
      Keyword.merge(connection.discovery_options,
        url: connection.endpoint <> path,
        headers: headers,
        redirect: false,
        retry: false,
        receive_timeout: 10_000
      )

    case Req.get(options) do
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> error({:http_status, status})
      {:error, _error} -> error(:connection_failed)
    end
  end

  defp instance_contract(%{"product" => "ixway", "ingress_dialects" => %{"openai_chat" => _}}),
    do: :ok

  defp instance_contract(_instance), do: error(:incompatible_instance)

  defp catalogue_models(%{"data" => entries}) when is_list(entries) do
    if Enum.all?(entries, &valid_entry?/1) do
      {:ok, Enum.filter(entries, &("openai_chat" in Map.get(&1, "ixway_ingress_dialects", [])))}
    else
      error(:invalid_catalogue)
    end
  end

  defp catalogue_models(_catalogue), do: error(:invalid_catalogue)

  defp valid_entry?(%{"id" => id, "ixway_ingress_dialects" => dialects} = entry)
       when is_binary(id) and id != "" and is_list(dialects) do
    not String.contains?(id, "*") and id != "@default" and
      is_list(Map.get(entry, "ixway_default_for", [])) and valid_capabilities?(entry)
  end

  defp valid_entry?(_entry), do: false

  defp valid_capabilities?(entry) do
    case Map.get(entry, "ixway_capabilities", %{}) do
      capabilities when is_map(capabilities) ->
        Enum.all?(capabilities, fn {_name, value} -> is_map(value) end)

      _ ->
        false
    end
  end

  defp default_id(%{
         client_policy: %{"default_profile" => %{"status" => "available", "id" => id}}
       }),
       do: id

  defp default_id(%{client_policy: %{"default_profile" => %{"status" => "unavailable"}}}), do: nil

  defp default_id(connection) do
    case Enum.filter(connection.models, &("openai_chat" in Map.get(&1, "ixway_default_for", []))) do
      [entry] -> entry["id"]
      _ -> nil
    end
  end

  defp validate_headers!(headers) do
    unless is_list(headers) and Enum.all?(headers, &valid_header?/1),
      do:
        raise(
          ArgumentError,
          "Ixway headers must be lowercase x-ixway-* or W3C trace headers without line breaks"
        )
  end

  defp valid_header?({name, value}) when is_binary(name) and is_binary(value) do
    (String.starts_with?(name, "x-ixway-") or name in ["traceparent", "tracestate"]) and
      name != "x-ixway-key" and name == String.downcase(name) and
      not String.contains?(name <> value, ["\r", "\n"])
  end

  defp valid_header?(_header), do: false
end
