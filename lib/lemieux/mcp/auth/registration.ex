defmodule Lemieux.MCP.Auth.Registration do
  @moduledoc """
  Getting a client id from an authorization server.

  There are three ways, the specification ranks them, and **all three are
  needed** — which is the finding that most changed this phase. Measured across
  eight hosted MCP servers:

  | | CIMD | DCR |
  | --- | --- | --- |
  | Linear, Sentry, Notion | yes | yes |
  | Atlassian, Stripe, Asana, PayPal | no | yes |
  | GitHub | no | no |

  So a client implementing only Client ID Metadata Documents — the mechanism
  the specification prefers and the one that will eventually be the only one —
  reaches three of the eight today. And GitHub, the server most likely to be
  asked for, supports neither: its authorization server is ordinary GitHub
  OAuth, and the only way in is an OAuth App somebody created by hand. That is
  why pre-registration is first in the priority order rather than a nicety.

  ## The order, and one departure from it

  1. **Pre-registered** credentials configured for this issuer.
  2. **Client ID Metadata Documents**, when the server advertises
     `client_id_metadata_document_supported` *and* a document URL is
     configured. No storage: the client id is a URL the server resolves, so it
     is portable across authorization servers and there is nothing to keep.
  3. **A registration already obtained** from this issuer by Dynamic Client
     Registration. This step is not in the specification's list; it exists so
     the fourth step happens once per server rather than once per run.
  4. **Dynamic Client Registration**, deprecated and still the majority path.

  ## `application_type` is not optional on the DCR request

  Omitting it defaults to `"web"` under OpenID Connect, and a `"web"` client
  is not allowed a loopback redirect URI — so an OIDC-backed server rejects the
  registration with an error about the redirect URI, which reads as though the
  URI were wrong rather than the application type. `"native"` is what a CLI is.
  """

  require Logger

  alias Lemieux.MCP.Auth.Store

  @doc """
  Resolves a client id for an authorization server, registering if it must.

  ## Options

    * `:store` — required, where a dynamic registration is kept.
    * `:clients` — pre-registered credentials, keyed by issuer.
    * `:client_id_metadata_url` — the HTTPS URL of this client's metadata
      document, or `nil` to not offer CIMD.
    * `:client_name` — what a person sees on the consent screen.
    * `:client_uri` — optional, shown alongside the name.
    * `:redirect_uris` — required for registration.
    * `:post` — how to POST JSON, for tests. Defaults to `Req`.
  """
  @spec resolve(metadata :: map(), opts :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def resolve(metadata, opts) do
    issuer = Map.fetch!(metadata, "issuer")

    with :error <- pre_registered(issuer, opts),
         :error <- cimd(metadata, opts),
         :error <- stored(issuer, opts) do
      register(metadata, issuer, opts)
    else
      {:ok, client} -> {:ok, client}
    end
  end

  defp pre_registered(issuer, opts) do
    opts
    |> Keyword.get(:clients, %{})
    |> Map.fetch(issuer)
  end

  defp cimd(metadata, opts) do
    url = Keyword.get(opts, :client_id_metadata_url)

    if Map.get(metadata, "client_id_metadata_document_supported") == true and is_binary(url) do
      {:ok, %{"client_id" => url}}
    else
      :error
    end
  end

  defp stored(issuer, opts) do
    opts |> Keyword.fetch!(:store) |> Store.fetch_client(issuer)
  end

  defp register(metadata, issuer, opts) do
    case Map.get(metadata, "registration_endpoint") do
      endpoint when is_binary(endpoint) -> post_registration(endpoint, issuer, opts)
      _otherwise -> {:error, nothing_available(issuer, opts)}
    end
  end

  defp post_registration(endpoint, issuer, opts) do
    case post(opts).(endpoint, registration_request(opts)) do
      {:ok, %{"client_id" => _id} = client} ->
        keep(client, issuer, opts)

      {:ok, other} ->
        {:error,
         "#{endpoint} answered a registration that carries no client_id: #{inspect(other)}"}

      {:error, reason} ->
        {:error, "#{endpoint} refused to register lemieux as a client: #{reason}"}
    end
  end

  # A failure to persist is a warning rather than an error: the registration in
  # hand is still usable for this run, and refusing to authorize because a file
  # could not be written would turn a slow path into a broken one.
  defp keep(client, issuer, opts) do
    case Store.put_client(Keyword.fetch!(opts, :store), issuer, client) do
      :ok ->
        {:ok, client}

      {:error, reason} ->
        Logger.warning(
          "lemieux: registered with #{issuer} but could not keep the registration, so the " <>
            "next run will register again: #{reason}"
        )

        {:ok, client}
    end
  end

  defp registration_request(opts) do
    %{
      "client_name" => Keyword.get(opts, :client_name, "lemieux"),
      "redirect_uris" => Keyword.fetch!(opts, :redirect_uris),
      # Without this, OpenID Connect servers default to "web" and then reject
      # the loopback redirect URI with an error that blames the URI.
      "application_type" => "native",
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
    |> put_optional("client_uri", Keyword.get(opts, :client_uri))
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp post(opts), do: Keyword.get(opts, :post, &post_json/2)

  defp post_json(url, body) do
    case Req.post(url, json: body, retry: false, receive_timeout: :timer.seconds(15)) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{describe_body(body)}"}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  # An authorization server's rejection is JSON naming an `error`, and that
  # name is the actionable part — `invalid_redirect_uri` says something
  # different from `invalid_client_metadata`.
  defp describe_body(%{"error" => error} = body),
    do: Enum.join([error, Map.get(body, "error_description")], " — ")

  defp describe_body(body) when is_map(body), do: inspect(body)
  defp describe_body(body), do: to_string(body)

  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  defp nothing_available(issuer, opts) do
    cimd =
      if Keyword.get(opts, :client_id_metadata_url) do
        ""
      else
        " It may accept a Client ID Metadata Document, which lemieux can offer once one is " <>
          "configured to point at."
      end

    "#{issuer} offers no way to obtain a client_id automatically: it advertises neither " <>
      "Client ID Metadata Document support nor a registration endpoint. Register an OAuth " <>
      "application with it by hand and configure the client_id it gives you." <> cimd
  end

  @doc """
  The metadata document lemieux publishes about itself for CIMD.

  Not served from here — this is a library, and the document has to live at a
  stable HTTPS URL somebody owns. This function builds it so the URL's owner
  can generate rather than hand-write it, and so the redirect URIs in it cannot
  drift from the ones the client actually uses.

  ## Redirect URIs, in more forms than look necessary

  RFC 8252 §7.3 requires an authorization server to ignore the port when
  matching a loopback redirect URI, so `http://127.0.0.1/callback` should be
  enough. Several servers instead compare the whole string, and reject
  `http://127.0.0.1:8642/callback` as not matching. This is an open
  disagreement between two specifications rather than one implementation's
  bug — it is filed against the MCP TypeScript SDK, FastMCP and Cloudflare's
  OAuth provider at once, and Claude Code is currently losing to it.

  So the document declares both the portless forms and the concrete ports the
  client will actually bind, and `127.0.0.1` as well as `localhost` because
  servers differ on which they will accept.
  """
  @spec metadata_document(url :: String.t(), client_name :: String.t(), opts :: keyword()) ::
          map()
  def metadata_document(url, client_name, opts \\ []) do
    %{
      # The document must name itself, and an authorization server must check
      # that it does. A mismatch here is the whole mechanism failing open.
      "client_id" => url,
      "client_name" => client_name,
      "redirect_uris" => redirect_uris(Keyword.get(opts, :redirect_uris, [])),
      "grant_types" => ["authorization_code", "refresh_token"],
      "response_types" => ["code"],
      "token_endpoint_auth_method" => "none"
    }
    |> put_optional("client_uri", Keyword.get(opts, :client_uri))
  end

  defp redirect_uris(configured) do
    (configured ++ Enum.flat_map(configured, &variants/1) ++ defaults())
    |> Enum.uniq()
  end

  defp defaults, do: ["http://127.0.0.1/callback", "http://localhost/callback"]

  defp variants(uri) do
    parsed = URI.parse(uri)

    for host <- ["127.0.0.1", "localhost"], port <- [parsed.port, nil], uniq: true do
      URI.to_string(%{parsed | host: host, port: port, scheme: "http"})
    end
  end
end
