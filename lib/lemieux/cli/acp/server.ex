defmodule Lemieux.CLI.ACP.Server do
  @moduledoc false
  use GenServer

  alias Lemieux.CLI.ACP.Wire
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

  @impl true
  def init(opts) do
    {:ok,
     %{
       options: Keyword.fetch!(opts, :options),
       host: Keyword.fetch!(opts, :host),
       emit: Keyword.fetch!(opts, :emit),
       version: nil,
       questions?: false,
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

  defp dispatch(%{"jsonrpc" => "2.0", "method" => method} = message, state)
       when is_binary(method) do
    params = Map.get(message, "params", %{})

    cond do
      not Map.has_key?(message, "id") ->
        notification(method, params, state)

      not (is_nil(message["id"]) or is_binary(message["id"]) or is_integer(message["id"])) ->
        failure(state, nil, -32_600, "Invalid request id")

      is_map(params) ->
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
       when is_integer(requested) and requested >= 1 do
    version = if requested == 1, do: 1, else: 2
    capabilities = params["capabilities"] || params["clientCapabilities"] || %{}
    questions? = match?(%{"_meta" => %{"lemieux" => %{"question" => true}}}, capabilities)
    state = %{state | version: version, questions?: questions?}
    reply(state, id, Wire.initialize(version))
  end

  defp request("initialize", _params, id, %{version: nil} = state),
    do: failure(state, id, -32_602, "protocolVersion must be a positive integer")

  defp request(_method, _params, id, %{version: nil} = state),
    do: failure(state, id, -32_000, "Initialize first")

  defp request(method, params, id, state)
       when method in ["session/new", "session/load", "session/resume"] do
    with :ok <- workspace(params),
         :ok <- replay_cursor(params),
         true <- map_size(state.sessions) < 16,
         {:ok, servers} <- servers(params),
         {:ok, state, session_id} <- open_session(method, params, servers, state) do
      replay? = method == "session/load" or params["replayFrom"] == %{"type" => "start"}
      if replay?, do: replay(state, session_id)
      reply(state, id, %{"sessionId" => session_id})
    else
      false -> failure(state, id, -32_000, "Connection session limit reached")
      {:error, reason} -> failure(state, id, -32_602, safe_reason(reason))
    end
  end

  defp request("session/list", params, id, state) do
    store = Runtime.store(state.options, state.host)

    with {:ok, offset} <- cursor(params["cursor"]),
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
         {:ok, text} <- prompt_text(params["prompt"]),
         :ok <- Session.prompt(session.pid, text) do
      update(state, params["sessionId"], running(state.version))
      put_session(state, params["sessionId"], %{session | prompt: id})
    else
      {:error, reason} -> failure(state, id, -32_602, safe_reason(reason))
    end
  end

  defp request("session/cancel", params, id, state) do
    with {:ok, session} <- session(state, params), :ok <- Session.cancel(session.pid) do
      reply(state, id, %{})
    else
      {:error, reason} -> failure(state, id, -32_602, safe_reason(reason))
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

      {:error, reason} ->
        failure(state, id, -32_602, safe_reason(reason))
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

  defp request(_method, _params, id, state),
    do: failure(state, id, -32_601, "Method not supported")

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

  defp replay_cursor(%{"replayFrom" => cursor}) when cursor not in [nil, %{"type" => "start"}],
    do: {:error, "Unsupported replay cursor"}

  defp replay_cursor(_params), do: :ok

  defp servers(params) do
    values = Map.get(params, "mcpServers", [])

    if is_list(values) and Enum.all?(values, &stdio_server?/1),
      do: {:ok, Enum.flat_map(values, &server_config/1)},
      else: {:error, "Only valid stdio MCP servers are supported"}
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

  defp open_session(method, params, servers, state) do
    resume = if method == "session/new", do: nil, else: params["sessionId"]
    options = %{state.options | resume: resume}
    host = Keyword.merge(state.host, cwd: params["cwd"], interactive?: true)

    with :ok <- resume_workspace(method, resume, params["cwd"], state),
         {:ok, prepared} <- Runtime.prepare(options, host),
         harness = Harness.append_mcp_servers(prepared.harness, servers),
         {:ok, pid} <- Runtime.start(%{prepared | harness: harness}, subscriber: self()) do
      info = Session.info(pid)
      Process.monitor(pid)
      session = %{pid: pid, prompt: nil, streamed: MapSet.new()}
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
      _invalid -> {:error, "Session is absent, open, or belongs to another workspace"}
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

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
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

    unless duplicate?, do: update(state, id, Wire.entry(state.version, entry))
    state
  end

  defp event(state, id, {:tool_call, call}) do
    update(state, id, Wire.tool(state.version, call))
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
  defp event(state, _id, _event), do: state

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

    pending = Map.reject(state.pending, fn {_key, pending} -> pending.session_id == id end)
    put_session(%{state | pending: pending}, id, %{session | prompt: nil, streamed: MapSet.new()})
  end

  defp terminal_reply(_state, nil, _reason), do: :ok

  defp terminal_reply(state, request_id, :error),
    do:
      failure(
        state,
        request_id,
        -32_000,
        "Agent request failed; inspect the local transcript or log"
      )

  defp terminal_reply(%{version: 2} = state, request_id, _reason),
    do: failure(state, request_id, -32_000, "Prompt ended before its user message was committed")

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

      {pending, remaining} ->
        pid = state.sessions[pending.session_id].pid
        resolve(pid, pending, message["result"])
        update(state, pending.session_id, running(state.version))
        %{state | pending: remaining}
    end
  end

  defp resolve(pid, %{kind: :approval, call_id: call}, result) do
    decision =
      if match?(%{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}, result),
        do: :allow,
        else: {:deny, "Client rejected permission"}

    Session.resolve_tool(pid, call, decision)
  end

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

  defp session(state, %{"sessionId" => id}) do
    case Map.fetch(state.sessions, id) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, "Unknown session"}
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

  defp failure(state, id, code, message) do
    state.emit.(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
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
  end
end
