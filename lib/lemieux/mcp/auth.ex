defmodule Lemieux.MCP.Auth do
  @moduledoc """
  Authorizing against an MCP server that wants OAuth.

  Attach one of these to a session as `:mcp_auth` and an HTTP MCP server that
  answers `401` stops being a dead end. Without one, nothing changes: the
  transport reports what the server asked for and says where to put a token, as
  it did before.

      Lemieux.MCP.Auth.new(
        store: Lemieux.MCP.Auth.Store.File.new(path),
        redirect_uri: "http://127.0.0.1:8642/callback",
        redirect: &MyHost.open_browser_and_wait/2
      )

  ## Two halves, and the seam between them

  Everything except **the browser round trip** happens here: discovery,
  registration, PKCE, the exchange, storage, refresh. The one thing a library
  cannot do honestly is open a browser and bind a port, so that is the whole of
  what a host supplies — a function given a URL and the redirect URI, returning
  the query parameters the authorization server eventually redirected to.

  Putting the seam there rather than at "give me a token" is deliberate. A
  seam at the token would push PKCE, `iss` validation and resource binding into
  every host, and those are exactly the parts that are security-relevant and
  tedious to get right. A host should be able to write its half in twenty
  lines and get the rest correct for free.

  ## It is driven by the refusal, not by connecting

  Nothing is attempted until a server actually refuses a request. So an
  unauthenticated server costs nothing, and an authenticated one costs one
  extra round trip when a client process starts — the `401` that names its
  authorization server. That trade is on purpose: the alternative is probing
  every server's protected-resource metadata at connect time, which spends a
  request on every server to learn something only some of them need.

  A refusal for a resource already worked out does not repeat the discovery; a
  client keeps what it learned for as long as it lives.

  ## What happens on each kind of refusal

    * **`401` with no token yet** — discover, register, authorize, keep the
      token, retry.
    * **`401` with a token that was rejected** — refresh it. If the refresh
      fails, forget the stored token (or it is retried forever) and authorize
      again.
    * **`403 insufficient_scope`** — a step up. Authorize again asking for the
      **union** of what was already requested and what the server now demands.
      The union is the point: asking for only the new scope silently gives up
      the old one, so authorizing for a second operation breaks the first.

  ## Headless hosts

  There is no device-code flow to offer — no MCP server in production
  advertises one, and the proposal to add it to the specification has been open
  since April 2025 without adoption. A host that cannot open a browser
  therefore does not authorize; it *reads a store somebody else wrote*. An
  operator runs `lmx` once on their own machine, and a server-side host points
  its `:store` at the result. That is why the store is a behaviour and not a
  private file format.
  """

  require Logger

  alias Lemieux.MCP.Auth.Challenge
  alias Lemieux.MCP.Auth.Discovery
  alias Lemieux.MCP.Auth.Flow
  alias Lemieux.MCP.Auth.Registration
  alias Lemieux.MCP.Auth.Store

  @typedoc """
  How this host authorizes.

    * `:store` — where tokens and registrations are kept.
    * `:redirect_uri` — where the authorization server sends the browser.
      **Fixed, and the host's choice.** See `new/1`.
    * `:redirect` — opens the URL and returns the redirect's query parameters.
      `nil` means this host cannot authorize interactively, and only stored
      tokens will be used.
    * `:client_name` — what a person sees on the consent screen.
    * `:client_id_metadata_url` — this client's published metadata document,
      enabling CIMD where a server supports it.
    * `:clients` — pre-registered credentials, keyed by issuer. The only way in
      to a server like GitHub, which offers no automatic registration at all.
    * `:scopes` — override what to ask for, when a server's own answer is
      wrong for this host.
  """
  @type t :: %__MODULE__{
          store: Store.t(),
          redirect_uri: String.t(),
          redirect: (String.t(), String.t() -> {:ok, map()} | {:error, term()}) | nil,
          client_name: String.t(),
          client_uri: String.t() | nil,
          client_id_metadata_url: String.t() | nil,
          clients: %{optional(String.t()) => map()},
          scopes: [String.t()] | nil
        }

  defstruct [
    :store,
    :redirect,
    :client_uri,
    :client_id_metadata_url,
    :scopes,
    redirect_uri: "http://127.0.0.1:8642/callback",
    client_name: "lemieux",
    clients: %{}
  ]

  @typedoc "What a client worked out about one server, and keeps."
  @type binding :: %{
          resource: String.t(),
          issuer: String.t(),
          metadata: map(),
          client: map(),
          scopes: [String.t()]
        }

  @doc """
  Builds an authorization configuration.

  ## The redirect URI is fixed, and that is not the usual advice

  RFC 8252 tells a native application to take an ephemeral port from the
  operating system. For MCP that is the wrong choice, for two reasons that
  happen to agree:

    * **Servers disagree about port matching.** RFC 8252 §7.3 requires an
      authorization server to ignore the port when matching a loopback redirect
      URI. Several do not, and reject `http://127.0.0.1:51353/callback` as not
      matching the `http://127.0.0.1/callback` in a Client ID Metadata
      Document. This is filed against the MCP TypeScript SDK, FastMCP and
      Cloudflare's OAuth provider at once, and Claude Code is currently losing
      to it.
    * **A tunnel needs to know the port first.** The working practice for a
      remote machine is `ssh -L 8642:localhost:8642 devbox`, browser on the
      laptop and listener on the box, and that cannot forward a port that has
      not been chosen yet.

  So the port is fixed, and configurable when something else already has it.
  """
  @spec new(opts :: keyword()) :: t()
  def new(opts), do: struct!(__MODULE__, opts)

  @doc """
  Gets a token to retry a refused request with.

  `binding` is what a previous call worked out about this server, or `nil` the
  first time. `stale?` says the request that was refused already carried a
  token, which means the stored one is no good and refreshing is the next move.

  `interactive: false` says nobody can be sent to a browser right now — a
  session connecting its servers at startup. A stored token is still used and
  a refreshable one still refreshed; only a flow that would need consent stops,
  as `{:error, {:needs_auth, info}}`, so the host can offer it when somebody is
  there to give it. Without that, a first connection to an OAuth server held
  startup for as long as the browser round trip was allowed to take.

  Returns the access token to send and the binding to keep.
  """
  @spec acquire(
          auth :: t(),
          mcp_url :: String.t(),
          challenge :: Challenge.t(),
          opts :: keyword()
        ) ::
          {:ok, String.t(), binding()}
          | {:error, String.t() | {:needs_auth, %{resource: String.t(), issuer: String.t()}}}
  def acquire(auth, mcp_url, challenge, opts \\ []) do
    with {:ok, binding} <- bind(auth, mcp_url, challenge, Keyword.get(opts, :binding)) do
      binding = %{binding | scopes: wanted(auth, binding, challenge)}
      consent = if Keyword.get(opts, :interactive, true) == false, do: :deferred, else: :now

      obtain(auth, binding, challenge, Keyword.get(opts, :stale?, false), consent)
    end
  end

  defp bind(_auth, _mcp_url, _challenge, binding) when is_map(binding), do: {:ok, binding}

  defp bind(auth, mcp_url, challenge, nil) do
    with {:ok, resource} <- Discovery.resource(mcp_url, challenge),
         {:ok, metadata} <- Discovery.authorization_server(resource.issuer),
         {:ok, client} <- Registration.resolve(metadata, registration_opts(auth)) do
      {:ok,
       %{
         resource: resource.resource,
         issuer: resource.issuer,
         metadata: metadata,
         client: client,
         scopes: resource.scopes_supported
       }}
    end
  end

  defp registration_opts(auth) do
    [
      store: auth.store,
      clients: auth.clients,
      client_id_metadata_url: auth.client_id_metadata_url,
      client_name: auth.client_name,
      client_uri: auth.client_uri,
      redirect_uris: [auth.redirect_uri]
    ]
  end

  # The specification's scope priority: what the challenge names wins, because
  # those are the scopes this operation actually needs and a client must not
  # assume any relationship between them and `scopes_supported`. A host that
  # says otherwise outranks both, since it may know something neither does.
  defp wanted(%{scopes: scopes}, _binding, _challenge) when is_list(scopes), do: scopes
  defp wanted(_auth, binding, %Challenge{scopes: []}), do: binding.scopes
  defp wanted(_auth, _binding, %Challenge{scopes: scopes}), do: scopes

  defp obtain(auth, binding, challenge, stale?, consent) do
    case Store.fetch_token(auth.store, binding.issuer, binding.resource) do
      {:ok, token} -> renew(auth, binding, challenge, token, stale?, consent)
      :error -> authorize(auth, binding, consent)
    end
  end

  defp renew(auth, binding, challenge, token, stale?, consent) do
    cond do
      # More scope is wanted than this token was granted. Refreshing would
      # return the same scope, so the only answer is to ask again.
      Challenge.step_up?(challenge) -> authorize(auth, step_up(binding, token), consent)
      stale? or Flow.expired?(token) -> refresh(auth, binding, token, consent)
      true -> {:ok, Map.fetch!(token, "access_token"), binding}
    end
  end

  # The union, which is the whole rule: a server challenging for `files:write`
  # is naming what this operation needs, not the complete set the client should
  # hold. Asking for only that would drop `files:read`, and the next read fails.
  defp step_up(binding, token) do
    granted = Map.get(token, "requested_scopes", [])

    %{binding | scopes: Enum.uniq(granted ++ binding.scopes)}
  end

  defp refresh(auth, binding, token, consent) do
    case Flow.refresh(binding.metadata, binding.client, token, binding.resource) do
      {:ok, refreshed} ->
        keep(auth, binding, Map.put(refreshed, "requested_scopes", binding.scopes))

      {:error, reason} ->
        # Forgotten before authorizing again, or a dead token is retried on
        # every run for as long as the file exists.
        Store.delete_token(auth.store, binding.issuer, binding.resource)

        Logger.info("lemieux: could not refresh the token for #{binding.resource}: #{reason}")

        authorize(auth, binding, consent)
    end
  end

  # Checked before the missing-browser clause: a host that deferred consent
  # may well be able to open a browser later, and "cannot open a browser" would
  # tell somebody the wrong thing about how to fix it.
  defp authorize(_auth, binding, :deferred),
    do: {:error, {:needs_auth, %{resource: binding.resource, issuer: binding.issuer}}}

  defp authorize(auth, binding, :now), do: authorize(auth, binding)

  defp authorize(%{redirect: nil} = auth, binding) do
    {:error,
     "#{binding.resource} needs authorization, and this host cannot open a browser. Authorize " <>
       "it once elsewhere — `lmx` will — against the same credential store " <>
       "(#{describe_store(auth.store)}), and this session will use the token it leaves."}
  end

  defp authorize(auth, binding) do
    {url, pending} =
      Flow.start(binding.metadata, binding.client,
        resource: binding.resource,
        redirect_uri: auth.redirect_uri,
        scopes: binding.scopes
      )

    with {:ok, params} <- open(auth, url, binding),
         {:ok, code} <- Flow.finish(pending, params),
         {:ok, token} <- Flow.exchange(binding.metadata, binding.client, pending, code) do
      # Recorded alongside the token so a later step-up can ask for the union
      # rather than guessing what was already granted.
      keep(auth, binding, Map.put(token, "requested_scopes", binding.scopes))
    end
  end

  defp open(auth, url, binding) do
    case auth.redirect.(url, auth.redirect_uri) do
      {:ok, params} when is_map(params) ->
        {:ok, params}

      {:error, reason} ->
        {:error, "authorizing #{binding.resource} did not finish: #{describe(reason)}"}

      other ->
        {:error, "the host's redirect returned #{inspect(other)} rather than parameters"}
    end
  end

  # A token that cannot be written is still a token: this run works, and the
  # next one authorizes again. Refusing to proceed would turn a slow path into
  # a broken one.
  defp keep(auth, binding, token) do
    case Store.put_token(auth.store, binding.issuer, binding.resource, token) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "lemieux: authorized #{binding.resource} but could not keep the token, so this will " <>
            "happen again next run: #{reason}"
        )
    end

    {:ok, Map.fetch!(token, "access_token"), binding}
  end

  defp describe_store({module, state}) when is_binary(state), do: "#{inspect(module)} at #{state}"
  defp describe_store({module, _state}), do: inspect(module)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
