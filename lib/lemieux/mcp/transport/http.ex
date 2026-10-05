defmodule Lemieux.MCP.Transport.HTTP do
  @moduledoc """
  An MCP server reached over Streamable HTTP.

  Every JSON-RPC message is its own POST. The server answers with either a
  single JSON object or an event stream, and a client **must** handle both —
  the choice is the server's, per request.

  ## The headers are not optional

  This revision mirrors parts of the body into headers so that load balancers
  and gateways can route without parsing JSON, and it makes servers reject any
  request where the two disagree. So `MCP-Protocol-Version` must equal the
  version in `_meta`, `Mcp-Method` must equal the method, and `Mcp-Name` must
  equal `params.name` on a `tools/call`. Getting one wrong is a `400` with a
  `HeaderMismatch` error, on every request, from every conforming server.

  A name that will not fit in a header — anything outside printable ASCII, or
  with edge whitespace — travels Base64-encoded between the sentinels
  `=?base64?` and `?=`, and so does any literal value that would look like
  one.

  ## Parameters that become headers

  A server may annotate a tool parameter with `x-mcp-header`, asking for its
  value in an `Mcp-Param-{Name}` header, and clients on this transport
  **must** honour it. They must also refuse a tool whose annotations break the
  rules — an empty name, one with characters a header cannot hold, a duplicate
  — by leaving that tool out of the list rather than by failing the list. One
  malformed tool should cost one tool.

  ## Reading an event stream

  The whole body is read and its `data:` frames parsed, rather than consumed
  incrementally. That works because every stream this client opens terminates:
  the specification says the final response **SHOULD** end the stream, and the
  one long-lived stream MCP defines — `subscriptions/listen` — is for change
  notifications lemieux does not ask for. Progress notifications that arrive
  ahead of the response are skipped by taking the last frame that is a
  response, and SSE comment lines (keep-alives) are ignored by only reading
  `data:`.

  If lemieux ever does open a stream that stays open, this is the function to
  change: it would need to consume incrementally rather than wait for a body
  that never ends.

  ## Credentials

  Whatever is in the server's `headers` is sent on every request, and
  `${VAR}` in one is read from the environment at connect time — see
  `Lemieux.MCP.expand/1` for why that is not done sooner. That is the whole
  story for a server behind a token somebody pasted into a config file.

  For a server that wants OAuth, a session may be given a
  `Lemieux.MCP.Auth`, and then a `401` is a thing to act on rather than
  report: the challenge names the authorization server, the token is fetched
  or refreshed, and the request is retried with it. Without one, nothing
  changes — a `401` or `403` becomes an error naming exactly what the server
  asked for, which is the useful thing to say when the answer is "go and get a
  token".

  Retries are bounded at three. The specification says a client should retry
  "no more than a few times" and then treat the failure as permanent, and the
  bound is what stops a server that answers `401` to everything from becoming
  a loop with a browser in it.

  A host that must not block on a browser while it starts — a session
  connecting its servers before anybody has typed anything — passes
  `interactive_auth: false`. A server that would need consent is then reported
  as `{:needs_auth, info}` instead of opening a page and waiting minutes for
  somebody to notice it; a stored or refreshable token is still used. The host
  finishes the flow later, interactively, when somebody asks for that server.

  ## Concurrency

  Every request is its own POST, so this transport is **independent** (see
  `Lemieux.MCP.Transport`): its client runs each tool call in a process of its
  own, and a call that is abandoned is killed rather than waited out.
  Notifications a server puts ahead of its response in an event stream are
  kept for the client to `drain/1` — a changed tool list announced there is
  still a changed tool list.

  ## Falling back

  A `400` does not mean a server from before all this: modern servers use
  `400` for version and header errors too. The body decides. A recognised
  modern JSON-RPC error means a modern server to keep talking to; an empty or
  unrecognisable body means one that wants `initialize`, and this transport
  reports it in a shape `Lemieux.MCP.Protocol.classify/1` reads as legacy.

  Legacy servers may mint a session; the id comes back on the `initialize`
  response and is echoed on everything after it. This revision has no
  sessions at all, so the header is simply absent for modern servers.
  """

  @behaviour Lemieux.MCP.Transport

  require Logger

  alias Lemieux.MCP
  alias Lemieux.MCP.Auth
  alias Lemieux.MCP.Auth.Challenge
  alias Lemieux.MCP.Protocol

  @sentinel_prefix "=?base64?"
  @sentinel_suffix "?="

  @attempts 3

  @impl Lemieux.MCP.Transport
  def configure(%{"url" => url} = config, opts) do
    expansion = MCP.expansion(config, opts)

    with {:ok, url} <- MCP.expand(url, expansion),
         {:ok, headers} <- MCP.expand(Map.get(config, "headers", %{}), expansion) do
      # `:auth` deliberately arrives through opts rather than through the
      # server's configuration. The configuration is persisted in the
      # transcript, and this holds a function and a credential store.
      {:ok,
       %{
         url: url,
         headers: headers,
         auth: Keyword.get(opts, :auth),
         interactive_auth: Keyword.get(opts, :interactive_auth, true) != false
       }}
    end
  end

  def configure(_config, _opts), do: {:error, "an http MCP server needs a url"}

  @impl Lemieux.MCP.Transport
  def connect(config) do
    {:ok,
     %{
       url: Map.fetch!(config, :url),
       headers: Map.get(config, :headers, %{}),
       session_id: nil,
       schemas: %{},
       # How this host authorizes, or nil. Never part of the server's JSON
       # configuration: it holds a function and a credential store, and that
       # configuration is written to the transcript.
       auth: Map.get(config, :auth),
       interactive_auth: Map.get(config, :interactive_auth, true),
       token: nil,
       # What was worked out about this server's authorization, kept so a
       # second refusal does not repeat the discovery.
       binding: nil,
       # Notifications that arrived in an event stream ahead of a response.
       inbox: []
     }}
  end

  @impl Lemieux.MCP.Transport
  def mode(_state), do: :independent

  # What a call can learn is a token, the binding it was obtained under, a
  # legacy session id, and notifications. Schemas are the client's to set, from
  # a listing, and a call running on an older copy must not undo that.
  @impl Lemieux.MCP.Transport
  def merge(current, returned) do
    %{
      current
      | token: returned.token,
        binding: returned.binding,
        session_id: returned.session_id || current.session_id,
        inbox: current.inbox ++ returned.inbox
    }
  end

  @impl Lemieux.MCP.Transport
  def drain(state), do: {state.inbox, %{state | inbox: []}}

  @impl Lemieux.MCP.Transport
  def prepare_tools(state, tools) do
    {usable, rejected} = Enum.split_with(tools, &valid_annotations?(&1.schema))

    Enum.each(rejected, fn tool ->
      Logger.warning(
        "lemieux: leaving out the MCP tool #{tool.name} from #{tool.server}: its " <>
          "x-mcp-header annotations are not usable as HTTP header names"
      )
    end)

    # Kept so a later `tools/call` knows which arguments to mirror into
    # headers without asking the server again.
    {usable, %{state | schemas: Map.new(usable, &{&1.name, &1.schema})}}
  end

  defp valid_annotations?(schema) do
    names = schema |> annotated() |> Enum.map(fn {_path, name} -> String.downcase(name) end)

    Enum.all?(names, &token?/1) and length(Enum.uniq(names)) == length(names)
  end

  defp token?(name) do
    name != "" and String.match?(name, ~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/)
  end

  # Only properties reachable by a chain of `properties` keys: the
  # specification excludes anything behind arrays, `$ref`, or a composition
  # keyword, because a value there has no single place to be read from.
  defp annotated(schema, path \\ []) do
    schema
    |> Map.get("properties", %{})
    |> Enum.flat_map(fn {key, property} ->
      here = path ++ [key]
      nested = annotated(property, here)

      case Map.get(property, "x-mcp-header") do
        name when is_binary(name) -> [{here, name} | nested]
        _otherwise -> nested
      end
    end)
  end

  @impl Lemieux.MCP.Transport
  def call(state, request, timeout) do
    post(state, request, timeout)
  end

  @impl Lemieux.MCP.Transport
  def notify(state, notification) do
    case post(state, notification, :timer.seconds(10)) do
      {:ok, _response, state} -> {:ok, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp post(state, message, timeout), do: post(state, message, timeout, @attempts)

  defp post(state, message, timeout, attempts) do
    request =
      Req.new(
        url: state.url,
        method: :post,
        json: message,
        headers: headers(state, message),
        receive_timeout: timeout,
        retry: false,
        # A 400 is data here, not a failure: it is how a modern server reports
        # a version it will not speak, and how a legacy one reports confusion.
        decode_body: false
      )

    case Req.request(request) do
      {:ok, %{status: status} = response} when status in [401, 403] ->
        refused(state, message, timeout, attempts, response)

      {:ok, response} ->
        {reply, notifications} = decode(response)
        state = %{remember_session(state, response) | inbox: state.inbox ++ notifications}
        {:ok, reply, state}

      {:error, reason} ->
        {:error, describe(reason), state}
    end
  end

  defp refused(%{auth: nil} = state, _message, _timeout, _attempts, response),
    do: {:error, unauthorised(state, response), state}

  defp refused(state, _message, _timeout, 0, response) do
    {:error,
     "#{state.url} kept refusing after #{@attempts} attempts to authorize. " <>
       "The last thing it said: #{challenge_header(response) || "nothing"}.", state}
  end

  defp refused(state, message, timeout, attempts, response) do
    challenge = Challenge.parse(challenge_header(response))

    opts = [
      binding: state.binding,
      # The request that was refused already carried a token, so the stored one
      # is no good — refresh it rather than spending it again.
      stale?: not is_nil(state.token),
      interactive: state.interactive_auth
    ]

    case Auth.acquire(state.auth, state.url, challenge, opts) do
      {:ok, token, binding} ->
        post(%{state | token: token, binding: binding}, message, timeout, attempts - 1)

      {:error, {:needs_auth, info}} ->
        {:error, {:needs_auth, Map.put(info, :url, state.url)}, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp challenge_header(response) do
    case Req.Response.get_header(response, "www-authenticate") do
      [value | _rest] -> value
      [] -> nil
    end
  end

  # An error somebody can act on rather than a bare status. With no
  # `Lemieux.MCP.Auth` attached lemieux performs no OAuth flow, so the useful
  # thing it can do is say exactly what the server asked for and both ways to
  # answer it.
  defp unauthorised(state, response) do
    said =
      case challenge_header(response) do
        nil -> ""
        value -> " The server said: #{value}."
      end

    example = ~s({"authorization": "Bearer ${MY_TOKEN}"})

    "#{state.url} refused the request with HTTP #{response.status}.#{said} " <>
      "No authorization is configured for this session, so lemieux performed no OAuth flow: " <>
      "either attach a Lemieux.MCP.Auth, or put a credential in the server's headers, for " <>
      "example #{example} — a variable there is read from the environment when the server is " <>
      "connected, and never written to the transcript."
  end

  defp headers(state, message) do
    method = Map.get(message, "method")
    params = Map.get(message, "params") || %{}

    state.headers
    |> Map.merge(%{
      "accept" => "application/json, text/event-stream",
      "mcp-method" => method
    })
    |> put_token(state)
    |> put_version(params)
    |> put_name(params)
    |> put_params(state, method, params)
    |> put_session(state)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Overwrites any static `authorization` the configuration carried: a token
  # this transport went and got for *this* resource is a better credential than
  # one somebody pasted in, and sending both is not a thing HTTP allows.
  defp put_token(headers, %{token: nil}), do: headers
  defp put_token(headers, state), do: Map.put(headers, "authorization", "Bearer #{state.token}")

  # Taken from the body rather than from state, because the two disagreeing is
  # exactly what servers reject.
  defp put_version(headers, params) do
    version = get_in(params, ["_meta", "io.modelcontextprotocol/protocolVersion"])

    Map.put(headers, "mcp-protocol-version", version)
  end

  defp put_name(headers, params) do
    Map.put(headers, "mcp-name", encode_value(params["name"] || params["uri"]))
  end

  defp put_params(headers, state, "tools/call", params) do
    schema = Map.get(state.schemas, params["name"], %{})
    arguments = params["arguments"] || %{}

    schema
    |> annotated()
    |> Enum.reduce(headers, fn {path, name}, headers ->
      case get_in(arguments, path) do
        nil -> headers
        value -> Map.put(headers, "mcp-param-#{String.downcase(name)}", encode_value(value))
      end
    end)
  end

  defp put_params(headers, _state, _method, _params), do: headers

  defp put_session(headers, %{session_id: nil}), do: headers
  defp put_session(headers, state), do: Map.put(headers, "mcp-session-id", state.session_id)

  defp encode_value(nil), do: nil
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"
  defp encode_value(value) when is_integer(value), do: Integer.to_string(value)

  defp encode_value(value) when is_binary(value) do
    if header_safe?(value), do: value, else: encode_base64(value)
  end

  defp encode_value(value), do: encode_value(to_string(value))

  # Printable ASCII, no edge whitespace, and not something that would be
  # mistaken for an already-encoded value.
  defp header_safe?(value) do
    String.match?(value, ~r/^[\x21-\x7e]([\x20-\x7e]*[\x21-\x7e])?$/) and
      not String.starts_with?(value, @sentinel_prefix)
  end

  defp encode_base64(value), do: @sentinel_prefix <> Base.encode64(value) <> @sentinel_suffix

  # Only a legacy server mints one; this revision has no sessions.
  defp remember_session(state, response) do
    case Req.Response.get_header(response, "mcp-session-id") do
      [id | _rest] -> %{state | session_id: id}
      [] -> state
    end
  end

  defp decode(response) do
    if event_stream?(response) do
      response.body |> to_string() |> from_event_stream()
    else
      {json(response), []}
    end
  end

  defp event_stream?(response) do
    response
    |> Req.Response.get_header("content-type")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  # The response terminates the stream. Taking the last decodable frame that
  # is a response skips progress notifications without needing to know what
  # they are; the notifications themselves are kept, because the ones that are
  # not about this request — a changed tool list — are the client's business.
  defp from_event_stream(body) do
    frames =
      body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map(&(&1 |> String.replace_prefix("data:", "") |> String.trim()))
      |> Enum.flat_map(&decode_frame/1)

    reply =
      frames
      |> Enum.filter(&(Map.has_key?(&1, "result") or Map.has_key?(&1, "error")))
      |> List.last()
      |> case do
        nil -> %{"error" => %{"code" => 0, "message" => "the event stream carried no response"}}
        message -> message
      end

    notifications =
      Enum.filter(frames, &(Map.has_key?(&1, "method") and not Map.has_key?(&1, "id")))

    {reply, notifications}
  end

  defp decode_frame(data) do
    case JSON.decode(data) do
      {:ok, message} when is_map(message) -> [message]
      _otherwise -> []
    end
  end

  defp json(response) do
    case response.body |> to_string() |> JSON.decode() do
      {:ok, message} when is_map(message) ->
        message

      _otherwise ->
        # An empty or unreadable body on an error status is the signal that a
        # server predates all of this. Reported as a JSON-RPC error that
        # `Protocol.classify/1` reads as legacy, so the client falls back
        # rather than treating a fallback as a failure.
        %{
          "error" => %{
            "code" => 0,
            "message" => "HTTP #{response.status} with no JSON-RPC body"
          }
        }
    end
  end

  defp describe(%{__exception__: true} = reason), do: Exception.message(reason)
  defp describe(reason), do: inspect(reason)

  @impl Lemieux.MCP.Transport
  def close(_state), do: :ok

  @doc """
  The protocol version this transport announces when nothing else says.
  """
  @spec default_version() :: String.t()
  def default_version, do: Protocol.modern_version()
end
