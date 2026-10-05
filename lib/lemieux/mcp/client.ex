defmodule Lemieux.MCP.Client do
  @moduledoc """
  One connection to one MCP server.

  Owns a transport, works out which era of the protocol the server speaks,
  lists its tools and calls them. A session with three servers configured has
  three of these, and one server being broken or slow costs only its own
  tools.

  ## Working out the era, once

  On connect the client sends `server/discover` — the probe the specification
  names for exactly this. What comes back decides everything after it:

    * a result → the server is modern, and its `supportedVersions` decides
      which revision to use on every subsequent request;
    * `UnsupportedProtocolVersionError` → also modern, and disagreeing about
      versions, so the client picks one from the error and carries on;
    * any other error → a server that has never heard of `server/discover`,
      so the client falls back to the `initialize` handshake.

  The answer is a property of the server, not of a request, so it is worked
  out once and kept. Re-probing per call would cost a round trip each time to
  learn something that cannot change while the process lives.

  ## Calls in flight, and calls nobody wants any more

  After the handshake, how requests are made depends on the transport's
  `c:Lemieux.MCP.Transport.mode/1`. Over stdio and HTTP any number of calls
  may be in flight at once; a host's transport that declares nothing is used
  one request at a time, as before.

  Every call's caller is monitored. When it goes — the session cancelled the
  turn, or its tool deadline passed and the task was killed — the request is
  withdrawn: `notifications/cancelled` is sent so the server can stop working
  on it, and nothing waits for its answer. The alternative, which this used
  to be, is a client that sits inside a dead call until the server replies or
  the deadline passes, with every later call to that server queued behind it;
  once tool calls were allowed minutes, that was minutes of a server nobody
  could use.

  ## Deadlines that move

  Three budgets, each overridable per server (see `Lemieux.MCP.connect/2`):

    * `:startup_timeout` — the handshake and the first listing. A server
      started through `npx -y` downloads itself first, so this is generous.
    * `:tool_timeout` — a tool call, measured as **silence**: a
      `notifications/progress` for the call starts the clock again, so a
      long job that keeps reporting is not killed for being long.
    * `:timeout` — everything else after startup (listings, prompts,
      resources).

  ## What a server says unprompted

  Heard over duplex and HTTP transports. `notifications/tools/list_changed`
  makes the client list the tools again and send the process named by
  `:notify` (the owner, by default)

      {:mcp_tools_changed, %{server: name, client: pid, tools: tools, notices: notices}}

  and a changed prompt or resource list sends

      {:mcp_list_changed, %{server: name, client: pid, kind: :prompts | :resources}}

  A `ping` is answered; any other request a server sends gets "method not
  found", because lemieux declares no capability a server may call back into,
  and a server waiting on an answer that never comes is a server that hangs.

  ## Failure is a tool result, not a crash

  Every public function returns `{:ok, _}` or `{:error, reason}`, and a client
  whose server has died keeps answering `{:error, _}` rather than exiting. A
  dead MCP server should cost its own tools and nothing else: the session goes
  on, the model is told the tool did not work, and the other servers are
  unaffected. That is why this is a `GenServer` per server rather than a
  process that links them together.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Lemieux.MCP.Protocol
  alias Lemieux.MCP.RemoteTool

  @timeout :timer.seconds(30)
  @startup_timeout :timer.seconds(60)
  @tool_timeout :timer.minutes(10)

  # JSON-RPC's "method not found", for the requests a server may not send us.
  @method_not_found -32_601

  @typedoc "How to address a client."
  @type client :: GenServer.server()

  @typedoc """
  What a client reports about a server that needs somebody to sign in.

  `:server` is the configuration's name, `:url` the MCP endpoint, and
  `:resource` and `:issuer` what its authorization metadata named.
  """
  @type needs_auth :: %{
          required(:server) => String.t(),
          optional(:url) => String.t(),
          optional(:resource) => String.t(),
          optional(:issuer) => String.t()
        }

  @doc """
  Starts a client.

  ## Options

    * `:server` — required, the name the server's tools are offered under.
    * `:transport` — required, `{module, config}`.
    * `:timeout` — how long any request after startup other than a tool call
      may take. Defaults to 30s. Given alone, it is also the startup and tool
      budget, which is what it used to mean.
    * `:startup_timeout` — the handshake and the first listing. Defaults to
      60s.
    * `:tool_timeout` — how long a tool call may go without an answer or a
      progress notification. Defaults to 10 minutes.
    * `:owner` — a process to follow. When it goes, so does this client: a
      server outliving the session that started it is a subprocess nobody is
      left to stop.
    * `:notify` — where change notifications are sent. Defaults to `:owner`.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  Lists the tools this server offers, following pagination to the end.

  Names are settled with `Lemieux.MCP.RemoteTool.assign_names/1`, so what
  comes back can be offered to any provider as it is.
  """
  @spec list_tools(client :: client()) :: {:ok, [RemoteTool.t()]} | {:error, String.t()}
  def list_tools(client), do: GenServer.call(client, :list_tools, :infinity)

  @doc """
  Calls a tool by its *unqualified* name — the name the server knows it by.
  """
  @spec call_tool(client :: client(), name :: String.t(), arguments :: map(), extra :: map()) ::
          {:ok, Lemieux.Tool.Result.t()}
          | {:error, Lemieux.Tool.Result.t() | String.t()}
          | {:input_required, map(), String.t() | nil}
  def call_tool(client, name, arguments, extra \\ %{}),
    do: GenServer.call(client, {:call_tool, name, arguments, extra}, :infinity)

  @doc """
  Lists the prompts this server offers, in the server's own shape.

  A server that did not declare the `prompts` capability, or answers that it
  has no such method, has none: an empty list rather than an error, because a
  host asking every server for its prompts should not report every server
  that simply has nothing to offer.
  """
  @spec list_prompts(client :: client()) :: {:ok, [map()]} | {:error, String.t()}
  def list_prompts(client), do: GenServer.call(client, {:list, :prompts}, :infinity)

  @doc """
  Fills in one prompt. `arguments` are its string arguments by name.

  Returns the server's `prompts/get` result, whose messages
  `Lemieux.MCP.Protocol.prompt_text/1` flattens into what a person would send.
  """
  @spec get_prompt(client :: client(), name :: String.t(), arguments :: map()) ::
          {:ok, map()} | {:error, String.t()}
  def get_prompt(client, name, arguments \\ %{}),
    do:
      GenServer.call(
        client,
        {:get, "prompts/get", %{"name" => name, "arguments" => arguments}},
        :infinity
      )

  @doc """
  Lists the resources this server offers, in the server's own shape.

  Empty rather than an error for a server without the capability, for the
  same reason as `list_prompts/1`.
  """
  @spec list_resources(client :: client()) :: {:ok, [map()]} | {:error, String.t()}
  def list_resources(client), do: GenServer.call(client, {:list, :resources}, :infinity)

  @doc """
  Reads one resource by URI. Returns the server's `resources/read` result.
  """
  @spec read_resource(client :: client(), uri :: String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def read_resource(client, uri),
    do: GenServer.call(client, {:get, "resources/read", %{"uri" => uri}}, :infinity)

  @doc """
  What the client worked out about the server.

  Its era and chosen version, whether it is usable, why not, whether it
  needs somebody to sign in (`:needs_auth`, see `t:needs_auth/0`), the
  capabilities it declared, and the notices from its last tool listing —
  tools renamed to fit a provider, or left out.
  """
  @spec info(client :: client()) :: map()
  def info(client), do: GenServer.call(client, :info, :infinity)

  @impl GenServer
  def init(opts) do
    # Stdio transports own a linked port, and its OS process may disappear with an
    # `:epipe` exit signal — one broken MCP server rather than a reason for this
    # client to die before it can answer the waiting session. Non-transport exits are
    # still stopped on explicitly in `handle_info/2`, preserving the supervisor's
    # authority.
    Process.flag(:trap_exit, true)

    {module, config} = Keyword.fetch!(opts, :transport)
    owner = Keyword.get(opts, :owner)
    timeout = Keyword.get(opts, :timeout)

    state = %{
      server: Keyword.fetch!(opts, :server),
      module: module,
      transport: nil,
      mode: :serial,
      started?: false,
      timeout: timeout || @timeout,
      startup_timeout: Keyword.get(opts, :startup_timeout) || timeout || @startup_timeout,
      tool_timeout: Keyword.get(opts, :tool_timeout) || timeout || @tool_timeout,
      era: nil,
      version: nil,
      server_info: nil,
      capabilities: nil,
      next_id: 1,
      failure: nil,
      needs_auth: nil,
      owner_ref: owner && Process.monitor(owner),
      notify: Keyword.get(opts, :notify, owner),
      pending: %{},
      monitors: %{},
      listed?: false,
      notices: [],
      refresh: nil
    }

    case module.connect(config) do
      {:ok, transport} -> {:ok, %{state | transport: transport}, {:continue, :probe}}
      # Not a crash: a server that cannot start is a configuration problem, and
      # the session it belongs to should keep working without its tools.
      {:error, reason} -> {:ok, fail(state, reason)}
    end
  end

  @impl GenServer
  def handle_continue(:probe, state) do
    state = probe(state)

    # The handshake was made one request at a time on purpose — nothing else
    # can be in flight yet — and only now may the transport's own mode apply.
    state =
      if is_nil(state.failure),
        do: %{state | started?: true, mode: transport_mode(state)},
        else: state

    {:noreply, state}
  end

  # Anything a transport says other than the three modes is read as serial,
  # the one mode every transport supports.
  defp transport_mode(%{module: module, transport: transport}) do
    with true <- function_exported?(module, :mode, 1),
         mode when mode in [:duplex, :independent] <- module.mode(transport) do
      mode
    else
      _serial -> :serial
    end
  end

  defp probe(state) do
    case sync_request(state, :modern, "server/discover", %{}, state.startup_timeout) do
      {:ok, %{"result" => result}, state} ->
        modern(state, Map.get(result, "supportedVersions"), result)

      {:ok, %{"error" => error}, state} ->
        era_from_error(state, error)

      {:error, reason, state} ->
        fail(state, reason)
    end
  end

  defp era_from_error(state, error) do
    case Protocol.classify(error) do
      {:modern, versions} -> modern(state, versions, %{})
      :legacy -> initialize(state)
    end
  end

  defp modern(state, versions, result) when is_list(versions) and versions != [] do
    case Protocol.choose(versions) do
      {:ok, version} -> modern_state(state, version, result)
      {:error, reason} -> fail(state, reason)
    end
  end

  # A modern server that named no versions is taken at its word that it speaks
  # the revision we asked it about, since that is what it just answered.
  defp modern(state, _versions, result),
    do: modern_state(state, Protocol.modern_version(), result)

  defp modern_state(state, version, result) do
    %{
      state
      | era: :modern,
        version: version,
        server_info: modern_server_info(result),
        capabilities: json_map(Map.get(result, "capabilities"))
    }
  end

  defp initialize(state) do
    params = %{
      "protocolVersion" => Protocol.newest_legacy_version(),
      "capabilities" => %{},
      "clientInfo" => %{"name" => "lemieux", "version" => Lemieux.version()}
    }

    case sync_request(state, :legacy, "initialize", params, state.startup_timeout) do
      {:ok, %{"result" => result}, state} ->
        state = %{
          state
          | era: :legacy,
            version: Map.get(result, "protocolVersion"),
            server_info: Map.get(result, "serverInfo"),
            capabilities: json_map(Map.get(result, "capabilities"))
        }

        send_message(state, Protocol.notification("notifications/initialized"))

      {:ok, %{"error" => error}, state} ->
        fail(state, "the server refused to initialize: #{message(error)}")

      {:error, reason, state} ->
        fail(state, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Calls
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_call(:info, _from, state) do
    info = %{
      server: state.server,
      era: state.era,
      version: state.version,
      server_info: state.server_info,
      capabilities: state.capabilities,
      ready?: is_nil(state.failure),
      failure: state.failure,
      needs_auth: state.needs_auth,
      notices: state.notices,
      mode: state.mode
    }

    {:reply, info, state}
  end

  def handle_call(_request, _from, %{failure: failure} = state) when is_binary(failure),
    do: {:reply, {:error, failure}, state}

  def handle_call(:list_tools, from, state) do
    timeout = if state.listed?, do: state.timeout, else: state.startup_timeout

    state =
      collect_tools(state, [timeout: timeout, from: from], fn result, state ->
        GenServer.reply(from, result)
        state
      end)

    {:noreply, state}
  end

  def handle_call({:call_tool, name, arguments, extra}, from, state) do
    # `requestState` is echoed back exactly as it arrived: it is the server's
    # own memory of an unfinished call, and the specification forbids a client
    # inspecting or changing it.
    params = Map.merge(%{"name" => name, "arguments" => arguments}, extra)
    opts = [timeout: state.tool_timeout, from: from, progress: true]

    state =
      dispatch(state, "tools/call", params, opts, fn result, state ->
        GenServer.reply(from, tool_reply(result))
        state
      end)

    {:noreply, state}
  end

  def handle_call({:list, kind}, from, state) do
    if declared?(state, kind) do
      method = "#{kind}/list"
      opts = [timeout: state.timeout, from: from]

      state =
        collect(state, method, nil, [], opts, &parse_list(kind, &1), fn result, state ->
          GenServer.reply(from, list_reply(result))
          state
        end)

      {:noreply, state}
    else
      {:reply, {:ok, []}, state}
    end
  end

  def handle_call({:get, method, params}, from, state) do
    state =
      dispatch(state, method, params, [timeout: state.timeout, from: from], fn result, state ->
        GenServer.reply(from, result_reply(result))
        state
      end)

    {:noreply, state}
  end

  defp tool_reply({:ok, %{"result" => result}}), do: Protocol.output(result)
  defp tool_reply({:ok, %{"error" => error}}), do: {:error, message(error)}
  defp tool_reply({:error, reason}), do: {:error, describe(reason)}

  defp result_reply({:ok, %{"result" => result}}) when is_map(result), do: {:ok, result}
  defp result_reply({:ok, %{"error" => error}}), do: {:error, message(error)}
  defp result_reply({:ok, other}), do: {:error, "an unreadable response: #{inspect(other)}"}
  defp result_reply({:error, reason}), do: {:error, describe(reason)}

  # A server that never declared the capability is not asked. One that
  # declared nothing at all — the capabilities field absent — is asked, and
  # "method not found" is read as none.
  defp declared?(%{capabilities: nil}, _kind), do: true
  defp declared?(%{capabilities: capabilities}, kind), do: Map.has_key?(capabilities, "#{kind}")

  defp list_reply({:ok, items}), do: {:ok, items}
  defp list_reply({:error, {:rpc, %{"code" => @method_not_found}}}), do: {:ok, []}
  defp list_reply({:error, {:rpc, error}}), do: {:error, message(error)}
  defp list_reply({:error, reason}), do: {:error, describe(reason)}

  defp parse_list(:prompts, result), do: Protocol.prompts(result)
  defp parse_list(:resources, result), do: Protocol.resources(result)

  defp collect_tools(state, opts, done) do
    collect(state, "tools/list", nil, [], opts, &{:ok, &1, Map.get(&1, "nextCursor")}, fn
      {:ok, results}, state ->
        {tools, state} = read_tools(state, results)
        done.({:ok, tools}, %{state | listed?: true})

      {:error, {:rpc, error}}, state ->
        done.({:error, message(error)}, state)

      {:error, reason}, state ->
        done.({:error, describe(reason)}, state)
    end)
  end

  # Pages are gathered raw and read together, so the tools are named against
  # the whole list rather than one page of it.
  defp read_tools(state, results) do
    {tools, problems} =
      Enum.reduce(results, {[], []}, fn result, {tools, problems} ->
        {:ok, page, _next, page_problems} =
          Protocol.tools_report(result, state.server,
            protocol_version: state.version,
            server_info: state.server_info
          )

        {tools ++ page, problems ++ page_problems}
      end)

    {tools, transport} = state.module.prepare_tools(state.transport, tools)
    {tools, renamed} = tools |> Enum.map(&%{&1 | client: self()}) |> RemoteTool.assign_names()

    # Informational: a host shows these from `info/1` beside the server's
    # state, where somebody looking for a missing tool will look.
    Enum.each(problems ++ renamed, &Logger.info("lemieux: #{&1}"))

    {tools, %{state | transport: transport, notices: problems ++ renamed}}
  end

  # A paginated listing. A server that keeps handing back the same cursor would
  # page forever; the only defence that does not need a heuristic is to stop
  # when the cursor stops changing.
  defp collect(state, method, cursor, acc, opts, parse, done) do
    params = if cursor, do: %{"cursor" => cursor}, else: %{}

    dispatch(state, method, params, opts, fn
      {:ok, %{"result" => result}}, state when is_map(result) ->
        case parse.(result) do
          {:ok, items, next} when is_binary(next) and next != cursor ->
            collect(state, method, next, acc ++ page(items), opts, parse, done)

          {:ok, items, _next} ->
            done.({:ok, acc ++ page(items)}, state)
        end

      {:ok, %{"error" => error}}, state ->
        done.({:error, {:rpc, error}}, state)

      {:ok, other}, state ->
        done.({:error, "an unreadable response: #{inspect(other)}"}, state)

      {:error, reason}, state ->
        done.({:error, reason}, state)
    end)
  end

  # A tools listing is collected as whole results, the others as their items.
  defp page(items) when is_list(items), do: items
  defp page(result) when is_map(result), do: [result]

  # ---------------------------------------------------------------------------
  # The request machinery
  # ---------------------------------------------------------------------------

  # Sends one request and arranges for `continue` to run with its outcome —
  # `{:ok, response}` or `{:error, reason}` — and the state at that time. Inline
  # for a serial transport; for the others, whenever the answer arrives.
  defp dispatch(state, method, params, opts, continue) do
    id = state.next_id
    state = %{state | next_id: id + 1}
    params = if Keyword.get(opts, :progress), do: progress(params, id), else: params
    request = Protocol.request(state.era, method, params, id: id, version: state.version)
    timeout = Keyword.fetch!(opts, :timeout)

    case state.mode do
      :serial ->
        case send_request(state, request, timeout) do
          {:ok, response, state} -> continue.({:ok, response}, state)
          {:error, reason, state} -> continue.({:error, reason}, state)
        end

      :duplex ->
        case state.module.notify(state.transport, request) do
          {:ok, transport} ->
            %{state | transport: transport}
            |> track(id, entry(continue, timeout, nil), Keyword.get(opts, :from))
            |> arm(id)

          {:error, reason, transport} ->
            continue.({:error, reason}, %{state | transport: transport})
        end

      # No deadline of the client's own: the call's process enforces the
      # timeout as silence on the socket, which is what lets a stream of
      # progress keep a long call alive, and an abandoned call is killed.
      :independent ->
        task = spawn_call(state, id, request, timeout)
        track(state, id, entry(continue, timeout, task), Keyword.get(opts, :from))
    end
  end

  defp entry(continue, timeout, task),
    do: %{continue: continue, timeout: timeout, timer: nil, token: nil, task: task, caller: nil}

  defp progress(params, id) do
    Map.update(params, "_meta", %{"progressToken" => id}, &Map.put(&1, "progressToken", id))
  end

  defp track(state, id, entry, from) do
    state = %{state | pending: Map.put(state.pending, id, entry)}

    state =
      case entry.task do
        {_pid, ref} -> %{state | monitors: Map.put(state.monitors, ref, {:task, id})}
        nil -> state
      end

    watch_caller(state, id, from)
  end

  # Monitored per request rather than per caller, so a caller with two calls
  # in flight that goes away withdraws both, and a finished call releases its
  # own monitor.
  defp watch_caller(state, _id, nil), do: state

  defp watch_caller(state, id, {pid, _tag}) do
    ref = Process.monitor(pid)

    %{
      state
      | monitors: Map.put(state.monitors, ref, {:caller, id}),
        pending: Map.update!(state.pending, id, &%{&1 | caller: ref})
    }
  end

  # The deadline is a message rather than a receive timeout because it has to
  # move: every progress notification for the call re-arms it. The token is
  # what tells a deadline that was re-armed from one that is still current,
  # since cancelling a timer does not recall a message already sent.
  defp arm(state, id) do
    case Map.fetch(state.pending, id) do
      {:ok, %{task: nil, timeout: timeout} = entry} when is_integer(timeout) ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        token = make_ref()
        timer = Process.send_after(self(), {:mcp_deadline, id, token}, timeout)
        %{state | pending: Map.put(state.pending, id, %{entry | timer: timer, token: token})}

      _not_armed ->
        state
    end
  end

  defp spawn_call(state, id, request, timeout) do
    client = self()
    module = state.module
    transport = state.transport

    spawn_monitor(fn ->
      outcome =
        try do
          module.call(transport, request, timeout)
        catch
          kind, reason -> {:error, "the request failed: #{inspect({kind, reason})}", transport}
        end

      send(client, {:mcp_answer, id, outcome})
    end)
  end

  # Removes a request from everything that knows about it, returning its entry.
  defp untrack(state, id) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {nil, state}

      {entry, pending} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)

        monitors =
          Enum.reduce([entry.caller, task_ref(entry.task)], state.monitors, fn
            nil, monitors ->
              monitors

            ref, monitors ->
              Process.demonitor(ref, [:flush])
              Map.delete(monitors, ref)
          end)

        {entry, %{state | pending: pending, monitors: monitors}}
    end
  end

  defp task_ref({_pid, ref}), do: ref
  defp task_ref(nil), do: nil

  defp complete(state, id, outcome) do
    case untrack(state, id) do
      {nil, state} -> state
      {entry, state} -> entry.continue.(outcome, state)
    end
  end

  # Withdraws a request nobody will read the answer to: the server is told, so
  # it can stop, and an independent call's process is stopped here.
  defp abandon(state, id, reason) do
    case untrack(state, id) do
      {nil, state} ->
        state

      {entry, state} ->
        with {pid, _ref} <- entry.task, do: Process.exit(pid, :kill)
        cancel_on_wire(state, id, reason)
    end
  end

  defp cancel_on_wire(state, id, reason) do
    notification =
      Protocol.notification("notifications/cancelled", %{"requestId" => id, "reason" => reason})

    case state.mode do
      :independent ->
        # Its own process: a cancellation is a POST like any other, and the
        # client should not wait on it to go on serving the next call.
        module = state.module
        transport = state.transport
        spawn(fn -> module.notify(transport, notification) end)
        state

      _duplex ->
        send_message(state, notification)
    end
  end

  # ---------------------------------------------------------------------------
  # Messages
  # ---------------------------------------------------------------------------

  @impl GenServer
  def handle_info({:mcp_deadline, id, token}, state) do
    case Map.fetch(state.pending, id) do
      {:ok, %{token: ^token, timeout: timeout}} ->
        state = cancel_on_wire(state, id, "timed out")
        message = "the MCP server #{state.server} did not answer within #{seconds(timeout)}"
        {:noreply, complete(state, id, {:error, message})}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_answer, id, outcome}, state) do
    {outcome, state} =
      case outcome do
        {:ok, response, transport} -> {{:ok, response}, absorb(state, transport)}
        {:error, reason, transport} -> {{:error, reason}, absorb(state, transport)}
      end

    {:noreply, complete(state, id, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.owner_ref ->
        # The session this client belongs to has finished. Nothing is left to
        # answer for, and the server it is holding open should not outlive it.
        {:stop, :normal, state}

      match?({:caller, _id}, state.monitors[ref]) ->
        {:caller, id} = state.monitors[ref]
        {:noreply, abandon(state, id, "the caller went away")}

      match?({:task, _id}, state.monitors[ref]) ->
        {:task, id} = state.monitors[ref]
        message = "the request to the MCP server #{state.server} failed: #{inspect(reason)}"
        {:noreply, complete(state, id, {:error, message})}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(message, %{mode: :duplex} = state) do
    case state.module.handle_message(state.transport, message) do
      {:ok, messages, transport} ->
        {:noreply, Enum.reduce(messages, %{state | transport: transport}, &incoming(&2, &1))}

      {:closed, reason, transport} ->
        {:noreply, closed(%{state | transport: transport}, reason)}

      :unknown ->
        other(message, state)
    end
  end

  def handle_info(message, state), do: other(message, state)

  defp other({:EXIT, port, reason}, %{transport: %{port: port}} = state) when is_port(port) do
    {:noreply, closed(state, "the MCP server #{state.server} stopped: #{inspect(reason)}")}
  end

  defp other({:EXIT, _linked, reason}, state), do: {:stop, reason, state}
  defp other(_message, state), do: {:noreply, state}

  # Folds an independent call's state back in, and hears whatever the server
  # said beside its answer.
  defp absorb(state, returned) do
    transport =
      if function_exported?(state.module, :merge, 2),
        do: state.module.merge(state.transport, returned),
        else: returned

    drained(%{state | transport: transport})
  end

  defp drained(state) do
    if function_exported?(state.module, :drain, 1) do
      {messages, transport} = state.module.drain(state.transport)
      Enum.reduce(messages, %{state | transport: transport}, &incoming(&2, &1))
    else
      state
    end
  end

  # A reply to something we asked.
  defp incoming(state, %{"id" => id} = message)
       when is_map_key(message, "result") or is_map_key(message, "error"),
       do: complete(state, id, {:ok, message})

  # A request the server is making of us.
  defp incoming(state, %{"id" => id, "method" => "ping"}),
    do: send_message(state, Protocol.response(id, %{}))

  defp incoming(state, %{"id" => id, "method" => method}),
    do:
      send_message(
        state,
        Protocol.error_response(id, @method_not_found, "lemieux does not offer #{method}")
      )

  defp incoming(state, %{
         "method" => "notifications/progress",
         "params" => %{"progressToken" => id}
       }),
       do: arm(state, id)

  defp incoming(state, %{"method" => "notifications/tools/list_changed"}), do: refresh(state)

  defp incoming(state, %{"method" => "notifications/prompts/list_changed"}),
    do:
      announce(
        state,
        {:mcp_list_changed, %{server: state.server, client: self(), kind: :prompts}}
      )

  defp incoming(state, %{"method" => "notifications/resources/list_changed"}),
    do:
      announce(
        state,
        {:mcp_list_changed, %{server: state.server, client: self(), kind: :resources}}
      )

  defp incoming(state, %{"method" => "notifications/message", "params" => params}) do
    Logger.debug(
      "lemieux: the MCP server #{state.server} logged: #{inspect(Map.get(params, "data"))}"
    )

    state
  end

  defp incoming(state, _message), do: state

  # One refresh at a time. A change announced while a refresh is in flight
  # may not be in its answer, so it earns exactly one more, not one each.
  defp refresh(%{refresh: nil, started?: true} = state) do
    state = %{state | refresh: :running}

    collect_tools(state, [timeout: state.timeout], fn
      {:ok, tools}, state ->
        state =
          announce(
            state,
            {:mcp_tools_changed,
             %{server: state.server, client: self(), tools: tools, notices: state.notices}}
          )

        again(state)

      {:error, reason}, state ->
        Logger.warning("lemieux: could not list the changed tools of #{state.server}: #{reason}")
        again(state)
    end)
  end

  defp refresh(%{refresh: :running} = state), do: %{state | refresh: :again}
  defp refresh(state), do: state

  defp again(%{refresh: :again} = state), do: refresh(%{state | refresh: nil})
  defp again(state), do: %{state | refresh: nil}

  defp announce(%{notify: nil} = state, _event), do: state

  defp announce(%{notify: notify} = state, event) do
    send(notify, event)
    state
  end

  # The server has gone. Everything in flight fails with the reason, and
  # everything after it answers the same.
  defp closed(state, reason) do
    state = fail(state, reason)

    state.pending
    |> Map.keys()
    |> Enum.reduce(state, &complete(&2, &1, {:error, state.failure}))
  end

  # ---------------------------------------------------------------------------
  # Wire helpers
  # ---------------------------------------------------------------------------

  defp sync_request(state, era, method, params, timeout) do
    id = state.next_id
    request = Protocol.request(era, method, params, id: id, version: state.version)
    send_request(%{state | next_id: id + 1}, request, timeout)
  end

  defp send_request(state, request, timeout) do
    case state.module.call(state.transport, request, timeout) do
      {:ok, response, transport} -> {:ok, response, drained(%{state | transport: transport})}
      {:error, reason, transport} -> {:error, reason, drained(%{state | transport: transport})}
    end
  catch
    # A port whose OS process died between the liveness check and the write
    # exits its caller with `:epipe`. That is transport failure, not a reason
    # to take down this client and the session waiting on it. Keep the last
    # transport state so `terminate/2` can close whatever remains.
    :exit, reason ->
      {:error, "the MCP server #{state.server} stopped: #{inspect(reason)}", state}
  end

  defp send_message(state, message) do
    case state.module.notify(state.transport, message) do
      {:ok, transport} -> %{state | transport: transport}
      {:error, reason, transport} -> fail(%{state | transport: transport}, reason)
    end
  catch
    :exit, reason -> fail(state, "the MCP server #{state.server} stopped: #{inspect(reason)}")
  end

  # A server that needs somebody to sign in is not broken, and is reported as
  # something a host can act on rather than only as a sentence.
  defp fail(state, {:needs_auth, info}) when is_map(info) do
    needs_auth = Map.put(info, :server, state.server)

    %{
      state
      | needs_auth: needs_auth,
        failure: "the MCP server #{state.server} needs authorization; sign in to use its tools"
    }
  end

  defp fail(%{failure: failure} = state, _reason) when is_binary(failure), do: state
  defp fail(state, reason), do: %{state | failure: describe(reason)}

  defp modern_server_info(result) do
    get_in(result, ["_meta", "io.modelcontextprotocol/serverInfo"])
  end

  defp seconds(timeout) when is_integer(timeout), do: "#{div(timeout, 1000)}s"
  defp seconds(timeout), do: inspect(timeout)

  defp message(%{"message" => message}), do: message
  defp message(error), do: inspect(error)

  defp describe(reason) when is_binary(reason), do: reason
  defp describe({:needs_auth, _info}), do: "needs authorization"
  defp describe(reason), do: inspect(reason)

  defp json_map(value) when is_map(value), do: value
  defp json_map(_value), do: nil

  @impl GenServer
  def terminate(_reason, state) do
    for {_id, %{task: {pid, _ref}}} <- state.pending, do: Process.exit(pid, :kill)
    if state.transport, do: state.module.close(state.transport)
    :ok
  end
end
