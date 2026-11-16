defmodule Lemieux.CLI.ACP.Server do
  @moduledoc false
  use GenServer

  alias Lemieux.CLI.ACP.ConfigOptions
  alias Lemieux.CLI.ACP.Questions
  alias Lemieux.CLI.ACP.Setup
  alias Lemieux.CLI.ACP.Tool
  alias Lemieux.CLI.ACP.Wire
  alias Lemieux.CLI.Config, as: CLIConfig
  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.SessionIndex
  alias Lemieux.Harness
  alias Lemieux.MCP.Config
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Transcript

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def receive_line(server, line), do: GenServer.cast(server, {:line, line})
  def receive_message(server, message), do: GenServer.cast(server, {:message, message})

  @spec client_request(
          server :: pid(),
          session_id :: String.t(),
          method :: String.t(),
          params :: map()
        ) ::
          {:ok, map()} | {:error, atom()}
  def client_request(server, session_id, method, params),
    do: GenServer.call(server, {:client_request, session_id, method, params}, :infinity)

  @spec tool_event(
          server :: pid(),
          session_id :: String.t(),
          call_id :: String.t(),
          event :: tuple()
        ) :: :ok
  def tool_event(server, session_id, call_id, event),
    do: GenServer.call(server, {:tool_event, session_id, call_id, event}, :infinity)

  @impl true
  def init(opts) do
    {:ok,
     %{
       options: Keyword.fetch!(opts, :options),
       argv: Keyword.get(opts, :argv),
       host: Keyword.fetch!(opts, :host),
       emit: Keyword.fetch!(opts, :emit),
       version: nil,
       used?: false,
       questions?: false,
       filesystem: %{},
       elicitation?: false,
       auth_methods: [],
       sessions: %{},
       pending: %{},
       serial: 0
     }}
  end

  @impl true
  def handle_cast({:line, line}, state) do
    case JSON.decode(line) do
      {:ok, message} -> {:noreply, dispatch(message, state)}
      {:error, _reason} -> {:noreply, failure(state, nil, -32_700, "Invalid JSON")}
    end
  end

  def handle_cast({:message, message}, state), do: {:noreply, dispatch(message, state)}

  @impl true
  def handle_call({:client_request, session_id, method, params}, from, state) do
    if Map.has_key?(state.sessions, session_id) do
      request_id = "lmx-#{state.serial + 1}"
      monitor = Process.monitor(elem(from, 0))
      timer = Process.send_after(self(), {:client_timeout, request_id}, 30_000)
      params = Map.put(params, "sessionId", session_id)

      state.emit.(%{
        "jsonrpc" => "2.0",
        "id" => request_id,
        "method" => method,
        "params" => params
      })

      pending = %{
        kind: :filesystem,
        session_id: session_id,
        from: from,
        monitor: monitor,
        timer: timer
      }

      {:noreply,
       %{state | serial: state.serial + 1, pending: Map.put(state.pending, request_id, pending)}}
    else
      {:reply, {:error, :ecanceled}, state}
    end
  end

  def handle_call({:tool_event, id, call_id, event}, _from, state),
    do: {:reply, :ok, tool_update(state, id, call_id, event)}

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = message, state)
       when is_binary(method) do
    params = Map.get(message, "params", %{})

    cond do
      not Map.has_key?(message, "id") ->
        notification(method, params, state)

      not (is_nil(message["id"]) or is_binary(message["id"]) or is_integer(message["id"])) ->
        failure(state, nil, -32_600, "Invalid request id")

      is_map(params) ->
        state =
          if method != "initialize" and state.version != nil,
            do: %{state | used?: true},
            else: state

        request(method, params, message["id"], state)

      true ->
        failure(state, message["id"], -32_602, "Parameters must be an object")
    end
  end

  defp dispatch(%{"jsonrpc" => "2.0", "id" => id} = message, state),
    do: client_reply(id, message, state)

  defp dispatch(_message, state), do: failure(state, nil, -32_600, "Invalid request")

  defp notification("session/cancel", params, %{version: version} = state)
       when not is_nil(version) and is_map(params) do
    case session(state, params) do
      {:ok, session} -> Session.cancel(session.pid)
      _unknown -> :ok
    end

    state
  end

  defp notification(_method, _params, state), do: state

  defp request(
         "initialize",
         %{"protocolVersion" => requested} = params,
         id,
         %{version: nil} = state
       )
       when is_integer(requested) and requested >= 1 and requested <= 65_535 do
    version = if requested == 1, do: 1, else: 2
    supplied = params["capabilities"] || params["clientCapabilities"]
    capabilities = if is_map(supplied), do: supplied, else: %{}
    questions? = match?(%{"_meta" => %{"lemieux" => %{"question" => true}}}, capabilities)

    filesystem = filesystem(version, capabilities)

    state = %{
      state
      | version: version,
        questions?: questions?,
        filesystem: filesystem,
        elicitation?:
          match?(%{"elicitation" => %{"form" => form}} when is_map(form), capabilities)
    }

    methods =
      if CLIConfig.path(state.options.config),
        do: Setup.methods(version, state.argv || [], capabilities),
        else: []

    state = %{state | auth_methods: methods}
    reply(state, id, Wire.initialize(version, methods))
  end

  defp request("initialize", params, id, %{version: 2, used?: false} = state) do
    initialized = request("initialize", params, id, %{state | version: nil})
    if is_nil(initialized.version), do: %{initialized | version: 2}, else: initialized
  end

  defp request("initialize", %{"protocolVersion" => 0}, id, %{version: nil} = state),
    do:
      failure(state, id, -32_022, "Unsupported protocol version", %{
        "requested" => 0,
        "supported" => [1, 2]
      })

  defp request("initialize", _params, id, %{version: nil} = state),
    do: failure(state, id, -32_602, "protocolVersion must be an integer from 0 to 65535")

  defp request("initialize", _params, id, state),
    do: failure(state, id, -32_600, "Initialization is already complete")

  defp request(_method, _params, id, %{version: nil} = state),
    do: failure(state, id, -32_600, "Initialize first")

  defp request(method, params, id, state)
       when method in ["session/new", "session/load", "session/resume"] do
    with {:ok, state} <- refresh(state),
         :ok <- workspace(params),
         :ok <- replay_cursor(params),
         :ok <- credentials(state),
         true <-
           Map.has_key?(state.sessions, params["sessionId"]) or map_size(state.sessions) < 16,
         {:ok, servers} <- servers(params),
         {:ok, state, session_id} <- open_session(method, params, servers, state) do
      replay? = method == "session/load" or params["replayFrom"] == %{"type" => "start"}
      if replay?, do: replay(state, session_id)
      if state.version == 2 and method == "session/resume", do: resume_updates(state, session_id)
      session = state.sessions[session_id]
      options = ConfigOptions.list(session.pid, state.version)
      state = put_session(state, session_id, %{session | config_options: options})

      reply(state, id, %{
        "sessionId" => session_id,
        "configOptions" => options
      })
    else
      false ->
        failure(state, id, -32_603, "Connection session limit reached")

      {:error, :authentication_required} ->
        if state.auth_methods == [],
          do: failure(state, id, -32_602, "Configure provider credentials with lmx acp setup"),
          else:
            failure(state, id, -32_000, "Configure Lemieux to continue", %{
              "authMethods" => state.auth_methods
            })

      {:error, reason} ->
        operation_error(state, id, reason)
    end
  end

  defp request("session/list", params, id, state) do
    store = Runtime.store(state.options, state.host)

    with :ok <- list_workspace(params["cwd"]),
         {:ok, offset} <- cursor(params["cursor"]),
         {:ok, items} <- SessionIndex.recent(store, limit: offset + 51, cwd: params["cwd"]) do
      page = items |> Enum.drop(offset) |> Enum.take(50)
      result = %{"sessions" => Enum.map(page, &descriptor/1)}

      result =
        if length(items) > offset + 50,
          do: Map.put(result, "nextCursor", to_string(offset + 50)),
          else: result

      reply(state, id, result)
    else
      {:error, _reason} -> failure(state, id, -32_602, "Invalid session list or cursor")
    end
  end

  defp request("session/prompt", params, id, state) do
    with {:ok, session} <- session(state, params),
         {:ok, text} <- prompt_text(params["prompt"]) do
      case Session.prompt(session.pid, text) do
        :ok ->
          update(state, params["sessionId"], running(state.version))
          put_session(state, params["sessionId"], %{session | prompt: id})

        {:error, :busy} when state.version == 2 and length(session.queued) < 16 ->
          put_session(state, params["sessionId"], %{
            session
            | queued: [{id, text} | session.queued]
          })

        {:error, reason} ->
          operation_error(state, id, reason)
      end
    else
      {:error, reason} -> operation_error(state, id, reason)
    end
  end

  defp request("session/cancel", params, id, state) do
    with {:ok, session} <- session(state, params), :ok <- Session.cancel(session.pid) do
      reply(state, id, %{})
    else
      {:error, reason} -> operation_error(state, id, reason)
    end
  end

  defp request("session/close", params, id, state) do
    case session(state, params) do
      {:ok, session} ->
        Session.cancel(session.pid)
        Runtime.stop_session(session.pid)
        state = finish(state, params["sessionId"], :cancelled)
        state = %{state | sessions: Map.delete(state.sessions, params["sessionId"])}
        reply(state, id, %{})

      {:error, {:unknown_session, _id}} ->
        reply(state, id, %{})

      {:error, reason} ->
        operation_error(state, id, reason)
    end
  end

  defp request("_lemieux/steer", params, id, state) do
    with {:ok, session} <- session(state, params),
         text when is_binary(text) <- params["text"],
         :ok <- Session.steer(session.pid, text) do
      reply(state, id, %{})
    else
      _error -> failure(state, id, -32_602, "Invalid steering request")
    end
  end

  defp request("_lemieux/fork", params, id, state) do
    with {:ok, session} <- session(state, params),
         %{status: :idle, cwd: cwd} <- Session.info(session.pid),
         {:ok, selector} <- fork_selector(params),
         {:ok, forked} <-
           Transcript.fork(
             Runtime.store(state.options, state.host),
             params["sessionId"],
             selector
           ),
         {:ok, state, forked} <-
           open_session("session/resume", %{"sessionId" => forked, "cwd" => cwd}, [], state) do
      reply(state, id, %{"sessionId" => forked})
    else
      _error ->
        failure(
          state,
          id,
          -32_602,
          "Fork requires an idle session and a safe transcript boundary"
        )
    end
  end

  defp request("_lemieux/configure", params, id, state) do
    with {:ok, session} <- session(state, params),
         :ok <- configure(session.pid, Map.delete(params, "sessionId")) do
      info = Session.info(session.pid)
      reply(state, id, %{"model" => info.model, "reasoningEffort" => info.reasoning_effort})
    else
      _error ->
        failure(
          state,
          id,
          -32_602,
          "Configure accepts one supported model or reasoningEffort setting on an idle session"
        )
    end
  end

  defp request("session/set_config_option", params, id, state) do
    with {:ok, session} <- session(state, params),
         :ok <- ConfigOptions.set(session.pid, params, state.version) do
      state = config_update(state, params["sessionId"])
      reply(state, id, %{"configOptions" => state.sessions[params["sessionId"]].config_options})
    else
      {:error, {:unknown_session, _id} = reason} -> operation_error(state, id, reason)
      _error -> failure(state, id, -32_602, "Unsupported or busy session configuration")
    end
  end

  defp request(_method, _params, id, state),
    do: failure(state, id, -32_601, "Method not supported")

  defp filesystem(1, capabilities) do
    %{
      read: match?(%{"fs" => %{"readTextFile" => true}}, capabilities),
      write: match?(%{"fs" => %{"writeTextFile" => true}}, capabilities)
    }
  end

  defp filesystem(_version, _capabilities), do: %{}

  defp configure(pid, %{"model" => model} = values)
       when map_size(values) == 1 and is_binary(model),
       do: configured(Session.set_model(pid, model))

  defp configure(pid, %{"reasoningEffort" => effort} = values)
       when map_size(values) == 1 and is_binary(effort),
       do: configured(Session.set_reasoning_effort(pid, effort))

  defp configure(_pid, _values), do: {:error, :invalid_configuration}
  defp configured({:ok, _value}), do: :ok
  defp configured(error), do: error
  defp fork_selector(%{"atSeq" => seq}) when is_integer(seq) and seq >= 0, do: {:ok, {:seq, seq}}
  defp fork_selector(%{"atSeq" => _invalid}), do: {:error, :invalid_selector}
  defp fork_selector(_params), do: {:ok, nil}

  defp workspace(%{"cwd" => cwd} = params) when is_binary(cwd) do
    if Path.type(cwd) == :absolute and File.dir?(cwd) and
         Map.get(params, "additionalDirectories", []) == [],
       do: :ok,
       else:
         {:error, "cwd must be an existing absolute directory; additional roots are unsupported"}
  end

  defp workspace(_params), do: {:error, "cwd is required"}

  defp list_workspace(nil), do: :ok

  defp list_workspace(cwd) when is_binary(cwd) do
    if Path.type(cwd) == :absolute, do: :ok, else: {:error, :invalid_cwd}
  end

  defp list_workspace(_cwd), do: {:error, :invalid_cwd}

  defp replay_cursor(%{"replayFrom" => cursor}) when cursor not in [nil, %{"type" => "start"}],
    do: {:error, "Unsupported replay cursor"}

  defp replay_cursor(_params), do: :ok

  defp servers(params) do
    values = Map.get(params, "mcpServers", [])

    if is_list(values) and Enum.all?(values, &stdio_server?/1) and unique_servers?(values),
      do: {:ok, Enum.flat_map(values, &server_config/1)},
      else: {:error, "Only valid stdio MCP servers are supported"}
  end

  defp unique_servers?(servers) do
    names = Enum.map(servers, & &1["name"])
    length(names) == length(Enum.uniq(names))
  end

  defp stdio_server?(%{"name" => name, "command" => command} = server) do
    is_binary(name) and name != "" and is_binary(command) and command != "" and
      is_list(Map.get(server, "args", [])) and is_list(Map.get(server, "env", [])) and
      Enum.all?(Map.get(server, "args", []), &is_binary/1) and
      Enum.all?(Map.get(server, "env", []), fn
        %{"name" => key, "value" => value} -> is_binary(key) and is_binary(value)
        _invalid -> false
      end)
  end

  defp stdio_server?(_server), do: false

  defp refresh(%{argv: nil} = state), do: {:ok, state}

  defp refresh(state) do
    with {:ok, options} <- Options.parse(state.argv, command: :acp),
         do: {:ok, %{state | options: options}}
  end

  defp credentials(state) do
    if Keyword.has_key?(state.host, :provider) or state.options.base_url != nil or
         state.options.ixway != nil or state.options.host.route != nil or
         Models.credential(Lemieux.ModelSpec.provider(state.options.model), state.options.config) !=
           :missing,
       do: :ok,
       else: {:error, :authentication_required}
  end

  defp server_config(server) do
    env = Map.new(Map.get(server, "env", []), &{&1["name"], &1["value"]})

    Config.parse(
      %{
        server["name"] => %{
          "command" => server["command"],
          "args" => Map.get(server, "args", []),
          "env" => env
        }
      },
      source: "explicit"
    )
  end

  defp open_session(method, %{"sessionId" => id, "cwd" => cwd}, servers, state)
       when method != "session/new" and is_map_key(state.sessions, id) do
    session = state.sessions[id]

    case Session.info(session.pid) do
      %{status: :idle, cwd: ^cwd} when session.servers == servers ->
        {:ok, state, id}

      _busy_or_different ->
        {:error, "Session is busy or has a different workspace/MCP configuration"}
    end
  end

  defp open_session(method, params, servers, state) do
    resume = if method == "session/new", do: nil, else: params["sessionId"]
    options = %{state.options | resume: resume}
    host = Keyword.merge(state.host, cwd: params["cwd"], interactive?: true)

    with :ok <- resume_workspace(method, resume, params["cwd"], state),
         {:ok, prepared} <- Runtime.prepare(options, host),
         harness = Harness.append_mcp_servers(prepared.harness, servers),
         harness = %{harness | tools: Tool.attach(harness.tools, self(), state.filesystem)},
         {:ok, pid} <- Runtime.start(%{prepared | harness: harness}, subscriber: self()) do
      info = Session.info(pid)
      Process.monitor(pid)

      session = %{
        pid: pid,
        prompt: nil,
        queued: [],
        streamed: MapSet.new(),
        servers: servers,
        config_options: nil,
        diffs: %{}
      }

      {:ok, put_session(state, info.id, session), info.id}
    end
  end

  defp resume_workspace("session/new", _id, _cwd, _state), do: :ok

  defp resume_workspace(_method, id, cwd, state) when is_binary(id) do
    with false <- Map.has_key?(state.sessions, id),
         {:ok, entries} <- Store.read(Runtime.store(state.options, state.host), id),
         entry when not is_nil(entry) <- Enum.find(entries, &(&1.type == :session)),
         true <- entry.payload["cwd"] == cwd do
      :ok
    else
      {:error, _reason} -> {:error, {:unknown_session, id}}
      _invalid -> {:error, "Session is open or belongs to another workspace"}
    end
  end

  defp resume_workspace(_method, _id, _cwd, _state), do: {:error, "sessionId is required"}

  defp replay(state, id) do
    snapshot = Session.snapshot(state.sessions[id].pid)

    Enum.each(snapshot.entries, fn entry ->
      Enum.each(entry.payload["tool_calls"] || [], fn call ->
        update(
          state,
          id,
          Wire.tool(state.version, %{
            id: call["id"],
            name: call["name"],
            arguments: call["arguments"]
          })
        )
      end)

      update(state, id, Wire.entry(state.version, entry))
    end)
  end

  defp resume_updates(state, id) do
    entry = state.sessions[id].pid |> Session.snapshot() |> Map.fetch!(:entries) |> List.last()
    update(state, id, %{"sessionUpdate" => "state_update", "state" => "idle"})

    update(state, id, %{
      "sessionUpdate" => "session_info_update",
      "updatedAt" => DateTime.to_iso8601(entry.at)
    })
  end

  defp prompt_text(blocks) when is_list(blocks) and blocks != [] do
    if Enum.all?(blocks, &text_block?/1),
      do: {:ok, Enum.map_join(blocks, "\n", &block_text/1)},
      else: {:error, "Only text and resource links are supported"}
  end

  defp prompt_text(_blocks), do: {:error, "prompt must contain text or resource links"}
  defp text_block?(%{"type" => "text", "text" => text}), do: is_binary(text)

  defp text_block?(%{"type" => "resource_link", "uri" => uri, "name" => name}),
    do: is_binary(uri) and is_binary(name)

  defp text_block?(_block), do: false
  defp block_text(%{"type" => "text", "text" => text}), do: text
  defp block_text(%{"uri" => uri, "name" => name}), do: "Resource #{name}: #{uri}"

  @impl true
  def handle_info({:lemieux, id, event}, state) do
    if Map.has_key?(state.sessions, id),
      do: {:noreply, event(state, id, event)},
      else: {:noreply, state}
  end

  def handle_info({:acp_tool, id, call_id, event}, state) do
    {:noreply, tool_update(state, id, call_id, event)}
  end

  def handle_info({:client_timeout, request_id}, state) do
    {pending, remaining} = Map.pop(state.pending, request_id)
    if pending, do: release(pending, {:error, :etimedout})
    {:noreply, %{state | pending: remaining}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    pending =
      Map.reject(state.pending, fn {_id, pending} ->
        if Map.get(pending, :monitor) == ref do
          release(pending, {:error, :ecanceled})
          true
        else
          false
        end
      end)

    state = %{state | pending: pending}

    case Enum.find(state.sessions, fn {_id, session} -> session.pid == pid end) do
      {id, _session} ->
        state = finish(state, id, :error)
        {:noreply, %{state | sessions: Map.delete(state.sessions, id)}}

      nil ->
        {:noreply, state}
    end
  end

  defp event(state, id, {:text_delta, chunk}) do
    update(state, id, Wire.chunk("agent_message_chunk", chunk))
    session = state.sessions[id]
    put_session(state, id, %{session | streamed: MapSet.put(session.streamed, chunk.id)})
  end

  defp event(state, id, {:thinking_delta, chunk}) do
    update(state, id, Wire.chunk("agent_thought_chunk", chunk))
    state
  end

  defp event(state, id, {:entry, entry}) do
    state = accepted(state, id, entry)
    session = state.sessions[id]

    duplicate? =
      state.version == 1 and entry.type == :assistant and
        MapSet.member?(session.streamed, entry.id)

    unless duplicate?, do: update(state, id, entry_update(state, id, entry))

    if entry.type == :tool_result,
      do:
        put_session(state, id, %{
          session
          | diffs: Map.delete(session.diffs, entry.payload["call_id"])
        }),
      else: state
  end

  defp event(state, id, {:tool_call, call}) do
    update(state, id, Wire.tool(state.version, call, Session.info(state.sessions[id].pid).cwd))
    state
  end

  defp event(state, id, {:tool_approval, call}) do
    ask_client(
      state,
      id,
      call.id,
      :approval,
      "session/request_permission",
      Wire.permission(state.version, id, call)
    )
  end

  defp event(%{elicitation?: true} = state, id, {:question, question}) do
    ask_client(
      state,
      id,
      question.call_id,
      {:elicitation, question},
      "elicitation/create",
      Questions.request(id, question)
    )
  end

  defp event(%{questions?: true} = state, id, {:question, question}) do
    ask_client(state, id, question.call_id, :question, "_lemieux/question", %{
      "sessionId" => id,
      "question" => json_shape(question)
    })
  end

  defp event(state, id, {:question, question}) do
    Session.answer(
      state.sessions[id].pid,
      question.call_id,
      missing_answer(question, "unavailable")
    )

    state
  end

  defp event(state, id, {:finished, reason}), do: finish(state, id, reason)

  defp event(state, id, {changed, _previous, _current})
       when changed in [:model_changed, :reasoning_effort_changed] do
    config_update(state, id)
  end

  defp event(state, _id, _event), do: state

  defp entry_update(state, id, %{type: :tool_result} = entry) do
    packet = Wire.entry(state.version, entry)
    diffs = Map.get(state.sessions[id].diffs, entry.payload["call_id"], [])
    Map.update!(packet, "content", &(diffs ++ &1))
  end

  defp entry_update(state, _id, entry), do: Wire.entry(state.version, entry)

  defp tool_update(state, id, call_id, event) do
    case state.sessions do
      %{^id => session} ->
        packet = Wire.tool_event(call_id, event, state.version)
        update(state, id, packet)
        diffs = remember_diff(session.diffs, call_id, event, packet)
        put_session(state, id, %{session | diffs: diffs})

      _closed ->
        state
    end
  end

  defp remember_diff(diffs, call_id, {:diff, _path, _old, _new}, packet),
    do: Map.update(diffs, call_id, packet["content"], &Enum.take(&1 ++ packet["content"], 64))

  defp remember_diff(diffs, _call_id, _event, _packet), do: diffs

  defp config_update(state, id) do
    session = state.sessions[id]
    options = ConfigOptions.list(session.pid, state.version)

    if options != session.config_options,
      do:
        update(state, id, %{"sessionUpdate" => "config_option_update", "configOptions" => options})

    put_session(state, id, %{session | config_options: options})
  end

  defp accepted(%{version: 2} = state, id, %{type: :user, id: message_id}) do
    case state.sessions[id].prompt do
      nil ->
        state

      request_id ->
        reply(state, request_id, %{"messageId" => message_id})
        put_session(state, id, %{state.sessions[id] | prompt: nil})
    end
  end

  defp accepted(state, _id, _entry), do: state

  defp finish(state, id, reason) do
    session = state.sessions[id]

    terminal_reply(state, session.prompt, reason)

    if state.version == 2,
      do:
        update(state, id, %{
          "sessionUpdate" => "state_update",
          "state" => "idle",
          "stopReason" => if(reason == :error, do: "error", else: Wire.stop_reason(reason))
        })

    pending =
      Map.reject(state.pending, fn {_key, pending} ->
        if pending.session_id == id do
          release(pending, {:error, :ecanceled})
          true
        else
          false
        end
      end)

    state =
      put_session(%{state | pending: pending}, id, %{
        session
        | prompt: nil,
          queued: [],
          streamed: MapSet.new(),
          diffs: %{}
      })

    next_prompt(state, id, Enum.reverse(session.queued), reason)
  end

  defp next_prompt(state, _id, [], _reason), do: state

  defp next_prompt(state, _id, queued, reason) when reason in [:cancelled, :error] do
    Enum.each(queued, fn {request_id, _text} ->
      failure(state, request_id, -32_800, "Prompt cancelled before insertion")
    end)

    state
  end

  defp next_prompt(state, id, [{request_id, text} | rest], _reason) do
    session = state.sessions[id]

    case Session.prompt(session.pid, text) do
      :ok ->
        update(state, id, running(state.version))
        put_session(state, id, %{session | prompt: request_id, queued: Enum.reverse(rest)})

      {:error, reason} ->
        state = operation_error(state, request_id, reason)
        next_prompt(state, id, rest, :error)
    end
  end

  defp terminal_reply(_state, nil, _reason), do: :ok

  defp terminal_reply(state, request_id, :error),
    do:
      failure(
        state,
        request_id,
        -32_603,
        "Agent request failed; inspect the local transcript or log"
      )

  defp terminal_reply(%{version: 2} = state, request_id, _reason),
    do: failure(state, request_id, -32_800, "Prompt ended before its user message was committed")

  defp terminal_reply(state, request_id, reason),
    do: reply(state, request_id, %{"stopReason" => Wire.stop_reason(reason)})

  defp ask_client(state, id, call_id, kind, method, params) do
    request_id = "lmx-#{state.serial + 1}"
    state.emit.(%{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params})

    if state.version == 2,
      do: update(state, id, %{"sessionUpdate" => "state_update", "state" => "requires_action"})

    pending = %{
      session_id: id,
      call_id: call_id,
      kind: kind,
      questionnaire?: get_in(params, ["question", "questionnaire"]) == true
    }

    %{state | serial: state.serial + 1, pending: Map.put(state.pending, request_id, pending)}
  end

  defp client_reply(id, message, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{kind: :filesystem} = pending, remaining} ->
        result =
          case message do
            %{"result" => result} when is_map(result) -> {:ok, result}
            _invalid -> {:error, :eio}
          end

        release(pending, result)
        %{state | pending: remaining}

      {pending, remaining} ->
        pid = state.sessions[pending.session_id].pid
        resolve(pid, pending, message["result"])
        update(state, pending.session_id, running(state.version))
        %{state | pending: remaining}
    end
  end

  defp release(%{kind: :filesystem} = pending, result) do
    Process.cancel_timer(pending.timer)
    Process.demonitor(pending.monitor, [:flush])
    GenServer.reply(pending.from, result)
  end

  defp release(_pending, _result), do: :ok

  defp resolve(pid, %{kind: :approval, call_id: call}, result) do
    decision =
      if match?(%{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}, result),
        do: :allow,
        else: {:deny, "Client rejected permission"}

    Session.resolve_tool(pid, call, decision)
  end

  defp resolve(pid, %{kind: {:elicitation, question}, call_id: call}, result),
    do: Session.answer(pid, call, Questions.answer(question, result))

  defp resolve(pid, %{kind: :question, call_id: call}, %{"answer" => answer})
       when is_binary(answer) or is_map(answer),
       do: Session.answer(pid, call, answer)

  defp resolve(pid, %{kind: :question, call_id: call} = pending, _result),
    do:
      Session.answer(
        pid,
        call,
        missing_answer(%{questionnaire: pending.questionnaire?}, "cancelled")
      )

  defp missing_answer(%{questionnaire: true}, status), do: %{"status" => status}

  defp missing_answer(_question, "cancelled"),
    do: "Client cancelled the question; no answer was provided."

  defp missing_answer(_question, _status),
    do: "Client does not support questions; no answer was provided."

  defp running(2), do: %{"sessionUpdate" => "state_update", "state" => "running"}
  defp running(_version), do: nil

  defp session(state, %{"sessionId" => id}) when is_binary(id) do
    case Map.fetch(state.sessions, id) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, {:unknown_session, id}}
    end
  end

  defp session(_state, _params), do: {:error, "sessionId is required"}

  defp put_session(state, id, session),
    do: %{state | sessions: Map.put(state.sessions, id, session)}

  defp cursor(nil), do: {:ok, 0}

  defp cursor(text) when is_binary(text) do
    case Integer.parse(text) do
      {offset, ""} when offset >= 0 and offset <= 10_000 -> {:ok, offset}
      _invalid -> {:error, :cursor}
    end
  end

  defp cursor(_cursor), do: {:error, :cursor}

  defp descriptor(item),
    do: %{
      "sessionId" => item.id,
      "cwd" => item.cwd,
      "title" => item.preview,
      "updatedAt" => item.updated_at && DateTime.to_iso8601(item.updated_at)
    }

  defp json_shape(value), do: value |> JSON.encode!() |> JSON.decode!()
  defp safe_reason(reason) when is_binary(reason), do: reason
  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(_reason), do: "Session operation failed; inspect the local log"
  defp update(_state, _id, nil), do: :ok

  defp update(state, id, update),
    do:
      state.emit.(%{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{"sessionId" => id, "update" => update}
      })

  defp reply(state, nil, _result), do: state

  defp reply(state, id, result) do
    state.emit.(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
    state
  end

  defp operation_error(state, id, {:unknown_session, session_id}),
    do: failure(state, id, -32_002, "Unknown session", %{"sessionId" => session_id})

  defp operation_error(state, id, reason), do: failure(state, id, -32_602, safe_reason(reason))

  defp failure(state, id, code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error

    state.emit.(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => error
    })

    state
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_id, session} ->
      if Process.alive?(session.pid) do
        Session.cancel(session.pid)
        Runtime.stop_session(session.pid)
      end
    end)

    Enum.each(state.pending, fn {_id, pending} -> release(pending, {:error, :ecanceled}) end)
  end
end
