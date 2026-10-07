defmodule LemieuxComputerUse.SystemOne do
  @moduledoc """
  System One classifier for the experimental computer-use extension: one
  `POST /v1/systemone` request per browser step, to the provider the host
  chose.

  A System One model answers typed questions about a state with calibrated
  probabilities. Here the state is the current page and the questions are
  the ones `LemieuxComputerUse.Decision` builds: which operation, and which
  offered target for each operation. Any service that speaks the route will
  do — TypeSafe's hosted Jev model, an Ixway gateway, an open model on the
  person's own machine (Ollama serves the route).

  ## Providers

  The classifier is given in one of two forms:

  - `provider:` describes it, in the shape `Lemieux.CLI.SystemOne.provider/3`
    resolves from `"systemone_providers"` in the lmx config file, which is
    how `mix lmx.browser` gets it: `%{name: "local", type: :endpoint,
    base_url: "http://127.0.0.1:11434", api_key: nil, api_key_header: nil,
    headers: %{}, model: "clef-flash"}`. `type: :typesafe` is TypeSafe's
    hosted service, through `SystemOneSDK.Providers.TypeSafe`, with a key
    required and `jev-1.13.0` as the default model. `type: :endpoint` is any
    other service, through `SystemOneSDK.Providers.Endpoint`, with a model
    required and a key only when one is given. `api_key_header` names the
    header the key travels in when the service takes no bearer token.
  - `client:` is a `%SystemOneSDK.Client{}` the host built itself. It wins
    over `provider:` and is never rebuilt.

  `timeout_ms:` bounds the request (default 15 seconds).

  With neither form there is no classifier, and `evaluate/2` says so. This
  module reads no environment variable and never falls back to TypeSafe: a
  person who pointed the browser at a model on their own machine chose
  where page content goes. A host that wants TypeSafe resolves it — the
  automatic choice of `Lemieux.CLI.SystemOne.provider/3` is TypeSafe when
  `JEV_API_KEY` is set. `api_key:` and `model:` are refused rather than
  ignored: they configured the TypeSafe-only client this module used to
  build, and a host still passing them would otherwise run against a
  provider it never chose, or against none, without being told.

  ## The request

  The questions go through SystemOneSDK's raw `system_one/4` rather than its
  semantic `evaluate/4`: `Decision.decode/4` validates the wire-shaped
  answers against the current observation itself, and the raw call returns
  them as they arrived. Keeping the questions portable is `Decision`'s job:
  every choice it sends has string descriptions and 2 to 26 options, the
  range System One servers other than TypeSafe's enforce. SDK retries are
  off and the transport (`LemieuxComputerUse.SystemOne.Transport`) follows
  no redirect, so a step costs one request and a key goes nowhere but the
  provider. The answer must name the model that was asked for: an answer
  from another model is not the judgement the run records.

  Errors are reduced to fixed strings before entering evidence, because SDK
  errors may contain provider bodies. No string carries a key or a URL.
  """

  alias LemieuxComputerUse.SystemOne.Transport
  alias SystemOneSDK.{Client, Error, SystemOneResponse}
  alias SystemOneSDK.Providers.{Endpoint, TypeSafe}

  @typesafe_model "jev-1.13.0"
  @default_timeout_ms 15_000
  @provider_types [:typesafe, :endpoint]
  @options [:provider, :client, :timeout_ms]

  @typedoc """
  A System One provider, as `Lemieux.CLI.SystemOne.provider/3` resolves it.
  `model` may be `nil` only for `type: :typesafe`.
  """
  @type provider :: %{
          required(:name) => String.t(),
          required(:type) => :typesafe | :endpoint,
          required(:base_url) => String.t(),
          optional(:api_key) => String.t() | nil,
          optional(:api_key_header) => String.t() | nil,
          optional(:headers) => %{optional(String.t()) => String.t()},
          optional(:model) => String.t() | nil
        }

  @doc """
  Asks the configured provider `request`'s questions about its state.

  Returns the answers, the model that gave them and its usage, or one of a
  fixed set of sentences. Raises `ArgumentError` for options this module
  does not take; `validate_options/1` reports them without raising.
  """
  @spec evaluate(request :: map(), opts :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def evaluate(request, opts \\ [])

  def evaluate(%{"state" => state, "questions" => questions}, opts)
      when is_map(questions) and is_list(opts) do
    case client(opts) do
      {:ok, client} -> ask(client, state, questions, opts)
      {:error, _sentence} = refused -> refused
    end
  end

  def evaluate(_request, opts) when is_list(opts) do
    validate_options!(opts)
    {:error, "System One request is invalid"}
  end

  # Only this module's own sentences leave it: a provider's error, string or
  # not, may quote its body.
  defp ask(client, state, questions, opts) do
    model = client.default_model

    with {:ok, %SystemOneResponse{raw: raw}} <-
           SystemOneSDK.system_one(client, state, questions,
             model: model,
             retry: false,
             timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
           ),
         # The raw call does not apply the client's response contract, so the
         # model is checked here.
         %{"answers" => answers, "model" => ^model} when is_map(answers) <- raw do
      {:ok, Map.take(raw, ~w(answers model usage))}
    else
      {:error, %Error{} = error} -> diagnostic(error)
      {:error, _} -> {:error, "System One transport failed"}
      _ -> {:error, "System One returned an invalid response"}
    end
  rescue
    error in Error -> diagnostic(error)
  end

  @doc """
  Builds the SDK client `opts` select, without contacting the provider.

  A provider is usable when a request to it could be built: an http(s) root
  without credentials, query or fragment, a model to name, and a key for
  TypeSafe and for an Ixway gateway (a gateway authenticates its callers,
  so Ixway without its key is not a keyless endpoint). Raises
  `ArgumentError` for options this module does not take, as `evaluate/2`
  does.
  """
  @spec client(opts :: keyword()) :: {:ok, Client.t()} | {:error, String.t()}
  def client(opts) when is_list(opts) do
    validate_options!(opts)

    case {Keyword.fetch(opts, :client), Keyword.get(opts, :provider)} do
      {{:ok, %Client{} = client}, _provider} -> {:ok, client}
      {{:ok, _invalid}, _provider} -> {:error, "System One client is invalid"}
      {:error, nil} -> {:error, "no System One provider is configured"}
      {:error, provider} -> provider |> usable() |> build(opts)
    end
  end

  @doc """
  The name of the configured provider for reports: the provider's own name,
  `"custom"` for a host's client, `nil` for none. Never a key or a URL.
  """
  @spec provider_name(opts :: keyword()) :: String.t() | nil
  def provider_name(opts) when is_list(opts) do
    case {Keyword.get(opts, :client), Keyword.get(opts, :provider)} do
      {%Client{}, _provider} -> "custom"
      {nil, %{name: name}} when is_binary(name) -> name
      _none -> nil
    end
  end

  @doc """
  Checks `opts` without building anything: `:ok`, or a sentence naming the
  option that is wrong and where its value now goes.
  """
  @spec validate_options(opts :: term()) :: :ok | {:error, String.t()}
  def validate_options(opts) do
    validate_options!(opts)
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  # The options from before `provider:` existed, each named with where its
  # value now goes.
  @removed_options [
    api_key: "the key is provider:'s api_key",
    model: "the model is provider:'s model, or the client's default"
  ]

  defp validate_options!(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "System One options must be a keyword list")

    case Enum.find(@removed_options, fn {key, _where} -> Keyword.has_key?(opts, key) end) do
      nil ->
        :ok

      {key, where} ->
        raise ArgumentError,
              "System One option #{inspect(key)} was removed when the classifier began taking " <>
                "provider: (a System One provider map) or client:; #{where}"
    end

    unless Keyword.keys(opts) -- @options == [],
      do:
        raise(
          ArgumentError,
          "System One options are provider:, client: and timeout_ms:; " <>
            "#{inspect(Keyword.keys(opts) -- @options)} is not one of them"
        )

    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)

    unless is_integer(timeout) and timeout > 0,
      do: raise(ArgumentError, "System One option :timeout_ms must be a positive integer")

    validate_provider!(Keyword.get(opts, :provider))
  end

  defp validate_provider!(nil), do: :ok

  defp validate_provider!(%{name: name, type: type, base_url: url} = provider)
       when is_binary(name) and type in @provider_types and is_binary(url) do
    checks = [
      {key_or_absent?(Map.get(provider, :api_key)), "api_key must be a string or nil"},
      {is_map(Map.get(provider, :headers, %{})), "headers must be a map"},
      {key_or_absent?(Map.get(provider, :api_key_header)),
       "api_key_header must be a header name or nil"},
      {key_or_absent?(Map.get(provider, :model)), "model must be a string or nil"}
    ]

    case Enum.find(checks, &(not elem(&1, 0))) do
      nil -> :ok
      {false, what} -> raise ArgumentError, "System One provider's #{what}"
    end
  end

  defp validate_provider!(_provider) do
    raise ArgumentError,
          "System One provider: must be a map with name, type (:typesafe or :endpoint), " <>
            "base_url, api_key, api_key_header, headers and model"
  end

  defp usable(%{type: :typesafe} = provider) do
    if present?(Map.get(provider, :api_key)),
      do: reachable(Map.put(provider, :model, Map.get(provider, :model) || @typesafe_model)),
      else: :unusable
  end

  defp usable(%{name: "ixway"} = provider),
    do: if(present?(Map.get(provider, :api_key)), do: reachable(provider), else: :unusable)

  defp usable(provider), do: reachable(provider)

  defp reachable(provider) do
    if present?(Map.get(provider, :model)) and valid_base_url?(provider.base_url),
      do: {:ok, %{provider | model: String.trim(provider.model)}},
      else: :unusable
  end

  defp build(:unusable, _opts), do: {:error, "System One provider is unusable"}

  # The checks above are the ones a resolved provider can fail; the SDK
  # applies its own when it builds the client, and a refusal there is the
  # same unusable provider, not a crash in the browser run.
  defp build({:ok, provider}, opts) do
    {api_key, headers} = credential(provider)

    {:ok,
     SystemOneSDK.new_client(
       provider: sdk_provider(provider.type),
       api_key: api_key,
       base_url: String.trim(provider.base_url),
       model: provider.model,
       retry: false,
       timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
       headers: headers,
       transport: Transport,
       transport_opts: [],
       response_contract: [allowed_models: [provider.model]]
     )}
  rescue
    _error in Error -> {:error, "System One provider is unusable"}
  end

  defp sdk_provider(:typesafe), do: TypeSafe
  defp sdk_provider(:endpoint), do: Endpoint

  # The key travels as a bearer token unless the provider names the header
  # it wants it in; then it is one more header, and no Authorization is sent.
  defp credential(provider) do
    headers = Map.get(provider, :headers, %{})

    case {trimmed(Map.get(provider, :api_key)), Map.get(provider, :api_key_header)} do
      {nil, _header} -> {nil, headers}
      {key, nil} -> {key, headers}
      {key, header} -> {nil, Map.put(headers, header, key)}
    end
  end

  defp trimmed(key) when is_binary(key) do
    case String.trim(key) do
      "" -> nil
      key -> key
    end
  end

  defp trimmed(_key), do: nil

  defp key_or_absent?(value), do: is_nil(value) or is_binary(value)

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  # The root before `/v1/systemone`. A path prefix is allowed, as the SDK
  # allows it. Credentials, a query or a fragment in the URL are refused:
  # they would be sent on the wire or silently dropped.
  defp valid_base_url?(url) when is_binary(url) do
    case URI.new(String.trim(url)) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  defp diagnostic(%Error{type: type}) when type in [:response_validation, :response_contract],
    do: {:error, "System One returned an invalid response"}

  defp diagnostic(%Error{type: :invalid_request}), do: {:error, "System One request is invalid"}

  defp diagnostic(%Error{type: :configuration}),
    do: {:error, "System One provider is unusable"}

  defp diagnostic(%Error{status: status}) when is_integer(status) and status in 100..599,
    do: {:error, "System One returned HTTP #{status}"}

  defp diagnostic(%Error{}), do: {:error, "System One transport failed"}
end
