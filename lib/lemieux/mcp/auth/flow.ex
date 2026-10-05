defmodule Lemieux.MCP.Auth.Flow do
  @moduledoc """
  The authorization code flow, expressed as data.

  This module computes a URL for somebody to visit and reads back what came out
  of the redirect. It opens no browser and binds no port — a library cannot do
  either honestly. `lmx` does those, and so could a host with a web interface
  of its own; both use the same three functions.

  ## What is being defended against

  Three of the checks here exist because of specific attacks, and each one is
  the sort that looks like paranoia until it is not:

  **`state`.** An attacker who can get a browser to hit the redirect URI with
  their own authorization code makes the client exchange it and end up holding
  a token for the *attacker's* account — anything the person then does through
  the client happens in the attacker's data. The `state` value ties the
  response to a request this client actually started.

  **`iss` (RFC 9207).** When a client talks to more than one authorization
  server, a hostile one can return a code issued by an honest one and have the
  client redeem it in the wrong place. The specification's table is implemented
  in `finish/2`: compare whenever `iss` is present, and additionally *require*
  it when the server advertised that it sends one. None of the eight servers
  measured advertise it yet, so the common path today is "absent, and the
  server did not claim otherwise — proceed".

  **Nothing from a mismatched response is repeated.** On an `iss` mismatch the
  specification says a client **must not** act on *or display* `error`,
  `error_description` or `error_uri`. That is easy to read past, and a
  diagnostic that helpfully prints the description is a phishing channel: the
  attacker controls the string, and it arrives with the client's own voice
  around it.

  ## PKCE, and only S256

  The verifier never leaves this process; only its SHA-256 goes in the URL.
  `Lemieux.MCP.Auth.Discovery` has already refused any server that does not
  advertise `S256`, so there is no negotiation here — two of the eight servers
  measured also offer `plain`, and picking whatever is advertised first is a
  silent downgrade.

  ## `resource` on both requests

  RFC 8707, and a **MUST** in both the authorization and the token request even
  when the server ignores it. It is what binds the token to one MCP server, and
  therefore the reason a token minted for one cannot be spent at another.
  """

  @typedoc """
  What a started flow has to remember until the redirect comes back.

  Held by the caller rather than in a process: the flow may outlive any
  particular request, and the redirect arrives somewhere else entirely.
  """
  @type pending :: %{
          state: String.t(),
          verifier: String.t(),
          issuer: String.t(),
          resource: String.t(),
          redirect_uri: String.t(),
          scopes: [String.t()],
          iss_required?: boolean()
        }

  # A token about to expire is refreshed now rather than spent on a request
  # that will outlive it. Anything shorter than a round trip is not usable.
  @skew 30

  @doc """
  Begins a flow: the URL to visit, and what to remember until it comes back.

  ## Options

    * `:resource` — required, the canonical URI of the MCP server.
    * `:redirect_uri` — required, where the authorization server sends the
      browser. Chosen by the host, never by this library.
    * `:scopes` — what to ask for.
  """
  @spec start(metadata :: map(), client :: map(), opts :: keyword()) :: {String.t(), pending()}
  def start(metadata, client, opts) do
    pending = %{
      state: random(),
      verifier: random(),
      # Recorded before the browser is opened, per the specification, and from
      # the *validated* metadata — an expected issuer taken from an unvalidated
      # source protects nothing.
      issuer: Map.fetch!(metadata, "issuer"),
      resource: Keyword.fetch!(opts, :resource),
      redirect_uri: Keyword.fetch!(opts, :redirect_uri),
      scopes: Keyword.get(opts, :scopes, []),
      iss_required?: Map.get(metadata, "authorization_response_iss_parameter_supported") == true
    }

    {authorization_url(metadata, client, pending), pending}
  end

  defp authorization_url(metadata, client, pending) do
    query =
      %{
        "response_type" => "code",
        "client_id" => Map.fetch!(client, "client_id"),
        "redirect_uri" => pending.redirect_uri,
        "state" => pending.state,
        "code_challenge" => challenge(pending.verifier),
        "code_challenge_method" => "S256",
        "resource" => pending.resource
      }
      |> put_scope(pending.scopes)

    metadata
    |> Map.fetch!("authorization_endpoint")
    |> URI.parse()
    |> Map.put(:query, URI.encode_query(query))
    |> URI.to_string()
  end

  defp put_scope(query, []), do: query
  defp put_scope(query, scopes), do: Map.put(query, "scope", Enum.join(scopes, " "))

  defp challenge(verifier),
    do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  defp random, do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Validates a redirect and returns the authorization code.

  `params` is the query string the browser was sent to, decoded.
  """
  @spec finish(pending :: pending(), params :: map()) :: {:ok, String.t()} | {:error, String.t()}
  def finish(pending, params) do
    # Ordered deliberately: `iss` is checked before anything in the response is
    # read, including an error, because a response from the wrong issuer must
    # not be acted on or displayed at all.
    with :ok <- check_issuer(pending, params),
         :ok <- check_state(pending, params),
         :ok <- check_error(params) do
      case Map.get(params, "code") do
        code when is_binary(code) and code != "" -> {:ok, code}
        _otherwise -> {:error, "the authorization server redirected back without a code"}
      end
    end
  end

  defp check_issuer(pending, params) do
    # Simple string comparison, per RFC 3986 §6.2.1: no case folding, no
    # default-port elision, no trailing-slash normalisation. The specification
    # forbids all three, because each one makes two different issuers compare
    # equal.
    case {Map.get(params, "iss"), pending.iss_required?} do
      {nil, false} ->
        :ok

      {nil, true} ->
        {:error,
         "#{pending.issuer} advertises that it sends an iss parameter but did not; refusing " <>
           "the response rather than assuming it came from the right place"}

      {issuer, _required?} when issuer == :erlang.map_get(:issuer, pending) ->
        :ok

      _otherwise ->
        {:error,
         "the authorization response came from a different issuer than the one asked; " <>
           "refusing it, and not repeating anything it said"}
    end
  end

  defp check_state(pending, params) do
    if Map.get(params, "state") == pending.state do
      :ok
    else
      {:error, "the authorization response carried the wrong state; refusing it"}
    end
  end

  defp check_error(%{"error" => error} = params) do
    description = Map.get(params, "error_description")

    {:error, "the authorization server refused: #{Enum.join([error, description], " — ")}"}
  end

  defp check_error(_params), do: :ok

  @doc """
  Exchanges an authorization code for a token.

  ## Options

    * `:post` — how to POST a form, for tests. Defaults to `Req`.
  """
  @spec exchange(
          metadata :: map(),
          client :: map(),
          pending :: pending(),
          code :: String.t(),
          opts :: keyword()
        ) :: {:ok, map()} | {:error, String.t()}
  def exchange(metadata, client, pending, code, opts \\ []) do
    form =
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        # Sent again, and it must be identical to the one in the authorization
        # request: the server compares them, and a mismatch is a code that was
        # authorized against a different destination.
        "redirect_uri" => pending.redirect_uri,
        "code_verifier" => pending.verifier,
        "resource" => pending.resource
      }
      |> put_client(client)

    token(metadata, form, %{}, opts)
  end

  @doc """
  Spends a refresh token for a new access token.

  ## Options

    * `:post` — how to POST a form, for tests. Defaults to `Req`.
  """
  @spec refresh(
          metadata :: map(),
          client :: map(),
          token :: map(),
          resource :: String.t(),
          opts :: keyword()
        ) :: {:ok, map()} | {:error, String.t()}
  def refresh(metadata, client, token, resource, opts \\ []) do
    case Map.get(token, "refresh_token") do
      refresh when is_binary(refresh) ->
        form =
          %{"grant_type" => "refresh_token", "refresh_token" => refresh, "resource" => resource}
          |> put_client(client)

        # A server that rotates refresh tokens sends a new one; a server that
        # does not sends nothing, and the old one is still the only one there
        # is. Dropping it there would turn every refresh into the last one.
        token(metadata, form, %{"refresh_token" => refresh}, opts)

      _otherwise ->
        {:error, "there is no refresh token to spend; authorization has to happen again"}
    end
  end

  defp put_client(form, client) do
    form
    |> Map.put("client_id", Map.fetch!(client, "client_id"))
    |> then(fn form ->
      case Map.get(client, "client_secret") do
        secret when is_binary(secret) -> Map.put(form, "client_secret", secret)
        _otherwise -> form
      end
    end)
  end

  defp token(metadata, form, defaults, opts) do
    endpoint = Map.fetch!(metadata, "token_endpoint")

    case post(opts).(endpoint, form) do
      {:ok, %{"access_token" => _at} = body} -> {:ok, stamp(Map.merge(defaults, body))}
      {:ok, body} -> {:error, "#{endpoint} answered without an access_token: #{inspect(body)}"}
      {:error, reason} -> {:error, "#{endpoint} refused: #{reason}"}
    end
  end

  # `expires_in` is a duration from the instant of a response nobody kept, and
  # is meaningless the moment it is written down. A moment survives being
  # stored, restarted and read back tomorrow.
  defp stamp(%{"expires_in" => seconds} = token) when is_integer(seconds),
    do:
      token
      |> Map.put("expires_at", System.system_time(:second) + seconds)
      |> Map.delete("expires_in")

  defp stamp(token), do: token

  @doc """
  Whether a token should be refreshed before being spent.

  A token with no expiry is taken at face value — the authorization server is
  entitled not to say, and the `401` that follows is the fallback.
  """
  @spec expired?(token :: map()) :: boolean()
  def expired?(%{"expires_at" => at}) when is_integer(at),
    do: at - @skew <= System.system_time(:second)

  def expired?(_token), do: false

  defp post(opts), do: Keyword.get(opts, :post, &post_form/2)

  defp post_form(url, form) do
    request =
      Req.new(
        url: url,
        method: :post,
        form: form,
        headers: %{"accept" => "application/json"},
        retry: false,
        receive_timeout: :timer.seconds(15)
      )

    case Req.request(request) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{describe_body(body)}"}

      {:error, reason} ->
        {:error, describe(reason)}
    end
  end

  defp describe_body(%{"error" => error} = body),
    do: Enum.join([error, Map.get(body, "error_description")], " — ")

  defp describe_body(body) when is_map(body), do: inspect(body)
  defp describe_body(body), do: to_string(body)

  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)
end
