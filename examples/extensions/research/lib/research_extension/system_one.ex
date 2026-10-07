defmodule ResearchExtension.SystemOne do
  @moduledoc """
  Default source classifier for the research host: one typed `choice`
  question to whichever System One provider the person configured.

  A System One provider is any service that answers `POST /v1/systemone` —
  TypeSafe's hosted Jev model, an Ixway gateway, an open model on the
  person's own machine (Ollama serves the route). `lmx` declares providers
  once, under `"systemone_providers"` in its config file, and
  `Lemieux.CLI.SystemOne` resolves them; this module only builds the
  request. `provider:` selects one:

  - absent (or `"auto"`): the automatic choice from the lmx config file —
    TypeSafe when `JEV_API_KEY` or `systemone_providers.typesafe.api_key` is
    set, Ixway when its endpoint and a model are. Nothing configured is
    `:unavailable`, and discovery stays off, as it did when only a Jev key
    could switch it on.
  - a name: that entry of `"systemone_providers"`. A name that cannot be
    used (undeclared, no key, no model) is `{:error, sentence}`: the person
    asked for that provider, and quietly running without discovery would
    measure something they did not ask for. There is no fallback to another
    provider either — a person who pointed discovery at their own machine
    chose where the question goes.
  - a provider map, as `Lemieux.CLI.SystemOne.provider/3` returns it, for a
    host that resolves providers itself.

  The config file is the one `lmx` reads: `LMX_CONFIG=none` reads none (the
  automatic choice still sees `JEV_API_KEY`), unset reads
  `~/.lmx/config.json` if it exists, any other value names the file. Nothing
  is created or modified. A host can bypass all of this with its own
  `classify:` callback in `ResearchExtension.Discovery`.

  `api_key:` is refused rather than ignored: it used to be the TypeSafe key,
  and a host that still passes one would otherwise run against whatever the
  automatic choice found, or without discovery, and never be told.

  The request is the native wire contract (https://docs.typesafe.ai/api)
  over the existing Req dependency — no System One SDK, so a configured
  provider is enough on its own. Redirects and retries are disabled so one
  choice cannot forward a credential or spend more than one request. The
  answer must name the model that was asked for: TypeSafe and Ollama echo it,
  and an answer from another model is not the judgement the run records. The
  key lives only in the returned function's closure; no error string carries
  it, nor any part of the provider's reply.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.SystemOne

  # TypeSafe's provider leaves its model to whoever builds the client; this
  # is the one the research benches were qualified against.
  @typesafe_model "jev-1.13.0"
  @selected_by "the discovery provider: option"

  @typedoc "A native typed-question request in, `{:ok, %{answers, model, usage}}` out."
  @type classify :: (map() -> {:ok, map()} | {:error, String.t()})

  @doc """
  The classifier for `opts[:provider]` (see the module doc), or
  `:unavailable` when no provider was named and none is configured.

  `request:` replaces `Req.post/1`; tests capture the Req options with it.
  """
  @spec classifier(opts :: keyword()) :: {:ok, classify()} | :unavailable | {:error, String.t()}
  def classifier(opts) when is_list(opts) do
    with :ok <- refuse_api_key(opts),
         {:ok, provider} <- provider(Keyword.get(opts, :provider)),
         {:ok, provider} <- usable(provider) do
      request = Keyword.get(opts, :request, &Req.post/1)
      {:ok, fn question -> evaluate(question, provider, request) end}
    end
  end

  defp refuse_api_key(opts) do
    if Keyword.has_key?(opts, :api_key),
      do:
        {:error,
         "discovery no longer takes api_key:; select a System One provider with provider: " <>
           "(a name from systemone_providers, or a provider map), or set JEV_API_KEY"},
      else: :ok
  end

  defp provider(selection) when selection in [nil, "auto"] do
    with {:ok, config} <- config() do
      case SystemOne.provider(config, nil, selected_by: @selected_by) do
        {:ok, provider} -> {:ok, provider}
        {:unavailable, _reason} -> :unavailable
      end
    end
  end

  defp provider(name) when is_binary(name) do
    with {:ok, config} <- config() do
      case SystemOne.provider(config, name, selected_by: @selected_by) do
        {:ok, provider} -> {:ok, provider}
        {:unavailable, reason} -> unusable(reason)
      end
    end
  end

  defp provider(%{type: type, base_url: url} = provider)
       when type in [:typesafe, :endpoint] and is_binary(url),
       do: {:ok, provider}

  defp provider(_selection),
    do:
      {:error,
       "#{@selected_by} must be a provider name from systemone_providers or a " <>
         "Lemieux.CLI.SystemOne provider map"}

  defp config do
    case System.get_env("LMX_CONFIG") do
      "none" -> {:ok, nil}
      nil -> Config.load(Config.default_path(), optional: true)
      path -> Config.load(Path.expand(path), [])
    end
  end

  # What a request needs: an http(s) root, a model to name, and for TypeSafe
  # a key. A resolved provider always has them; a host's own map may not.
  defp usable(%{type: :typesafe} = provider) do
    if present?(Map.get(provider, :api_key)),
      do: reachable(Map.put(provider, :model, Map.get(provider, :model) || @typesafe_model)),
      else: unusable("the typesafe provider has no key")
  end

  defp usable(provider), do: reachable(provider)

  defp reachable(provider) do
    cond do
      not valid_base_url?(provider.base_url) ->
        unusable("the provider's base_url is not an http(s) root before /v1/systemone")

      not present?(Map.get(provider, :model)) ->
        unusable("the provider has no model")

      true ->
        {:ok, provider}
    end
  end

  defp unusable(reason), do: {:error, "System One discovery is unavailable: #{reason}."}

  # Credentials, a query or a fragment in the URL are refused: they would be
  # sent on the wire, or silently dropped when the path is appended.
  defp valid_base_url?(url) do
    match?(
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "",
      URI.new(url)
    )
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp evaluate(%{"state" => state, "questions" => questions}, provider, request)
       when is_map(questions) do
    [
      # The base URL may carry a path prefix (a vendor's account path, a
      # gateway mount); only a trailing slash is normalised.
      url: String.trim_trailing(provider.base_url, "/") <> "/v1/systemone",
      json: %{"state" => state, "questions" => questions, "model" => provider.model},
      redirect: false,
      retry: false,
      receive_timeout: 15_000,
      connect_options: [timeout: 5_000]
    ]
    |> Keyword.merge(credentials(provider))
    |> request.()
    |> response(provider.model)
  end

  defp evaluate(_question, _provider, _request), do: {:error, "System One request is invalid"}

  # The key travels as a bearer token unless the provider names the header
  # it wants it in; then it is one more header and no Authorization is sent.
  # A provider on the person's own machine often has no key at all.
  defp credentials(provider) do
    headers = Map.get(provider, :headers, %{})
    key = Map.get(provider, :api_key)
    header = Map.get(provider, :api_key_header)

    cond do
      not present?(key) -> [headers: headers]
      is_binary(header) -> [headers: Map.put(headers, header, key)]
      true -> [headers: headers, auth: {:bearer, key}]
    end
  end

  defp response({:ok, %Req.Response{status: 200, body: body}}, requested) do
    case body do
      %{"answers" => answers, "model" => ^requested} when is_map(answers) ->
        {:ok, Map.take(body, ~w(answers model usage))}

      %{"answers" => answers, "model" => model} when is_map(answers) and is_binary(model) ->
        {:error, "System One answered with a model other than the one requested"}

      _body ->
        {:error, "System One returned an invalid response"}
    end
  end

  defp response({:ok, %Req.Response{status: status}}, _requested) when status in 100..599,
    do: {:error, "System One returned HTTP #{status}"}

  defp response(_result, _requested), do: {:error, "System One transport failed"}
end
