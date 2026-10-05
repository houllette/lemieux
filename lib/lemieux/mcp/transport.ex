defmodule Lemieux.MCP.Transport do
  @moduledoc """
  How a client reaches one MCP server.

  Two are built in: `Lemieux.MCP.Transport.Stdio`, which runs the server as a
  child process and speaks newline-delimited JSON over its pipes, and
  `Lemieux.MCP.Transport.HTTP`, which posts to a URL. A host adds a third by
  implementing this behaviour and registering the module under a name — see
  `Lemieux.MCP.transports/0` — and nothing in the library has to learn it
  exists. `configure/2` is what makes that possible: the library resolves the
  name and hands the transport its own configuration to read.

  ## The three ways a client can use a transport

  The required callbacks are **synchronous request/response**, and a
  transport that implements only those is used **serially**: its client makes
  one request at a time and waits for it inline. That is the smallest contract
  that works, and a host's transport can stay that small.

  Serial has a cost that stopped being acceptable once tool calls were allowed
  to run for minutes: a call nobody is waiting for any more — the session
  cancelled it, or its deadline passed — still holds the client until the
  server answers, and every later call to that server queues behind it. So a
  transport may declare, through the optional `mode/1`, that it can do better:

    * `:duplex` — messages from the server arrive as **process messages** to
      the client (a Port's data, a socket in active mode). The client writes
      every request, response and notification with `notify/2`, feeds whatever
      arrives through `handle_message/2`, and correlates replies by id itself.
      Any number of calls can then be in flight; one that is abandoned is
      cancelled on the wire and forgotten, and a server's unprompted
      notifications — progress, a changed tool list — are heard at all.
    * `:independent` — every request is its own round trip that holds no
      shared connection (HTTP). The client runs `call/3` in a separate process
      per request on a copy of the state, so an abandoned call is simply
      killed, and folds anything the call learned back in with `merge/2`.

  The startup handshake is always made serially, before anything else can be
  in flight, so a transport's `call/3` is required either way.
  """

  @typedoc "Whatever an implementation needs to keep."
  @type state :: term()

  @typedoc "How the client may use a transport; see the module documentation."
  @type mode :: :serial | :duplex | :independent

  @doc """
  Reads a server's configuration into what `connect/1` takes.

  `config` is the JSON-shaped map the session recorded — string keys, as
  `Lemieux.MCP.config/1` left it. `opts` are the options the host gave
  `Lemieux.MCP.connect/2` (`:cwd`, `:auth`, `:stdio_launcher`, and whatever
  else it added), which is how anything that must not be written to the
  transcript reaches a transport: a credential store or a function travels
  here, never in `config`.

  A field that may hold `${VAR}` is expanded here with `Lemieux.MCP.expand/2`
  and not earlier, for the reason given there. Which fields those are is the
  transport's knowledge, which is why the expansion is not done for it.

  A configuration this transport cannot use is `{:error, message}`, and the
  message is what the log says about the server; name what is missing.
  """
  @callback configure(config :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, String.t()}

  @doc """
  Starts talking to a server. Called once, when the client starts, with what
  `configure/2` returned.
  """
  @callback connect(config :: map()) :: {:ok, state()} | {:error, term()}

  @doc """
  Sends a request and waits for its reply.

  Returns the decoded JSON-RPC response — the whole envelope, so the caller
  can tell a result from an error, which is a protocol decision and not a
  transport one.
  """
  @callback call(state :: state(), request :: map(), timeout :: timeout()) ::
              {:ok, map(), state()} | {:error, term(), state()}

  @doc """
  Sends a message that is not waited for here.

  For a serial or independent transport this is a notification. A duplex
  transport also receives every request and every response the client sends
  through it once the handshake is over, since for it "send" and "wait" are
  separate steps.
  """
  @callback notify(state :: state(), notification :: map()) ::
              {:ok, state()} | {:error, term(), state()}

  @doc """
  Stops talking to the server and releases whatever was holding it open.
  """
  @callback close(state :: state()) :: :ok

  @doc """
  A chance to inspect a freshly listed set of tools before they are offered.

  Exists because one requirement genuinely is transport-specific: over HTTP a
  client **must** honour `x-mcp-header` annotations and **must** drop a tool
  whose annotations are malformed, while over stdio it may ignore them
  entirely. Putting that in the transport keeps the rule where its reason is,
  rather than in a client that would have to ask what it is talking over.
  """
  @callback prepare_tools(state :: state(), tools :: [struct()]) :: {[struct()], state()}

  @doc """
  How the client may use this transport. `:serial` when not implemented.
  """
  @callback mode(state :: state()) :: mode()

  @doc """
  Turns a process message the client received into decoded JSON-RPC messages.

  Duplex transports only. `:unknown` means the message was not this
  transport's; `{:closed, reason, state}` that the server has gone, which
  fails every call in flight.
  """
  @callback handle_message(state :: state(), message :: term()) ::
              {:ok, [map()], state()} | {:closed, term(), state()} | :unknown

  @doc """
  Folds what an independent `call/3` learned into the client's current state.

  The state `call/3` returned was copied before the call started, and other
  calls may have finished since. Only what a call can learn — a token it
  refreshed, a session a legacy server minted — belongs in the merge. Taken
  wholesale when not implemented.
  """
  @callback merge(current :: state(), returned :: state()) :: state()

  @doc """
  Messages that arrived beside a reply rather than as one.

  An HTTP server can put notifications ahead of its response in an event
  stream, and a changed tool list announced there should not be lost just
  because it rode along with an unrelated answer. The client drains these
  after every call.
  """
  @callback drain(state :: state()) :: {[map()], state()}

  @optional_callbacks mode: 1, handle_message: 2, merge: 2, drain: 1
end
