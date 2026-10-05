defmodule Lemieux.MCP.Auth.Discovery do
  @moduledoc """
  Getting from a refused request to an authorization server.

  Two hops. The MCP server's **protected resource metadata** (RFC 9728) names
  its authorization servers; the authorization server's own **metadata**
  (RFC 8414, or OpenID Connect discovery) names the endpoints to talk to. Both
  hops are probes rather than single fetches, because both have more than one
  place the answer is allowed to be.

  ## Why the probes have several steps

  Measured against real servers, and each step earns its place:

    * **A challenge need not name `resource_metadata`.** Atlassian's does not:
      it is `Bearer realm="OAuth", error="invalid_token", ...` and nothing
      else, so the well-known URIs are the only way in. They are tried
      path-first then root, per RFC 9728.
    * **A server may publish none of it.** Atlassian, again — nothing at either
      well-known URI either, so it implements neither of the two mechanisms the
      specification says a server must implement one of. `from_origin/1` is the
      accommodation, and says why it is safe.
    * **GitHub's issuer has a path component** — `https://github.com/login/oauth`.
      Its metadata is at
      `https://github.com/.well-known/oauth-authorization-server/login/oauth`:
      the suffix is *inserted* after the host, not appended to the path.
      Appending, which is the obvious thing to write, gets a 404 from the
      largest forge there is.

  Four of the five servers this was measured against are reached end to end by
  the code as written; the fifth is Atlassian, reached by the accommodation.

  ## Two validations that are not optional

  **The issuer must match.** A metadata document fetched from
  `https://attacker.example/...` that claims `"issuer": "https://honest.example"`
  is rejected. Without that check, discovery is a redirect an attacker
  controls, and every later validation is built on it.

  **PKCE must be advertised.** OAuth 2.1 defines no way to ask whether a server
  supports PKCE, so `code_challenge_methods_supported` is the only signal there
  is, and the specification says a client **must** refuse to proceed when it is
  absent. `S256` specifically: two of the eight servers measured also offer
  `plain`, and taking the first one advertised is a silent downgrade.
  """

  require Logger

  alias Lemieux.MCP.Auth.Challenge

  @resource_suffix "/.well-known/oauth-protected-resource"

  @typedoc "What the MCP server said about itself."
  @type resource :: %{
          resource: String.t(),
          issuer: String.t(),
          scopes_supported: [String.t()]
        }

  @doc """
  The URLs that might hold an MCP server's protected resource metadata, in the
  order to try them.

  A challenge that names one is believed and is the only candidate — the
  specification says to use it when present. Otherwise the well-known URIs are
  constructed from the server's own URL.
  """
  @spec resource_metadata_urls(mcp_url :: String.t(), challenge :: Challenge.t()) :: [String.t()]
  def resource_metadata_urls(_mcp_url, %Challenge{resource_metadata: url}) when is_binary(url),
    do: [url]

  def resource_metadata_urls(mcp_url, %Challenge{}) do
    uri = URI.parse(mcp_url)
    root = %{uri | path: @resource_suffix, query: nil, fragment: nil}

    case path_of(uri) do
      "" -> [URI.to_string(root)]
      path -> [URI.to_string(%{root | path: @resource_suffix <> path}), URI.to_string(root)]
    end
  end

  @doc """
  The URLs that might hold an authorization server's metadata, in the priority
  order the specification requires.
  """
  @spec authorization_server_urls(issuer :: String.t()) :: [String.t()]
  def authorization_server_urls(issuer) do
    uri = URI.parse(issuer)

    case path_of(uri) do
      "" ->
        [
          well_known(uri, "/.well-known/oauth-authorization-server"),
          well_known(uri, "/.well-known/openid-configuration")
        ]

      path ->
        [
          well_known(uri, "/.well-known/oauth-authorization-server" <> path),
          well_known(uri, "/.well-known/openid-configuration" <> path),
          well_known(uri, path <> "/.well-known/openid-configuration")
        ]
    end
  end

  defp well_known(uri, path),
    do: URI.to_string(%{uri | path: path, query: nil, fragment: nil})

  defp path_of(%URI{path: nil}), do: ""
  defp path_of(%URI{path: "/"}), do: ""
  defp path_of(%URI{path: path}), do: String.trim_trailing(path, "/")

  @doc """
  Follows a refusal to the MCP server's protected resource metadata.

  ## Options

    * `:get` — how to fetch a JSON document, for tests. Defaults to `Req`.
  """
  @spec resource(mcp_url :: String.t(), challenge :: Challenge.t(), opts :: keyword()) ::
          {:ok, resource()} | {:error, String.t()}
  def resource(mcp_url, challenge, opts \\ []) do
    urls = resource_metadata_urls(mcp_url, challenge)

    case probe(urls, opts) do
      {:ok, metadata} -> from_resource_metadata(metadata, mcp_url)
      :error -> from_origin(mcp_url)
    end
  end

  # Atlassian's MCP server, measured on 2026-08-14, refuses with a
  # `WWW-Authenticate` naming no resource metadata *and* publishes nothing at either
  # well-known URI, implementing neither of the two mechanisms the specification says
  # a server must implement one of. It does serve authorization server metadata at
  # its own origin.
  #
  # Refusing on principle would mean a conforming client that cannot reach a server
  # people use, so the last resort is to assume the server is its own authorization
  # server. That is safe rather than merely convenient: the origin is one we are
  # already sending MCP requests to, and `authorization_server/2` still refuses
  # metadata whose `issuer` is not that origin.
  defp from_origin(mcp_url) do
    uri = URI.parse(mcp_url)

    case uri.host do
      nil ->
        {:error, "#{mcp_url} is not a URL an authorization server can be found from"}

      _host ->
        origin = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})

        Logger.info(
          "lemieux: #{mcp_url} publishes no protected resource metadata, which the " <>
            "specification requires; assuming #{origin} is its own authorization server"
        )

        {:ok, %{resource: mcp_url, issuer: origin, scopes_supported: []}}
    end
  end

  defp from_resource_metadata(metadata, mcp_url) do
    case Map.get(metadata, "authorization_servers") do
      [issuer | _rest] when is_binary(issuer) ->
        {:ok,
         %{
           # The metadata's own `resource` is the canonical identifier to send
           # as the `resource` parameter, and it may differ from the URL used
           # to reach the server — a trailing slash, a redirect. The server's
           # answer wins over our guess.
           resource: Map.get(metadata, "resource") || mcp_url,
           issuer: issuer,
           scopes_supported: Map.get(metadata, "scopes_supported", [])
         }}

      _otherwise ->
        {:error,
         "#{mcp_url} published protected resource metadata that names no authorization server, " <>
           "so there is nowhere to go and ask for a token"}
    end
  end

  @doc """
  Fetches and validates an authorization server's metadata.

  ## Options

    * `:get` — how to fetch a JSON document, for tests. Defaults to `Req`.
  """
  @spec authorization_server(issuer :: String.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def authorization_server(issuer, opts \\ []) do
    urls = authorization_server_urls(issuer)

    with {:ok, metadata} <- fetch_metadata(urls, issuer, opts),
         :ok <- validate_issuer(metadata, issuer),
         :ok <- validate_pkce(metadata, issuer) do
      {:ok, metadata}
    end
  end

  defp fetch_metadata(urls, issuer, opts) do
    case probe(urls, opts) do
      {:ok, metadata} ->
        {:ok, metadata}

      :error ->
        {:error,
         "could not find authorization server metadata for #{issuer}. Tried " <>
           Enum.map_join(urls, ", ", & &1) <> "."}
    end
  end

  # RFC 8414 §3.3: the document's issuer must be identical to the one used to
  # build the URL it came from. Anything else is a document an attacker put
  # somewhere convenient.
  defp validate_issuer(metadata, issuer) do
    case Map.get(metadata, "issuer") do
      ^issuer ->
        :ok

      other ->
        {:error,
         "the metadata published for #{issuer} names a different issuer, #{inspect(other)}; " <>
           "refusing to use it"}
    end
  end

  defp validate_pkce(metadata, issuer) do
    case Map.get(metadata, "code_challenge_methods_supported") do
      methods when is_list(methods) ->
        if "S256" in methods do
          :ok
        else
          {:error,
           "#{issuer} advertises PKCE methods #{inspect(methods)} but not S256, which OAuth 2.1 " <>
             "requires; refusing to downgrade"}
        end

      _otherwise ->
        {:error,
         "#{issuer} does not advertise code_challenge_methods_supported, which is the only way " <>
           "to know it supports PKCE; refusing to proceed without it"}
    end
  end

  defp probe([], _opts), do: :error

  defp probe([url | rest], opts) do
    case get(opts).(url) do
      {:ok, body} when is_map(body) -> {:ok, body}
      _otherwise -> probe(rest, opts)
    end
  end

  defp get(opts), do: Keyword.get(opts, :get, &fetch/1)

  defp fetch(url) do
    case Req.get(url, retry: false, receive_timeout: :timer.seconds(15)) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
