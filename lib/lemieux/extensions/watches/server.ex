defmodule Lemieux.Extensions.Watches.Server do
  @moduledoc """
  Host-owned watch scheduler and durable delivery queue.

  Required options: `:journal`, `:session_id`, `:sources`, `:task_supervisor`.
  Optional: `:session`, `:name`, `:clock`, `:now` (UTC milliseconds),
  `:authorize` (current host continuation policy, a one-argument predicate),
  `:max_concurrency` (4), `:max_records` (256 per session), `:poll_ms` (1000),
  `:max_poll_ms` (60000), `:observation_timeout_ms` (15000),
  `:retention_ms` (one day) and `:tick_ms` (1000).

  Persisted deadlines use wall time so a new VM cannot reset them. Timers use
  the supplied `Lemieux.Clock`. One session's journal has one fenced owner;
  the host chooses a separate journal directory or partition per session.
  Output expires after retention once delivered, or explicitly via `forget/2`.
  Small receipts remain and registration stops at `max_records`, rather than
  growing an unbounded in-memory history or silently losing undelivered data.
  """
  use GenServer, restart: :transient

  alias Lemieux.Clock
  alias Lemieux.Extensions.Watches.Record
  alias Lemieux.Jobs.Journal
  alias Lemieux.Session

  @doc "Starts observation without starting an agent or external job."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    journal = Keyword.fetch!(opts, :journal)
    session_id = Keyword.fetch!(opts, :session_id)
    max_records = positive(opts, :max_records, 256)

    with :ok <- session_identity(opts[:session], session_id),
         {:ok, lock} <- journal_lock(journal),
         {:ok, records} <- load(journal, max_records),
         true <- Enum.all?(records, fn {_id, record} -> Record.valid?(record, session_id) end) do
      state = %{
        journal: journal,
        lock: lock,
        session_id: session_id,
        sources: Keyword.fetch!(opts, :sources),
        records: records,
        task_supervisor: Keyword.fetch!(opts, :task_supervisor),
        tasks: %{},
        session: nil,
        session_ref: nil,
        clock: Keyword.get(opts, :clock),
        now: Keyword.get(opts, :now, fn -> System.system_time(:millisecond) end),
        authorize: Keyword.get(opts, :authorize, fn _watch -> true end),
        default_follow_up: Keyword.get(opts, :default_follow_up, false) == true,
        delivery_timer: nil,
        max_records: max_records,
        max_concurrency: positive(opts, :max_concurrency, 4),
        poll_ms: positive(opts, :poll_ms, 1000),
        max_poll_ms: positive(opts, :max_poll_ms, 60_000),
        observation_timeout_ms: positive(opts, :observation_timeout_ms, 15_000),
        retention_ms: positive(opts, :retention_ms, :timer.hours(24)),
        tick_ms: positive(opts, :tick_ms, 1000)
      }

      state = connect(state, opts[:session])
      Enum.each(state.records, fn {_id, record} -> subscribe_background(state, record.value) end)
      send(self(), :tick)
      {:ok, state}
    else
      false -> {:stop, :invalid_watch_records}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:list, _from, state),
    do:
      {:reply, state.records |> Map.values() |> Enum.map(& &1.value) |> Enum.sort_by(& &1["id"]),
       state}

  def handle_call({:get, id}, _from, state), do: {:reply, fetch(state, id), state}

  def handle_call(:sources, _from, state), do: {:reply, Enum.sort(Map.keys(state.sources)), state}

  def handle_call(:defaults, _from, state),
    do: {:reply, %{follow_up: state.default_follow_up}, state}

  def handle_call({:register, source, target, opts}, _from, state) do
    case existing_background(state, source, target, Keyword.get(opts, :reuse, true)) do
      nil ->
        register_new(state, source, target, opts)

      watch ->
        state =
          reuse(
            state,
            watch,
            Keyword.get(opts, :follow_up, state.default_follow_up) == true,
            Keyword.get(opts, :continuation_origin, "host")
          )

        {:reply, fetch(state, watch["id"]), state}
    end
  end

  def handle_call({:follow_up, id, enabled?}, _from, state) do
    case fetch(state, id) do
      {:ok, %{"delivery" => "pending"} = watch} ->
        state =
          save(
            state,
            id,
            Map.merge(watch, %{"follow_up" => enabled?, "continuation_origin" => "user"})
          )
          |> deliver()

        {:reply, fetch(state, id), state}

      {:ok, _watch} ->
        {:reply, {:error, :already_delivered}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:stop, id}, _from, state) do
    case fetch(state, id) do
      {:ok, %{"status" => "watching"}} ->
        state =
          state
          |> stop_task(id)
          |> terminal(id, "stopped", %{
            "summary" => "Monitoring stopped; external work was not cancelled."
          })
          |> deliver()

        {:reply, fetch(state, id), state}

      {:ok, %{"delivery" => "pending"} = watch} ->
        state = save(state, id, Map.put(watch, "follow_up", false)) |> deliver()
        {:reply, fetch(state, id), state}

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:forget, id}, _from, state) do
    case fetch(state, id) do
      {:ok, %{"delivery" => "delivered"} = watch} ->
        state = save(state, id, Record.forget(watch))
        {:reply, fetch(state, id), state}

      {:ok, _watch} ->
        {:reply, {:error, :not_delivered}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:attach, session, opts}, _from, state) do
    case session_identity(session, state.session_id) do
      :ok ->
        state = replace_sources(state, opts)

        state = %{
          state
          | authorize: Keyword.get(opts, :authorize, state.authorize),
            default_follow_up: Keyword.get(opts, :default_follow_up, state.default_follow_up)
        }

        {:reply, :ok, state |> connect(session) |> schedule() |> deliver()}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:deliver_results, state),
    do: {:noreply, flush_deliveries(%{state | delivery_timer: nil})}

  def handle_info(:tick, state) do
    Clock.send_after(state.clock, self(), :tick, state.tick_ms)
    {:noreply, state |> expire() |> schedule() |> deliver() |> cleanup()}
  end

  def handle_info(
        {:lemieux_background, %{task: %{id: task_id, session_id: session_id}}},
        %{session_id: session_id} = state
      ) do
    # Completion is a wake-up, not trusted result data. Re-read the original
    # source immediately, including when a stale pending probe is in flight.
    state =
      Enum.reduce(state.records, state, fn {id, %{value: watch}}, state ->
        wake_background(state, id, watch, task_id)
      end)

    {:noreply, state |> schedule() |> deliver()}
  end

  def handle_info({ref, result}, %{tasks: tasks} = state) when is_map_key(tasks, ref) do
    {task, tasks} = Map.pop(tasks, ref)
    Process.demonitor(ref, [:flush])
    state = observe(%{state | tasks: tasks}, task.id, result)
    {:noreply, state |> schedule() |> deliver()}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{session_ref: ref, journal: nil} = state
      ),
      do: {:stop, :normal, %{state | session: nil, session_ref: nil}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{session_ref: ref} = state),
    do: {:noreply, %{state | session: nil, session_ref: nil}}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{tasks: tasks} = state)
      when is_map_key(tasks, ref) do
    {task, tasks} = Map.pop(tasks, ref)

    state =
      terminal(%{state | tasks: tasks}, task.id, "unavailable", %{
        "summary" => "Status observer crashed."
      })

    {:noreply, state |> schedule() |> deliver()}
  end

  def handle_info({:lemieux, id, {:finished, :cancelled}}, %{session_id: id} = state) do
    state =
      Enum.reduce(state.records, state, fn {id, record}, state ->
        if record.value["delivery"] == "pending" and record.value["follow_up"],
          do: save(state, id, Map.put(record.value, "follow_up", false)),
          else: state
      end)

    {:noreply, deliver(state)}
  end

  def handle_info({:lemieux, id, {:finished, _reason}}, %{session_id: id} = state),
    do: {:noreply, deliver(state)}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.tasks, fn {_ref, task} -> Task.shutdown(task.task, :brutal_kill) end)
    if state.journal, do: Journal.unlock(state.journal, "watch-owner", state.lock)
  end

  defp existing_background(state, "background", target, true) do
    target = canonical_background(state, target)

    Enum.find_value(state.records, fn {_id, %{value: watch}} ->
      if watch["source"] == "background" and watch["target"] == target and
           watch["status"] in ["watching", "completed"],
         do: watch
    end)
  end

  defp existing_background(_state, _source, _target, _reuse?), do: nil

  defp canonical_background(state, target) do
    with {:ok, adapter} <- Map.fetch(state.sources, "background"),
         {:ok, target} <- validate(adapter, target),
         do: target,
         else: (_error -> target)
  end

  defp reuse(state, %{"continuation_origin" => "user"}, _follow_up?, _origin), do: state

  defp reuse(state, %{"delivery" => "pending"} = watch, follow_up?, origin) do
    save(
      state,
      watch["id"],
      Map.merge(watch, %{"follow_up" => follow_up?, "continuation_origin" => origin})
    )
  end

  defp reuse(state, _watch, _follow_up?, _origin), do: state

  defp register_new(state, source, target, opts) do
    with true <- map_size(state.records) < state.max_records,
         {:ok, adapter} <- Map.fetch(state.sources, source),
         {:ok, target} <- validate(adapter, target),
         :ok <- Record.validate_target(target),
         {:ok, timeout} <- Record.timeout(opts) do
      now = state.now.()
      id = "watch-" <> Lemieux.ID.generate()

      watch = %{
        "version" => 1,
        "id" => id,
        "session_id" => state.session_id,
        "source" => source,
        "target" => target,
        "status" => "watching",
        "created_at" => now,
        "created_order" => next_order(state, now),
        "deadline" => now + timeout,
        "deadline_at" =>
          DateTime.from_unix!(now + timeout, :millisecond) |> DateTime.to_iso8601(),
        "next_poll_at" => now,
        "attempts" => 0,
        "follow_up" => Keyword.get(opts, :follow_up, state.default_follow_up) == true,
        "continuation_origin" => Keyword.get(opts, :continuation_origin, "host"),
        "label" => Record.text(Keyword.get(opts, :label), 240),
        "task_name" => Record.text(Keyword.get(opts, :task_name), 100),
        "delivery" => "pending",
        "result" => nil,
        "finished_at" => nil
      }

      {:ok, record} = write(state.journal, id, 0, watch)
      state = %{state | records: Map.put(state.records, id, record)}
      subscribe_background(state, watch)
      {:reply, {:ok, watch}, schedule(state)}
    else
      false -> {:reply, {:error, :record_limit}, state}
      :error -> {:reply, {:error, :unknown_source}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # ULID randomness cannot order registrations made in the same millisecond.
  # Persist a logical order so pause/resume selects the newest observation even
  # after recovery, with a frozen clock, or after the wall clock moves backward.
  defp next_order(state, now),
    do:
      Enum.reduce(state.records, now, fn {_id, %{value: watch}}, order ->
        max(order, (watch["created_order"] || watch["created_at"]) + 1)
      end)

  defp load(journal, limit, cursor \\ nil, records \\ %{})
  defp load(nil, _limit, _cursor, _records), do: {:ok, %{}}

  defp load(journal, limit, cursor, records) do
    with {:ok, page} <- Journal.scan(journal, "watch-", cursor, min(limit + 1, 1000)) do
      records = Enum.reduce(page, records, &Map.put(&2, &1.key, &1))

      cond do
        map_size(records) > limit -> {:error, :record_limit}
        page == [] -> {:ok, records}
        true -> load(journal, limit, List.last(page).key, records)
      end
    end
  end

  defp connect(state, nil), do: state

  defp connect(state, session) do
    if state.session do
      session_call(fn -> Session.unsubscribe(state.session, self()) end)
      Process.demonitor(state.session_ref, [:flush])
    end

    case session_call(fn -> Session.subscribe(session, self()) end) do
      :ok -> %{state | session: session, session_ref: Process.monitor(session)}
      {:error, :disconnected} -> %{state | session: nil, session_ref: nil}
    end
  end

  defp session_identity(nil, _id), do: :ok

  defp session_identity(session, id) do
    case session_call(fn -> Session.id(session) end) do
      ^id -> :ok
      {:error, :disconnected} = error -> error
      _wrong -> {:error, :wrong_session}
    end
  end

  defp session_call(fun) do
    fun.()
  catch
    :exit, _reason -> {:error, :disconnected}
  end

  defp replace_sources(state, opts) do
    case Keyword.fetch(opts, :sources) do
      {:ok, sources} ->
        state =
          Enum.reduce(state.tasks, state, fn {_ref, task}, state -> stop_task(state, task.id) end)

        %{state | sources: sources}

      :error ->
        state
    end
  end

  defp validate({module, context}, target), do: module.validate(context, target)

  defp fetch(state, id) do
    case Map.fetch(state.records, id) do
      {:ok, record} -> {:ok, record.value}
      :error -> {:error, :not_found}
    end
  end

  # Hermetic hosts keep observation state in this server, with no disk writes.
  defp journal_lock(nil), do: {:ok, nil}
  defp journal_lock(journal), do: Journal.lock(journal, "watch-owner")

  defp write(nil, id, revision, value),
    do: {:ok, %{key: id, revision: revision + 1, value: value}}

  defp write(journal, id, revision, value), do: Journal.write(journal, id, revision, value)

  defp save(state, id, watch) do
    record = Map.fetch!(state.records, id)
    {:ok, stored} = write(state.journal, id, record.revision, watch)
    %{state | records: Map.put(state.records, id, stored)}
  end

  defp schedule(state) do
    active = MapSet.new(state.tasks, fn {_ref, task} -> task.id end)
    slots = max(state.max_concurrency - map_size(state.tasks), 0)
    now = state.now.()

    state.records
    |> Map.values()
    |> Enum.map(& &1.value)
    |> Enum.filter(
      &(&1["status"] == "watching" and &1["next_poll_at"] <= now and
          not MapSet.member?(active, &1["id"]))
    )
    |> Enum.sort_by(&{&1["next_poll_at"], &1["id"]})
    |> Enum.take(slots)
    |> Enum.reduce(state, &start_observation/2)
  end

  defp start_observation(watch, state) do
    id = watch["id"]

    if watch["deadline"] <= state.now.() do
      terminal(state, id, "timed_out", %{"summary" => "Watch deadline expired."})
    else
      launch(state, watch, Map.fetch(state.sources, watch["source"]))
    end
  end

  defp launch(state, watch, {:ok, {module, context}}) do
    target = watch["target"]

    task =
      Task.Supervisor.async(state.task_supervisor, fn ->
        case module.validate(context, target) do
          {:ok, ^target} -> module.observe(context, target)
          _invalid -> {:error, :failed, "Stored source identity is invalid in this host."}
        end
      end)

    record = %{task: task, id: watch["id"], started_at: state.now.()}
    %{state | tasks: Map.put(state.tasks, task.ref, record)}
  end

  defp launch(state, watch, :error),
    do:
      terminal(state, watch["id"], "unavailable", %{
        "summary" => "Source is not configured in this host."
      })

  defp observe(state, id, {:done, result}) when is_map(result),
    do: terminal(state, id, "completed", result)

  defp observe(state, id, {:error, category, reason})
       when category in [:authentication, :unavailable, :failed] and is_binary(reason),
       do: terminal(state, id, Atom.to_string(category), %{"summary" => reason})

  defp observe(state, id, {:pending, summary}) when is_binary(summary),
    do: pending(state, id, summary, nil)

  defp observe(state, id, {:retry, delay, summary})
       when is_integer(delay) and delay > 0 and is_binary(summary),
       do: pending(state, id, summary, delay)

  defp observe(state, id, _invalid),
    do:
      terminal(state, id, "unavailable", %{"summary" => "Source returned an invalid observation."})

  defp pending(state, id, summary, retry_after) do
    {:ok, watch} = fetch(state, id)
    attempts = watch["attempts"] + 1

    delay =
      retry_after || min(state.poll_ms * Integer.pow(2, min(attempts - 1, 16)), state.max_poll_ms)

    save(
      state,
      id,
      Map.merge(watch, %{
        "attempts" => attempts,
        "last_status" => Record.text(summary, 1000),
        "next_poll_at" => state.now.() + delay
      })
    )
  end

  defp terminal(state, id, status, result) do
    {:ok, watch} = fetch(state, id)
    unsubscribe_background(state, watch)

    save(
      state,
      id,
      Map.merge(watch, %{
        "status" => status,
        "result" => Record.result(result),
        "finished_at" => state.now.()
      })
    )
  end

  defp wake_background(
         state,
         id,
         %{"source" => "background", "status" => "watching", "target" => %{"task_id" => task_id}} =
           watch,
         task_id
       ) do
    state |> stop_task(id) |> save(id, Map.put(watch, "next_poll_at", state.now.()))
  end

  defp wake_background(state, _id, _watch, _task_id), do: state

  defp subscribe_background(state, %{
         "source" => "background",
         "status" => "watching",
         "target" => %{"task_id" => id}
       }) do
    case state.sources["background"] do
      {Lemieux.Extensions.Watches.Background, source} ->
        Lemieux.Background.subscribe(source.supervisor, state.session_id, id, self())

      _other ->
        :ok
    end
  end

  defp subscribe_background(_state, _watch), do: :ok

  defp unsubscribe_background(state, %{"source" => "background", "target" => %{"task_id" => id}}) do
    case state.sources["background"] do
      {Lemieux.Extensions.Watches.Background, source} ->
        Lemieux.Background.unsubscribe(source.supervisor, state.session_id, id, self())

      _other ->
        :ok
    end
  end

  defp unsubscribe_background(_state, _watch), do: :ok

  defp expire(state) do
    now = state.now.()

    state =
      Enum.reduce(state.tasks, state, fn {_ref, task}, state ->
        if now - task.started_at >= state.observation_timeout_ms do
          state
          |> stop_task(task.id)
          |> terminal(task.id, "unavailable", %{"summary" => "Status observation timed out."})
        else
          state
        end
      end)

    Enum.reduce(state.records, state, fn {id, record}, state ->
      if record.value["status"] == "watching" and record.value["deadline"] <= now,
        do:
          state
          |> stop_task(id)
          |> terminal(id, "timed_out", %{"summary" => "Watch deadline expired."}),
        else: state
    end)
  end

  defp stop_task(state, id) do
    tasks =
      Enum.reduce(state.tasks, state.tasks, fn {ref, task}, tasks ->
        if task.id == id do
          Task.shutdown(task.task, :brutal_kill)
          Map.delete(tasks, ref)
        else
          tasks
        end
      end)

    %{state | tasks: tasks}
  end

  defp deliver(%{session: nil} = state), do: state

  defp deliver(state) do
    {background, other} = Enum.split_with(pending_results(state), &batch_candidate?(state, &1))

    state =
      Enum.reduce(other, state, fn watch, state -> deliver_one(state, watch["id"], watch) end)

    if background == [] or state.delivery_timer,
      do: state,
      else: %{state | delivery_timer: Process.send_after(self(), :deliver_results, 100)}
  end

  defp batch_candidate?(state, watch),
    do:
      watch["source"] == "background" and watch["status"] == "completed" and watch["follow_up"] and
        state.authorize.(watch) == true

  defp pending_results(state),
    do:
      state.records
      |> Map.values()
      |> Enum.map(& &1.value)
      |> Enum.filter(&(&1["status"] != "watching" and &1["delivery"] == "pending"))

  # One receipt contains every component identity before inference begins.
  # Recovery may see only a subset of journal updates; those identities still
  # deduplicate against the same atomic transcript receipt.
  defp flush_deliveries(%{session: nil} = state), do: state

  defp flush_deliveries(state) do
    {background, other} = Enum.split_with(pending_results(state), &batch_candidate?(state, &1))

    state =
      Enum.reduce(other, state, fn watch, state -> deliver_one(state, watch["id"], watch) end)

    background |> Enum.chunk_every(8) |> Enum.reduce(state, &deliver_batch/2)
  end

  defp deliver_batch([watch], state), do: deliver_one(state, watch["id"], watch)

  defp deliver_batch(watches, state) do
    case notify(state.session, Record.batch(watches), true) do
      result when result in [:ok, :duplicate] ->
        Enum.reduce(watches, state, fn watch, state ->
          save(
            state,
            watch["id"],
            Map.merge(watch, %{
              "delivery" => "delivered",
              "continuation" => continuation(result, true)
            })
          )
        end)

      {:error, :partial_duplicate} ->
        Enum.reduce(watches, state, fn watch, state -> deliver_one(state, watch["id"], watch) end)

      _retry ->
        state
    end
  end

  defp deliver_one(state, id, watch) do
    authorized? =
      watch["follow_up"] and watch["status"] == "completed" and state.authorize.(watch) == true

    event = Record.event(watch)

    case notify(state.session, event, authorized?) do
      result when result in [:ok, :duplicate] ->
        save(
          state,
          id,
          Map.merge(watch, %{
            "delivery" => "delivered",
            "continuation" => continuation(result, authorized?)
          })
        )

      _retry ->
        state
    end
  end

  defp continuation(:duplicate, _authorized?), do: "already_delivered"
  defp continuation(:ok, true), do: "authorized"
  defp continuation(:ok, false), do: "notification_only"

  defp notify(session, event, authorized?) do
    Session.deliver_notification(session, event, follow_up: authorized?, preserve_turns: true)
  catch
    :exit, _reason -> {:error, :disconnected}
  end

  defp cleanup(state) do
    now = state.now.()

    Enum.reduce(state.records, state, fn {id, record}, state ->
      watch = record.value

      if watch["delivery"] == "delivered" and watch["result"] != nil and
           watch["finished_at"] + state.retention_ms <= now,
         do: save(state, id, Record.forget(watch)),
         else: state
    end)
  end

  defp positive(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: value,
      else: raise(ArgumentError, "#{key} must be a positive integer")
  end
end
