defmodule Lemieux.A2A.Server do
  @moduledoc """
  An explicitly mounted, bounded A2A task runtime. The host supplies the
  provider, store, model and supervisor; nothing is started by the library.
  A provider or store that is not a `{module, state}` pair, or a missing
  model, stops the server at mount with `{:invalid_session_options, key}`
  rather than failing every task later.

  `:server_name` selects registration (default this module, nil for anonymous
  instances). `:name` and `:description` describe the public agent. Task options
  are selected by `Lemieux.A2A.Policy`, never copied wholesale from a session.
  `:read_paths` and `:deny_paths` restrict exported data. Keep the journal and
  transcript store outside the exported checkout.

  Defaults: four concurrent tasks, 128 retained tasks, one hour retention,
  three minutes execution including questions, 64 KB input and 256 KB output.
  Session defaults cap each task at eight provider requests and twelve turns.
  `:max_total_requests` (128 by default) reserves each task's full request allowance
  against a lifetime server ceiling, persisted with `:task_directory`. The
  reservation is deliberately not refunded: unreported provider requests must
  not create spend room. Dollar budgets retain the session's unknown-price
  refusal. Usage is informational and never subscription billing.

  HTTP hosts must authenticate before calling Handler and supply an opaque,
  stable `:principal`. Tasks are visible only to their owner. Distribution is
  a trusted runtime domain: cookie peers can execute arbitrary BEAM RPC, so
  neither principal checks nor read-only tools sandbox a cookie holder.

  A journal restores terminal results and ownership. Executions lost across a
  restart become failed, never silently replayed. Durable workflow resumption,
  tenant quotas across instances and orchestration belong to an orchestrating
  host, not this task projection.
  """
  use GenServer

  defmodule State do
    @moduledoc false
    @derive {Inspect, only: [:admitted]}
    defstruct [:opts, :session_opts, tasks: %{}, admitted: 0]
  end

  alias Lemieux.A2A.{Card, Journal, JSONRPC, Message, Policy, Skill}
  alias Lemieux.A2A.Task, as: A2ATask
  alias Lemieux.Checkpoint.Git
  alias Lemieux.{Session, Usage}
  alias Lemieux.Tools.AskUser.Questionnaire

  @doc """
  Starts a server with the options the module documentation lists.
  `:server_name` registers it: this module by default, `nil` for none.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    registration =
      case Keyword.get(opts, :server_name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, registration)
  end

  @doc "The agent card this server publishes. Options as for `request/3`."
  @spec card(opts :: keyword()) :: {:ok, Card.t()} | {:error, String.t()}
  def card(opts \\ []), do: public(request(:card, %{}, opts))

  @doc """
  Sends a user message, a string or a partial message `Lemieux.A2A.Message.new/1`
  completes, and returns the task it started or continued. Options as for
  `request/3`.
  """
  @spec ask(message :: String.t() | map(), opts :: keyword()) ::
          {:ok, A2ATask.t()} | {:error, String.t()}
  def ask(message, opts \\ []) do
    public(request(:send_message, %{"message" => Message.new(message)}, opts))
  end

  @doc "Task `id`, when the caller's principal owns it. Options as for `request/3`."
  @spec get_task(id :: String.t(), opts :: keyword()) :: {:ok, A2ATask.t()} | {:error, String.t()}
  def get_task(id, opts \\ []), do: public(request(:get_task, %{"id" => id}, opts))

  @doc """
  Cancels task `id` when the caller's principal owns it and it is still running.
  Options as for `request/3`.
  """
  @spec cancel_task(id :: String.t(), opts :: keyword()) ::
          {:ok, A2ATask.t()} | {:error, String.t()}
  def cancel_task(id, opts \\ []), do: public(request(:cancel_task, %{"id" => id}, opts))

  @doc """
  The caller's tasks, filtered and paged by `params` as `ListTasks` takes them.
  Options as for `request/3`.
  """
  @spec list_tasks(params :: map(), opts :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def list_tasks(params \\ %{}, opts \\ []), do: public(request(:list_tasks, params, opts))

  @doc """
  Sends `watcher` the updates of task `id` as `{:a2a, id, event}` messages, and
  returns the task as it stands. Options as for `request/3`.
  """
  @spec subscribe(id :: String.t(), watcher :: pid(), opts :: keyword()) ::
          {:ok, A2ATask.t()} | {:error, String.t()}
  def subscribe(id, watcher, opts \\ []),
    do: public(request(:subscribe_to_task, %{"id" => id}, Keyword.put(opts, :stream, watcher)))

  @doc """
  Typed host entry point.

  Options: `:server`, the pid or name to call (this module by default);
  `:principal`, the caller's stable identity, which owns the tasks it starts
  (`"distribution"` when not given); and `:timeout`, 190 seconds by default. A
  caller timeout detaches; the task deadline still governs execution.
  """
  @spec request(operation :: atom(), params :: map(), opts :: keyword()) :: tuple()
  def request(operation, params, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {operation, params, opts},
      Keyword.get(opts, :timeout, 190_000)
    )
  catch
    :exit, {:timeout, _} ->
      {:error, "InternalError", "caller timed out; retrieve the task before retrying"}

    :exit, _ ->
      {:error, "InternalError", "this runtime is not answering to other agents"}
  end

  defp public({:error, name, reason}), do: {:error, name <> ": " <> reason}
  defp public(result), do: result

  @impl GenServer
  def init(opts) do
    with :ok <- validate_options(opts),
         session_opts = Policy.session_options(opts),
         :ok <- validate_session_options(session_opts),
         {:ok, data} <- Journal.load(opts[:task_directory]),
         {:ok, tasks, admitted} <- recover(data) do
      state = %State{
        opts: opts,
        tasks: tasks,
        admitted: admitted,
        session_opts: session_opts
      }

      Process.send_after(self(), :prune, 1_000)
      {:ok, persist(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call({:card, _params, _opts}, _from, state),
    do: {:reply, {:ok, describe(state)}, state}

  def handle_call({operation, params, opts}, from, state) do
    state = prune(state)

    case validate_call(operation, params, opts) do
      :ok -> perform(operation, params, opts, from, state)
      {:error, reason} -> {:reply, {:error, "InvalidParams", reason}, state}
    end
  end

  defp validate_call(operation, params, opts) do
    if is_binary(principal(opts)) and principal(opts) != "" and byte_size(principal(opts)) <= 512 and
         (is_nil(opts[:stream]) or is_pid(opts[:stream])),
       do: JSONRPC.validate_params(operation, params),
       else: {:error, "invalid caller identity or watcher"}
  end

  defp perform(:send_message, %{"message" => message} = params, opts, from, state) do
    config = Map.get(params, "configuration", %{})

    cond do
      message["role"] != "ROLE_USER" ->
        failure(state, "InvalidParams", "send a user message")

      byte_size(JSON.encode!(message)) > limit(state, :max_input_bytes, 64_000) ->
        failure(state, "InvalidParams", "message exceeds input limit")

      Map.has_key?(config, "taskPushNotificationConfig") ->
        failure(state, "PushNotificationNotSupported", "use task streaming")

      config["acceptedOutputModes"] && "text/plain" not in config["acceptedOutputModes"] ->
        failure(state, "ContentTypeNotSupported", "text/plain output required")

      message["taskId"] ->
        continue(state, message, config, opts, from)

      not Message.text_only?(message) ->
        failure(
          state,
          "ContentTypeNotSupported",
          "new tasks accept text parts; files and URLs are not fetched"
        )

      true ->
        start(state, message, config, opts, from)
    end
  end

  defp perform(:get_task, params, opts, _from, state) do
    case owned(state, params["id"], opts) do
      {:ok, tracked} -> {:reply, {:ok, history(tracked.task, params)}, state}
      :error -> missing(state)
    end
  end

  defp perform(:cancel_task, params, opts, _from, state) do
    case owned(state, params["id"], opts) do
      {:ok, %{task: task}} when task.state in [:completed, :failed, :canceled, :rejected] ->
        failure(state, "TaskNotCancelable", "the task has ended")

      {:ok, tracked} ->
        state = finish(state, tracked.task.id, :canceled, "Canceled by caller")
        {:reply, {:ok, state.tasks[tracked.task.id].task}, state}

      :error ->
        missing(state)
    end
  end

  defp perform(:subscribe_to_task, params, opts, _from, state) do
    case {owned(state, params["id"], opts), opts[:stream]} do
      {{:ok, %{task: %{state: ending}}}, _watcher}
      when ending in [:completed, :failed, :canceled, :rejected] ->
        failure(state, "UnsupportedOperation", "terminal tasks cannot be subscribed to")

      {{:ok, tracked}, watcher} when is_pid(watcher) and map_size(tracked.watchers) >= 16 ->
        failure(state, "UnsupportedOperation", "task subscriber limit reached")

      {{:ok, tracked}, watcher} when is_pid(watcher) ->
        tracked = watch_add(tracked, watcher)
        send(watcher, {:a2a, tracked.task.id, {:status, tracked.task}})
        {:reply, {:ok, tracked.task}, put_in(state.tasks[tracked.task.id], tracked)}

      {:error, _} ->
        missing(state)

      _ ->
        failure(state, "InvalidParams", "a watcher pid is required")
    end
  end

  defp perform(:unsubscribe, params, opts, _from, state) do
    case owned(state, params["id"], opts) do
      {:ok, tracked} ->
        {removed, kept} =
          Enum.split_with(tracked.watchers, fn {_ref, pid} -> pid == opts[:stream] end)

        Enum.each(removed, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)

        {:reply, {:ok, tracked.task},
         put_in(state.tasks[tracked.task.id], %{tracked | watchers: Map.new(kept)})}

      :error ->
        missing(state)
    end
  end

  defp perform(:list_tasks, params, opts, _from, state) do
    token = Map.get(params, "pageToken", "")

    tasks =
      state.tasks
      |> Map.values()
      |> Enum.filter(fn tracked ->
        tracked.owner == principal(opts) and
          (is_nil(params["contextId"]) or tracked.task.context_id == params["contextId"]) and
          (is_nil(params["status"]) or
             {:ok, tracked.task.state} == A2ATask.from_wire(params["status"])) and
          updated_after?(tracked.task.timestamp, params["statusTimestampAfter"])
      end)
      |> Enum.sort_by(& &1.task.id)

    page =
      tasks |> Enum.filter(&(&1.task.id > token)) |> Enum.take(Map.get(params, "pageSize", 50))

    next =
      if page != [] and List.last(page).task.id != last_id(tasks),
        do: List.last(page).task.id,
        else: ""

    {:reply,
     {:ok,
      %{
        "tasks" =>
          Enum.map(page, fn tracked ->
            task = history(tracked.task, params)
            task = if params["includeArtifacts"] == true, do: task, else: %{task | artifacts: []}
            A2ATask.to_json(task)
          end),
        "nextPageToken" => next,
        "pageSize" => Map.get(params, "pageSize", 50),
        "totalSize" => length(tasks)
      }}, state}
  end

  defp perform(_operation, _params, _opts, _from, state),
    do: failure(state, "UnsupportedOperation", "operation not supported")

  defp start(state, message, config, opts, from) do
    reservation = Keyword.fetch!(state.session_opts, :max_requests)

    cond do
      Enum.count(state.tasks, fn {_id, t} -> t.session != nil end) >=
          limit(state, :max_concurrency, 4) ->
        failure(state, "UnsupportedOperation", "agent is at capacity")

      map_size(state.tasks) >= limit(state, :max_tasks, 128) ->
        failure(state, "UnsupportedOperation", "task retention is at capacity")

      state.admitted + reservation > limit(state, :max_total_requests, 128) ->
        failure(state, "UnsupportedOperation", "server request allowance exhausted")

      true ->
        start_session(state, message, config, opts, from, reservation)
    end
  end

  defp start_session(state, message, config, opts, from, reservation) do
    case Lemieux.start_session(state.session_opts) do
      {:ok, session} ->
        id = Session.id(session)

        task = %A2ATask{
          id: id,
          context_id: message["contextId"] || Lemieux.ID.generate(),
          state: :working,
          history: [message],
          timestamp: now(),
          metadata: %{
            "lemieux" => %{
              "usage" => Map.new(Usage.empty(), fn {key, _value} -> {key, nil} end),
              "usage_reports" => 0,
              "requests_started" => 0,
              "usage_complete" => false,
              "requests_reserved" => reservation,
              "source" => source(state.session_opts[:cwd])
            }
          }
        }

        monitor = Process.monitor(session)
        guard = guard_session(self(), session)

        timer =
          Process.send_after(self(), {:deadline, id}, limit(state, :task_timeout_ms, 180_000))

        tracked = %{
          task: task,
          session: session,
          from: wait_for(config, from),
          owner: principal(opts),
          awaiting: nil,
          question: nil,
          monitor: monitor,
          guard: guard,
          timer: timer,
          watchers: %{},
          expires: expiry(state)
        }

        tracked = watch_add(tracked, opts[:stream])

        state =
          %{
            state
            | admitted: state.admitted + reservation,
              tasks: Map.put(state.tasks, id, tracked)
          }
          |> persist()

        prompted(state, tracked, config, session_call(session, :prompt, [Message.text(message)]))

      {:error, _reason} ->
        failure(state, "InternalError", "could not create a task session")
    end
  end

  defp prompted(state, tracked, config, :ok) do
    broadcast(tracked, {:status, tracked.task})
    waiting_reply(state, tracked, config)
  end

  defp prompted(state, tracked, config, {:error, _reason}) do
    state = finish(state, tracked.task.id, :failed, "Could not start the task")
    waiting_reply(state, tracked, config)
  end

  defp waiting_reply(state, %{from: nil, task: task}, config),
    do: {:reply, {:ok, history(state.tasks[task.id].task, config)}, state}

  defp waiting_reply(state, _tracked, _config), do: {:noreply, state}

  defp continue(state, message, config, opts, from) do
    case owned(state, message["taskId"], opts) do
      :error ->
        missing(state)

      {:ok, %{awaiting: nil}} ->
        failure(state, "UnsupportedOperation", "task does not accept a continuation")

      {:ok, tracked} ->
        resume(state, tracked, message, config, opts, from)
    end
  end

  defp resume(state, tracked, message, config, opts, from) do
    with true <- is_nil(message["contextId"]) or message["contextId"] == tracked.task.context_id,
         {:ok, answer} <- answer(message, tracked.question),
         :ok <- session_call(tracked.session, :answer, [tracked.awaiting, answer]),
         {:ok, task} <- A2ATask.transition(tracked.task, :working) do
      task = %{task | history: Enum.take(tracked.task.history ++ [message], -64)}

      tracked =
        %{tracked | task: task, awaiting: nil, question: nil, from: wait_for(config, from)}
        |> watch_add(opts[:stream])

      state = put_in(state.tasks[task.id], tracked) |> persist()
      broadcast(tracked, {:status, task})
      waiting_reply(state, tracked, config)
    else
      _ -> failure(state, "InvalidParams", "invalid or late answer; task was not resumed")
    end
  end

  defp answer(message, %{questionnaire: true, questions: questions}) do
    data = Enum.find_value(message["parts"], &Map.get(&1, "data"))

    questions =
      Enum.map(questions, fn question ->
        Lemieux.Contract.json(question) |> Map.put("id", question.question_id)
      end)

    answers = Questionnaire.normalize_batch({:ok, data}, questions)

    if Enum.all?(answers, &(&1["status"] != "invalid")),
      do: {:ok, data},
      else: {:error, :invalid_answer}
  end

  defp answer(message, _question) do
    if Message.text_only?(message) and Message.text(message) != "",
      do: {:ok, Message.text(message)},
      else: {:error, :invalid_answer}
  end

  @impl GenServer
  def handle_info({:lemieux, id, {:text_delta, %{text: chunk}}}, state) do
    case state.tasks[id] do
      %{session: session} = tracked when is_pid(session) ->
        text = A2ATask.text(tracked.task) <> chunk

        if byte_size(text) > limit(state, :max_output_bytes, 256_000) do
          {:noreply, finish(state, id, :failed, "Task output limit exceeded")}
        else
          tracked = %{tracked | task: %{tracked.task | artifacts: [%{"text" => text}]}}
          broadcast(tracked, {:delta, chunk})
          {:noreply, put_in(state.tasks[id], tracked)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lemieux, id, {:question, question}}, state) do
    case state.tasks[id] do
      %{session: session} = tracked when is_pid(session) ->
        {:ok, task} = A2ATask.transition(tracked.task, :input_required, question.question)

        task = %{
          task
          | status_message:
              Message.agent(question.question)
              |> Map.update!("parts", &(&1 ++ [%{"data" => Lemieux.Contract.json(question)}]))
        }

        broadcast(tracked, {:status, task})
        respond(tracked, task)

        tracked = %{
          tracked
          | task: task,
            from: nil,
            awaiting: question.call_id,
            question: question
        }

        {:noreply, put_in(state.tasks[id], tracked) |> persist()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lemieux, id, {:entry, %{type: :request}}}, state) do
    case state.tasks[id] do
      %{session: session} = tracked when is_pid(session) ->
        task = tracked.task
        task = update_in(task.metadata["lemieux"]["requests_started"], &(&1 + 1))
        task = put_in(task.metadata["lemieux"]["usage_complete"], false)
        {:noreply, put_in(state.tasks[id], %{tracked | task: task}) |> persist()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lemieux, id, {:usage, usage}}, state) do
    case state.tasks[id] do
      %{session: session} = tracked when is_pid(session) ->
        reports = tracked.task.metadata["lemieux"]["usage_reports"]

        previous =
          if reports == 0, do: Usage.empty(), else: tracked.task.metadata["lemieux"]["usage"]

        total = Usage.add(previous, usage)
        task = tracked.task
        task = put_in(task.metadata["lemieux"]["usage"], total)
        task = put_in(task.metadata["lemieux"]["usage_reports"], reports + 1)

        task =
          put_in(
            task.metadata["lemieux"]["usage_complete"],
            reports + 1 == task.metadata["lemieux"]["requests_started"]
          )

        {:noreply, put_in(state.tasks[id], %{tracked | task: task}) |> persist()}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lemieux, id, {:finished, reason}}, state),
    do:
      {:noreply,
       finish(
         state,
         id,
         A2ATask.from_finish(reason),
         if(reason == :stop, do: nil, else: "Task stopped: #{inspect(reason)}")
       )}

  def handle_info({:deadline, id}, state),
    do: {:noreply, finish(state, id, :failed, "Task execution deadline exceeded")}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      case Enum.find(state.tasks, fn {_id, tracked} -> tracked.monitor == ref end) do
        {id, _tracked} ->
          finish(state, id, :failed, "Task session exited unexpectedly")

        nil ->
          %{
            state
            | tasks:
                Map.new(state.tasks, fn {id, tracked} ->
                  {id, %{tracked | watchers: Map.delete(tracked.watchers, ref)}}
                end)
          }
      end

    {:noreply, state}
  end

  def handle_info(:prune, state) do
    Process.send_after(self(), :prune, 1_000)
    {:noreply, prune(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state),
    do: Enum.each(state.tasks, fn {_id, tracked} -> cleanup(tracked) end)

  defp finish(state, id, ending, message) do
    case state.tasks[id] do
      %{session: session} = tracked when is_pid(session) ->
        {:ok, task} = A2ATask.transition(tracked.task, ending, message)
        task = complete_usage(task)
        cleanup(tracked)

        finished = %{
          tracked
          | task: task,
            session: nil,
            from: nil,
            awaiting: nil,
            question: nil,
            monitor: nil,
            guard: nil,
            timer: nil,
            watchers: %{},
            expires: expiry(state)
        }

        state = put_in(state.tasks[id], finished) |> persist()
        broadcast(tracked, {:status, task})
        respond(tracked, task)
        emit(task)
        state

      _ ->
        state
    end
  end

  defp cleanup(%{session: session} = tracked) when is_pid(session) do
    if tracked.timer, do: Process.cancel_timer(tracked.timer)
    if tracked.monitor, do: Process.demonitor(tracked.monitor, [:flush])
    Enum.each(tracked.watchers, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    stop_session(session)
    if tracked.guard, do: send(tracked.guard, :release)
  end

  defp cleanup(_tracked), do: :ok

  defp stop_session(session) do
    if Process.alive?(session) do
      Session.cancel(session)
      GenServer.stop(session, :normal)
    end
  catch
    :exit, _ -> :ok
  end

  defp guard_session(server, session) do
    spawn(fn ->
      ref = Process.monitor(server)

      receive do
        :release -> Process.demonitor(ref, [:flush])
        {:DOWN, ^ref, :process, ^server, _reason} -> stop_session(session)
      end
    end)
  end

  defp wait_for(%{"returnImmediately" => true}, _from), do: nil
  defp wait_for(config, from), do: {from, config}
  defp respond(%{from: nil}, _task), do: :ok

  defp respond(tracked, task),
    do: GenServer.reply(elem(tracked.from, 0), {:ok, history(task, elem(tracked.from, 1))})

  defp watch_add(tracked, watcher) when is_pid(watcher) do
    if A2ATask.terminal?(tracked.task) or
         Enum.any?(tracked.watchers, fn {_ref, pid} -> pid == watcher end),
       do: tracked,
       else: %{tracked | watchers: Map.put(tracked.watchers, Process.monitor(watcher), watcher)}
  end

  defp watch_add(tracked, _watcher), do: tracked

  defp broadcast(tracked, event),
    do:
      Enum.each(tracked.watchers, fn {_ref, pid} -> send(pid, {:a2a, tracked.task.id, event}) end)

  defp owned(state, id, opts) do
    case state.tasks[id] do
      %{owner: owner} = tracked -> if owner == principal(opts), do: {:ok, tracked}, else: :error
      nil -> :error
    end
  end

  defp principal(opts), do: Keyword.get(opts, :principal, "distribution")
  defp history(task, %{"historyLength" => 0}), do: %{task | history: []}

  defp history(task, %{"historyLength" => length}),
    do: %{task | history: Enum.take(task.history, -length)}

  defp history(task, _params), do: task

  defp session_call(session, function, arguments) do
    apply(Session, function, [session | arguments])
  catch
    :exit, _ -> {:error, :session_unavailable}
  end

  defp updated_after?(_timestamp, nil), do: true
  defp updated_after?(nil, _after), do: false

  defp updated_after?(timestamp, after_time) do
    {:ok, actual, _} = DateTime.from_iso8601(timestamp)
    {:ok, requested, _} = DateTime.from_iso8601(after_time)
    DateTime.compare(actual, requested) in [:eq, :gt]
  end

  defp last_id([]), do: ""
  defp last_id(tasks), do: List.last(tasks).task.id
  defp missing(state), do: failure(state, "TaskNotFound", "no task here for this caller")
  defp failure(state, name, reason), do: {:reply, {:error, name, reason}, state}
  defp limit(state, key, default), do: Keyword.get(state.opts, key, default)
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp expiry(state),
    do: System.system_time(:millisecond) + limit(state, :retention_ms, 3_600_000)

  defp prune(state) do
    tasks =
      Map.reject(state.tasks, fn {_id, tracked} ->
        tracked.session == nil and tracked.expires <= System.system_time(:millisecond)
      end)

    if tasks == state.tasks, do: state, else: persist(%{state | tasks: tasks})
  end

  defp persist(state) do
    data = %{
      "admitted" => state.admitted,
      "tasks" =>
        Enum.map(state.tasks, fn {_id, tracked} ->
          %{
            "task" => A2ATask.to_json(tracked.task),
            "owner" => tracked.owner,
            "expires" => tracked.expires
          }
        end)
    }

    case Journal.save(state.opts[:task_directory], data) do
      :ok -> state
      {:error, reason} -> raise "A2A journal unavailable: #{inspect(reason)}"
    end
  end

  defp recover(%{"tasks" => records, "admitted" => admitted})
       when is_list(records) and is_integer(admitted) and admitted >= 0 do
    Enum.reduce_while(records, {:ok, %{}, admitted}, &recover_record/2)
  end

  defp recover(_data), do: {:error, :invalid_task_journal}

  defp recover_record(record, {:ok, tasks, admitted}) do
    with %{"task" => json, "owner" => owner, "expires" => expires}
         when is_binary(owner) and is_integer(expires) <- record,
         {:ok, task} <- A2ATask.from_json(json) do
      task = recover_task(task)

      tracked = %{
        task: task,
        owner: owner,
        expires: expires,
        session: nil,
        from: nil,
        awaiting: nil,
        question: nil,
        monitor: nil,
        guard: nil,
        timer: nil,
        watchers: %{}
      }

      {:cont, {:ok, Map.put(tasks, task.id, tracked), admitted}}
    else
      _ -> {:halt, {:error, :invalid_task_journal}}
    end
  end

  defp recover_task(task) do
    if A2ATask.terminal?(task),
      do: task,
      else: elem(A2ATask.transition(task, :failed, "Execution lost across server restart"), 1)
  end

  defp validate_options(opts) do
    limits =
      ~w(max_concurrency max_tasks retention_ms task_timeout_ms max_input_bytes max_output_bytes max_total_requests)a

    if Enum.all?(limits, fn key ->
         not Keyword.has_key?(opts, key) or (is_integer(opts[key]) and opts[key] > 0)
       end) and
         (not Keyword.has_key?(opts, :max_requests) or
            (is_integer(opts[:max_requests]) and opts[:max_requests] > 0)),
       do: :ok,
       else: {:error, :invalid_a2a_limits}
  end

  # Every task session starts from these same options, and
  # `Lemieux.start_session/1` raises in its caller when one is missing or
  # malformed. Here that caller is this server's `handle_call`, so a server
  # mounted without a model crashed on every remote ask, and a peer asking
  # often enough exhausted the host supervisor's restart intensity. Checked
  # once at mount instead, the way `Lemieux.Supervisor.start_link/1` checks
  # its own options, where a host expects a configuration mistake to stop the
  # child. Values are never put in the reason: providers and stores carry
  # credentials in their state.
  defp validate_session_options(session_opts) do
    case Enum.reject([:provider, :store, :model], &session_option?(&1, session_opts[&1])) do
      [] -> :ok
      [key | _rest] -> {:error, {:invalid_session_options, key}}
    end
  end

  defp session_option?(:model, model), do: not is_nil(model)

  defp session_option?(_pair, {module, _state}) when is_atom(module) and not is_nil(module),
    do: true

  defp session_option?(_pair, _value), do: false

  # Both questions go through `Lemieux.Checkpoint.Git`, which asks the
  # repository with nothing it configures run: a task's session can write
  # `.git/config` and the refs, and a plain `git status` here ran the
  # `core.fsmonitor` or filter it put there, on this machine. The revision
  # is the object name alone (`Lemieux.Checkpoint.Git.revision/1`), never
  # the warnings a ref the session wrote makes git print before it.
  defp source(cwd) do
    cwd = cwd || File.cwd!()

    case Git.revision(cwd) do
      {:ok, revision} ->
        %{"kind" => "working_tree", "revision" => revision, "dirty" => dirty(cwd)}

      :none ->
        %{"kind" => "working_tree", "revision" => nil, "dirty" => nil}
    end
  end

  # The first line of `Lemieux.Checkpoint.Git.status/2` is the branch; any
  # other is a change.
  defp dirty(cwd) do
    case Git.status(cwd) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.any?(&(not String.starts_with?(&1, "## ")))

      {:error, _unknown} ->
        nil
    end
  end

  defp complete_usage(task) do
    if task.metadata["lemieux"]["usage_complete"] do
      task
    else
      put_in(task.metadata["lemieux"]["usage"]["cost_usd"], nil)
    end
  end

  defp emit(task),
    do:
      :telemetry.execute([:lemieux, :a2a, :task, :stop], %{count: 1}, %{
        task_id: task.id,
        state: task.state
      })

  defp describe(state) do
    Card.for_session(
      %{
        id: to_string(node()),
        model: state.opts[:model],
        cwd: Keyword.get_lazy(state.opts, :cwd, &File.cwd!/0)
      },
      name: state.opts[:name],
      description: state.opts[:description],
      skills:
        Keyword.get_lazy(state.opts, :skills, fn ->
          Skill.from_tools(%{
            cwd: Keyword.get_lazy(state.opts, :cwd, &File.cwd!/0),
            tools: state.session_opts[:tools]
          })
        end),
      interfaces: Keyword.get(state.opts, :interfaces, [{:distribution, node()}]),
      security_schemes: Keyword.get(state.opts, :security_schemes, %{}),
      security_requirements: Keyword.get(state.opts, :security_requirements, [])
    )
  end
end
