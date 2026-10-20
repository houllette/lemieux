defmodule Lemieux.Jobs do
  @moduledoc """
  An opt-in, single-node host for bounded durable coding jobs.

  Mount this separately from `Lemieux.Supervisor`. Supply a journal, a
  locking transcript store, a `factory` (`job -> {:ok, session_options}`)
  and `authorize` (`action, job, current_authority -> :ok | {:error, reason}`).
  The factory reconstructs credentials, tools, hooks and environment from
  current host policy on every attempt. None of them is serialized as authority.
  The authorizer controls submission, reading, recovery, cancellation,
  resolution, reconciliation and dispatch. These callbacks are trusted host
  code; they must return promptly and must not call this manager.

  Submit an inert intent with `prompt`, absolute `cwd`, and `limits` containing
  `max_requests` and/or `max_cost_usd`. Optional `run_at` is a UTC ISO timestamp,
  and `timeout_ms` is the job's whole elapsed allowance after its first start.
  One-shot schedules survive restart; recurring schedules and remote transports
  belong to the embedding host. Queue and execution concurrency are bounded.

  Attach subscribes to `{:lemieux_job, id, event}` and returns a durable
  snapshot. Detach only removes that subscription. The manager owns the work,
  not the connection. Approval resolution names the current attempt epoch and
  exact session/call, and is checked against current host authority.

  Restart quarantines active jobs as interrupted. `recover/3` is explicit:
  completed effects are repaired into their transcripts, safe interrupted
  tools can be retried through fresh hooks, and ambiguous effects block recovery
  until `reconcile/5` records host evidence. Reservations and consumed requests
  survive. Unmeasured dollars close cost admission until the host supplies a
  documented cumulative accounting reconciliation; original caps cannot grow.

  This does not promise exactly-once external effects. There is always a gap
  between an external effect and its receipt. A journal start without a finish
  remains uncertainty, including after cancellation. A report links the job,
  transcript, effect receipts, checks, failures and inclusive accounting; a
  model stopping is separate from its changes passing verification.

  Owned background commands hold a normal model stop open until their results
  are consumed. Completion resumes the same attempt under its existing ledger
  and deadline; cancellation stops the commands and revokes the continuation.
  """
  use GenServer, restart: :temporary
  @behaviour Lemieux.Execution
  alias Lemieux.Background.Completion
  alias Lemieux.Contract
  alias Lemieux.Extensions.Verify
  alias Lemieux.JobBudget
  alias Lemieux.Jobs.Intent
  alias Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Ledger
  alias Lemieux.Jobs.Recovery
  alias Lemieux.Session
  alias Lemieux.Session.Document
  alias Lemieux.Store
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Transcript
  @terminal ~w(completed failed limited cancelled)
  @active_status ~w(starting running waiting_approval cancelling)

  @doc "Starts an explicitly configured job host; starts no runtime implicitly."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "Persists a bounded intent before making it eligible for dispatch."
  @spec submit(server :: GenServer.server(), intent :: map(), authority :: term()) ::
          {:ok, map()} | {:error, term()}
  def submit(server, intent, authority \\ nil),
    do: GenServer.call(server, {:submit, intent, authority})

  @doc "Reads the job, inclusive accounting and surviving pending approvals."
  @spec get(server :: GenServer.server(), id :: String.t(), authority :: term()) ::
          {:ok, map()} | {:error, term()}
  def get(server, id, authority \\ nil), do: GenServer.call(server, {:get, id, authority})
  @doc "Lists a bounded page; the last id is the next cursor."
  @spec list(server :: GenServer.server(), cursor :: String.t() | nil, authority :: term()) ::
          {:ok, [map()]} | {:error, term()}
  def list(server, cursor \\ nil, authority \\ nil),
    do: GenServer.call(server, {:list, cursor, authority})

  @doc "Reads a bounded page of dispatch intents and outcome receipts for a job."
  @spec effects(
          server :: GenServer.server(),
          id :: String.t(),
          cursor :: String.t() | nil,
          authority :: term()
        ) :: {:ok, [Journal.stored_record()]} | {:error, term()}
  def effects(server, id, cursor \\ nil, authority \\ nil),
    do: GenServer.call(server, {:effects, id, cursor, authority})

  @doc "Subscribes an observer without transferring job ownership."
  @spec attach(
          server :: GenServer.server(),
          id :: String.t(),
          subscriber :: pid(),
          authority :: term()
        ) :: {:ok, map()} | {:error, term()}
  def attach(server, id, subscriber \\ self(), authority \\ nil),
    do: GenServer.call(server, {:attach, id, subscriber, authority})

  @doc "Disconnects an observer; the job continues."
  @spec detach(server :: GenServer.server(), id :: String.t(), subscriber :: pid()) :: :ok
  def detach(server, id, subscriber \\ self()),
    do: GenServer.call(server, {:detach, id, subscriber})

  @doc "Fences new dispatch before stopping the root and its children."
  @spec cancel(server :: GenServer.server(), id :: String.t(), authority :: term()) ::
          :ok | {:error, term()}
  def cancel(server, id, authority \\ nil),
    do: GenServer.call(server, {:cancel, id, authority}, :infinity)

  @doc "Requests recovery with current host authorization and the original allowance."
  @spec recover(server :: GenServer.server(), id :: String.t(), authority :: term()) ::
          :ok | {:error, term()}
  def recover(server, id, authority \\ nil),
    do: GenServer.call(server, {:recover, id, authority}, :infinity)

  @doc "Resolves only a currently parked call in the named attempt."
  @spec resolve(
          server :: GenServer.server(),
          id :: String.t(),
          epoch :: String.t(),
          session_id :: String.t(),
          call_id :: String.t(),
          decision :: Lemieux.Hooks.decision(),
          authority :: term()
        ) :: :ok | {:error, term()}
  def resolve(server, id, epoch, session_id, call_id, decision, authority \\ nil),
    do:
      GenServer.call(
        server,
        {:resolve, id, epoch, session_id, call_id, {:decision, decision}, authority}
      )

  @doc "Answers a currently parked question under the current host and attempt."
  @spec answer(
          server :: GenServer.server(),
          id :: String.t(),
          epoch :: String.t(),
          session_id :: String.t(),
          call_id :: String.t(),
          answer :: String.t() | map(),
          authority :: term()
        ) :: :ok | {:error, term()}
  def answer(server, id, epoch, session_id, call_id, answer, authority \\ nil),
    do:
      GenServer.call(
        server,
        {:resolve, id, epoch, session_id, call_id, {:answer, answer}, authority}
      )

  @doc """
  Records external reconciliation under current host authority.

  `key` is an effect key or `"budget"`. Every decision needs a nonempty
  `evidence` string naming the host's proof. Effects accept `status: "completed"`
  with a result or `status: "not_run"`; the latter is an explicit host assertion
  that repetition has no prior external effect. Budget decisions carry the
  verified cumulative `spent_usd`, never a replacement request allowance.
  Reconciliation is refused while a job is running or an effect is unresolved.
  """
  @spec reconcile(
          server :: GenServer.server(),
          id :: String.t(),
          key :: String.t(),
          decision :: map(),
          authority :: term()
        ) :: :ok | {:error, term()}
  def reconcile(server, id, key, decision, authority \\ nil),
    do: GenServer.call(server, {:reconcile, id, key, decision, authority})

  @impl Lemieux.Execution
  def start({server, id, epoch}, effect),
    do: GenServer.call(server, {:effect, id, epoch, effect}, :infinity)

  @impl Lemieux.Execution
  def finish({server, id, epoch}, token, result),
    do: GenServer.call(server, {:receipt, id, epoch, token, result}, :infinity)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    factory = Keyword.fetch!(opts, :factory)
    authorize = Keyword.fetch!(opts, :authorize)

    unless is_function(factory, 1) and is_function(authorize, 3),
      do: raise(ArgumentError, "jobs require factory/1 and authorize/3")

    journal = Keyword.fetch!(opts, :journal)

    case Journal.lock(journal, "host") do
      {:ok, lock} ->
        state = %{
          journal: journal,
          lock: lock,
          store: Keyword.fetch!(opts, :store),
          runtime: Keyword.fetch!(opts, :supervisor),
          factory: factory,
          authorize: authorize,
          max_active: positive!(opts, :max_active, 2),
          max_pending: positive!(opts, :max_pending, 100),
          max_subscribers: positive!(opts, :max_subscribers, 64),
          poll_ms: positive!(opts, :poll_ms, 250),
          queued: %{},
          active: %{},
          sessions: %{},
          subscribers: %{},
          inflight: %{}
        }

        state = restore(state, nil)
        send(self(), :poll)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp positive!(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: value,
      else: raise(ArgumentError, "job #{key} must be positive")
  end

  defp restore(state, cursor) do
    {:ok, records} = Journal.pending(state.journal, cursor, 100)

    state =
      Enum.reduce(records, state, fn record, state ->
        job = record.value

        cond do
          job["version"] != 1 ->
            raise "unsupported job record version"

          job["status"] in @active_status ->
            save!(state, job["id"], %{"status" => "interrupted"})
            state

          job["status"] == "queued" ->
            restore_queued(state, job)

          true ->
            state
        end
      end)

    if records == [], do: state, else: restore(state, List.last(records).key)
  end

  defp restore_queued(state, job) do
    if map_size(state.queued) >= state.max_pending,
      do: raise("persisted job queue exceeds host max_pending")

    put_in(state.queued[job["id"]], %{job: job, authority: nil})
  end

  @impl GenServer
  def handle_call({:submit, intent, authority}, _from, state) do
    intent =
      if is_map(intent),
        do: Map.put(intent, "timeout_ms", intent["timeout_ms"] || :timer.hours(1)),
        else: intent

    with :ok <- valid_intent(intent),
         :ok <- state.authorize.(:submit, %{"intent" => intent}, authority),
         true <- map_size(state.queued) + map_size(state.active) < state.max_pending do
      id = Lemieux.ID.generate()

      job = %{
        "version" => 1,
        "id" => id,
        "session_id" => Lemieux.ID.generate(),
        "intent" => intent,
        "status" => "queued",
        "epoch" => nil,
        "attempt" => 0,
        "created_at" => now(),
        "deadline_at" => nil,
        "sessions" => [],
        "result" => nil
      }

      job = Map.put(job, "sessions", [job["session_id"]])
      {:ok, _record} = Journal.write(state.journal, "job-" <> id, 0, job)
      send(self(), :dispatch)
      {:reply, {:ok, job}, put_in(state.queued[id], %{job: job, authority: authority})}
    else
      false -> {:reply, {:error, :queue_full}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:list, cursor, authority}, _from, state) do
    with :ok <- valid_cursor(cursor),
         :ok <- state.authorize.(:list, %{}, authority),
         {:ok, records} <-
           Journal.scan(state.journal, "job-", if(cursor, do: "job-" <> cursor), 100) do
      records = Enum.filter(records, &(state.authorize.(:read, &1.value, authority) == :ok))
      {:reply, {:ok, Enum.map(records, & &1.value)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:get, id, authority}, _from, state),
    do: {:reply, read_authorized(state, id, authority), state}

  def handle_call({:effects, id, cursor, authority}, _from, state) do
    with :ok <- valid_cursor(cursor),
         {:ok, job} <- job(state, id),
         :ok <- state.authorize.(:read, job, authority) do
      {:reply, Journal.scan(state.journal, "effect-" <> id <> "-", cursor, 100), state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:attach, id, subscriber, authority}, _from, state) do
    with {:ok, job} <- read_authorized(state, id, authority),
         true <- is_pid(subscriber),
         :ok <- observer_room(state, {id, subscriber}) do
      key = {id, subscriber}

      state =
        if Map.has_key?(state.subscribers, key),
          do: state,
          else: put_in(state.subscribers[key], Process.monitor(subscriber))

      {:reply, {:ok, job}, state}
    else
      false -> {:reply, {:error, :invalid_subscriber}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:detach, id, subscriber}, _from, state) do
    {monitor, subscribers} = Map.pop(state.subscribers, {id, subscriber})
    if monitor, do: Process.demonitor(monitor, [:flush])
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:cancel, id, authority}, _from, state) do
    with {:ok, job} <- job(state, id), :ok <- state.authorize.(:cancel, job, authority) do
      state =
        if job["status"] in @terminal,
          do: state,
          else: stop_job(state, id, "cancelled", :cancelled)

      {:reply, :ok, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:recover, id, authority}, _from, state) do
    with {:ok, job} <- job(state, id),
         :ok <- state.authorize.(:recover, job, authority),
         true <- job["status"] in ["interrupted", "blocked"],
         :ok <- queue_room(state),
         :ok <- drained(state, job),
         :ok <- Recovery.assess(state.journal, job),
         :ok <- Recovery.repair(state.journal, job, state.store) do
      job = save!(state, id, %{"status" => "queued", "recover" => true})
      send(self(), :dispatch)
      {:reply, :ok, put_in(state.queued[id], %{job: job, authority: authority})}
    else
      false -> {:reply, {:error, :not_interrupted}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:resolve, id, epoch, session_id, call_id, decision, authority}, _from, state) do
    with {:ok, job} <- job(state, id),
         :ok <- state.authorize.(:resolve, job, authority),
         %{epoch: ^epoch} <- state.active[id],
         true <- session_id in job["sessions"],
         {:ok, session} <- Lemieux.session(state.runtime, session_id) do
      result = resolve_session(session, call_id, decision)
      state = if result == :ok, do: refresh_attention(state, job), else: state
      {:reply, result, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      _stale -> {:reply, {:error, :stale_attempt}, state}
    end
  end

  def handle_call({:reconcile, id, key, decision, authority}, _from, state) do
    with {:ok, job} <- job(state, id),
         :ok <- state.authorize.(:reconcile, job, authority),
         true <- job["status"] in ["interrupted", "blocked", "cancelled"],
         :ok <- drained(state, job),
         true <- is_map(decision) and nonempty?(decision["evidence"]) do
      {:reply, reconcile_record(state, job, key, decision), state}
    else
      false -> {:reply, {:error, :invalid_reconciliation}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:effect, id, epoch, effect}, {owner, _tag}, state) do
    with %{epoch: ^epoch, authority: authority} <- state.active[id],
         {:ok, job} <- job(state, id),
         true <- job["status"] in ~w(running waiting_approval),
         true <- not expired?(job),
         true <- effects_alive?(state, id),
         :ok <- state.authorize.(:dispatch, job, authority) do
      effect = Map.put(effect, "session_id", effect["session_id"] || job["session_id"])
      key = effect_key(id, effect)

      case record_effect(state, key, epoch, effect) do
        {:ok, _record} ->
          state = subscribe_session(state, id, effect["session_id"])
          monitor = Process.monitor(owner)
          state = put_in(state.inflight[monitor], %{id: id, key: key, owner: owner})
          {:reply, {:ok, key}, state}

        error ->
          {:reply, error, state}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
      _stale -> {:reply, {:error, :stale_or_stopped_job}, state}
    end
  end

  def handle_call({:receipt, id, epoch, key, result}, _from, state) do
    with %{epoch: ^epoch} <- state.active[id],
         {:ok, %{value: %{"epoch" => ^epoch, "status" => "started"}}} <-
           Journal.read(state.journal, key) do
      {:ok, _record} =
        Journal.update(
          state.journal,
          key,
          &Map.merge(&1, %{"status" => "completed", "result" => result, "finished_at" => now()})
        )

      {:reply, :ok, drop_effect(state, key)}
    else
      _stale -> {:reply, {:error, :stale_receipt}, state}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)

    state =
      Enum.reduce(state.active, state, fn {id, _active}, state ->
        {:ok, job} = job(state, id)
        if expired?(job), do: stop_job(state, id, "limited", :job_deadline), else: state
      end)

    {:noreply, dispatch(state)}
  end

  def handle_info(:dispatch, state), do: {:noreply, dispatch(state)}

  def handle_info({:background_cancelled, session_id}, state),
    do: handle_info({:lemieux, session_id, {:finished, :cancelled}}, state)

  def handle_info({:lemieux, session_id, event}, state) do
    case state.sessions[session_id] do
      nil ->
        {:noreply, state}

      id ->
        state = broadcast(state, id, {:session, session_id, event})
        {:noreply, session_event(state, id, session_id, event)}
    end
  end

  def handle_info({:track_session, session_id}, state) do
    case Lemieux.session(state.runtime, session_id) do
      {:ok, session} -> Session.subscribe(session, self())
      :error -> :ok
    end

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Enum.find(state.active, fn {_id, active} ->
           active.preparation && active.preparation.ref == ref
         end) do
      {id, active} ->
        Process.demonitor(ref, [:flush])
        {:ok, job} = job(state, id)
        state = prepared_result(state, job, active.authority, result)
        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    case state.inflight[monitor] do
      %{id: id} -> {:noreply, stop_job(state, id, "interrupted", :effect_result_lost)}
      nil -> session_down(state, monitor)
    end
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:start_prompt, id, recovering?}, state) do
    case state.active[id] do
      nil -> {:noreply, state}
      active -> begin_prompt(state, id, recovering?, active)
    end
  end

  defp prepared_result(state, job, authority, {:ok, opts}),
    do: launch(state, job, authority, opts)

  defp prepared_result(state, job, _authority, {:error, reason}),
    do: failed_start(state, job, reason)

  defp prepared_result(state, job, _authority, _invalid),
    do: failed_start(state, job, :invalid_factory_result)

  defp begin_prompt(state, id, recovering?, active) do
    {:ok, job} = job(state, id)

    result =
      if recovering? and has_prompt?(state, job),
        do: Session.continue(active.session),
        else: Session.prompt(active.session, job["intent"]["prompt"])

    if result == :ok,
      do: {:noreply, state},
      else: {:noreply, stop_job(state, id, "failed", :prompt_refused)}
  end

  defp session_down(state, monitor) do
    case Enum.find(state.active, fn {_id, active} -> active.monitor == monitor end) do
      {id, _active} ->
        {:noreply, stop_job(state, id, "interrupted", :session_down)}

      nil ->
        subscribers = Map.reject(state.subscribers, fn {_key, ref} -> ref == monitor end)
        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  defp effects_alive?(state, id),
    do:
      Enum.all?(
        state.inflight,
        fn {_monitor, effect} -> effect.id != id or Process.alive?(effect.owner) end
      )

  defp drop_effect(state, key) do
    inflight =
      Map.reject(state.inflight, fn {monitor, effect} ->
        if effect.key == key do
          Process.demonitor(monitor, [:flush])
          true
        else
          false
        end
      end)

    %{state | inflight: inflight}
  end

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.active, fn {id, _active} ->
      stop_job(state, id, "interrupted", :host_stopped)
    end)

    Journal.unlock(state.journal, "host", state.lock)
  end

  defp dispatch(state) do
    slots = state.max_active - map_size(state.active)

    eligible =
      state.queued
      |> Enum.filter(fn {_id, queued} -> due?(queued.job) end)
      |> Enum.sort_by(fn {id, queued} -> {queued.job["created_at"], id} end)
      |> Enum.take(slots)

    Enum.reduce(eligible, state, fn {id, queued}, state ->
      state = %{state | queued: Map.delete(state.queued, id)}
      prepare_job(state, queued.job, queued.authority)
    end)
  end

  defp prepare_job(state, job, authority) do
    case state.authorize.(:run, job, authority) do
      :ok ->
        job =
          save!(state, job["id"], %{
            "status" => "starting",
            "attempt" => job["attempt"] + 1,
            "epoch" => Lemieux.ID.generate(),
            "deadline_at" => job["deadline_at"] || deadline(job)
          })

        factory = state.factory

        task =
          Task.Supervisor.async_nolink(Sup.task_supervisor(state.runtime), fn -> factory.(job) end)

        watch_preparation(state.runtime, task.pid, self())

        active = %{
          preparation: task,
          monitor: task.ref,
          epoch: job["epoch"],
          authority: authority,
          session: nil,
          budget: nil
        }

        state = put_in(state.active[job["id"]], active)
        broadcast(state, job["id"], {:status, job})

      {:error, reason} ->
        failed_start(state, job, reason)
    end
  end

  defp launch(state, job, authority, opts) do
    with :ok <- state.authorize.(:run, job, authority),
         true <- is_list(opts),
         false <- expired?(job) do
      job = save!(state, job["id"], %{"status" => "running"})
      execution = {__MODULE__, {self(), job["id"], job["epoch"]}}
      {:ok, budget} = Ledger.start(state.journal, job, execution, state.runtime)

      opts =
        Keyword.merge(opts,
          supervisor: state.runtime,
          store: state.store,
          id: job["session_id"],
          subscriber: self(),
          cwd: job["intent"]["cwd"],
          execution: execution,
          job_budget: budget,
          job_limits: nil,
          recovery_stop: Recovery.stop_reason(state.journal, job, state.store),
          recover_tools: job["recover"] == true
        )

      result =
        case Store.read(state.store, job["session_id"]) do
          {:ok, entries} -> Lemieux.start_session(Keyword.put(opts, :entries, entries))
          {:error, :not_found} -> Lemieux.start_session(opts)
          error -> error
        end

      case result do
        {:ok, session} ->
          active = %{
            session: session,
            budget: budget,
            preparation: nil,
            monitor: Process.monitor(session),
            epoch: job["epoch"],
            authority: authority
          }

          state =
            state
            |> put_in([:active, job["id"]], active)
            |> put_in([:sessions, job["session_id"]], job["id"])

          watch_host(state.runtime, session, self())
          send(self(), {:start_prompt, job["id"], job["recover"] == true})
          broadcast(state, job["id"], {:status, job})

        {:error, reason} ->
          GenServer.stop(budget)
          failed_start(state, job, reason)
      end
    else
      {:error, reason} -> failed_start(state, job, reason)
      true -> stop_job(state, job["id"], "limited", :job_deadline)
      false -> failed_start(state, job, :invalid_factory_options)
    end
  end

  defp failed_start(state, job, reason) do
    job = save!(state, job["id"], %{"status" => "blocked", "failure" => inspect(reason)})
    state = broadcast(state, job["id"], {:status, job})
    %{state | active: Map.delete(state.active, job["id"])}
  end

  defp session_event(state, id, session_id, {:finished, reason}) do
    if state.active[id] && is_pid(state.active[id].session) &&
         Session.id(state.active[id].session) == session_id do
      if reason == :stop and Completion.settle(state.active[id].session) == :waiting,
        do: state,
        else: stop_job(state, id, terminal_status(reason), reason)
    else
      state
    end
  end

  defp session_event(state, id, _session_id, {kind, _call})
       when kind in [:tool_approval, :question] do
    job = save!(state, id, %{"status" => "waiting_approval"})
    broadcast(state, id, {:status, job})
  end

  defp session_event(state, _id, _session_id, _event), do: state

  defp refresh_attention(state, job) do
    status =
      if Recovery.pending(state.store, job["sessions"]) == [],
        do: "running",
        else: "waiting_approval"

    current = save!(state, job["id"], %{"status" => status})
    broadcast(state, job["id"], {:status, current})
  end

  defp stop_job(state, id, status, reason) do
    {:ok, job} = job(state, id)
    save!(state, id, %{"status" => "cancelling"})
    active = state.active[id]

    if active do
      if active.preparation, do: Task.shutdown(active.preparation, 0)
      Enum.each(job["sessions"], &stop_session(state, &1, status))

      if is_pid(active.budget) and Process.alive?(active.budget) do
        JobBudget.snapshot(active.budget)
        GenServer.stop(active.budget)
      end

      Process.demonitor(active.monitor, [:flush])
    end

    state =
      Enum.reduce(state.inflight, state, fn {_monitor, effect}, current ->
        if effect.id == id, do: drop_effect(current, effect.key), else: current
      end)

    result = report(state, job, reason)
    job = save!(state, id, %{"status" => status, "result" => result})
    state = broadcast(state, id, {:status, job})

    %{
      state
      | active: Map.delete(state.active, id),
        queued: Map.delete(state.queued, id),
        sessions: Map.reject(state.sessions, fn {_session_id, job_id} -> job_id == id end)
    }
  end

  defp stop_session(state, session_id, status) do
    case Lemieux.session(state.runtime, session_id) do
      {:ok, session} ->
        Completion.cancel(state.runtime, session_id)
        if status not in ["completed", "interrupted"], do: Session.cancel(session, :job_stopped)
        DynamicSupervisor.terminate_child(Sup.session_supervisor(state.runtime), session)

      :error ->
        :ok
    end
  end

  defp report(state, job, reason) do
    entries =
      case Store.read(state.store, job["session_id"]) do
        {:ok, entries} -> entries
        {:error, :not_found} -> []
        {:error, error} -> raise "could not read job result: #{inspect(error)}"
      end

    text =
      case Transcript.latest_assistant_text(entries) do
        {:ok, text} -> text
        {:error, :not_found} -> nil
      end

    evidence = Enum.filter(entries, &(&1.type in [:run_evidence, :error]))

    {:ok, verification} =
      Document.read(Enum.reverse(entries), Verify.namespace())

    %{
      "job_id" => job["id"],
      "session_id" => job["session_id"],
      "sessions" => job["sessions"],
      "text" => if(text, do: String.slice(text, 0, 16_000)),
      "text_truncated" => is_binary(text) and String.length(text) > 16_000,
      "stop_reason" => Contract.json(reason),
      "budget" => Ledger.snapshot(state.journal, job["id"]),
      "verification" => verification.value,
      "evidence" =>
        evidence
        |> Enum.take(-32)
        |> Enum.map(&%{"entry_id" => &1.id, "type" => to_string(&1.type)}),
      "evidence_complete" => length(evidence) <= 32,
      "effects_prefix" => "effect-" <> job["id"] <> "-"
    }
  end

  defp subscribe_session(state, _id, nil), do: state

  defp subscribe_session(state, id, session_id) do
    if state.sessions[session_id] do
      state
    else
      send(self(), {:track_session, session_id})
      {:ok, job} = job(state, id)
      save!(state, id, %{"sessions" => Enum.uniq(job["sessions"] ++ [session_id])})
      put_in(state.sessions[session_id], id)
    end
  end

  defp record_effect(state, key, epoch, effect) do
    record = %{"epoch" => epoch, "effect" => effect, "status" => "started", "started_at" => now()}

    case Journal.read(state.journal, key) do
      {:error, :not_found} ->
        Journal.write(state.journal, key, 0, record)

      {:ok, previous} ->
        allowed? =
          previous.value["status"] == "not_run" or
            (previous.value["status"] == "started" and
               Recovery.retryable?(previous.value["effect"]) and
               previous.value["effect"]["descriptor"] == effect["descriptor"])

        if allowed?,
          do:
            Journal.write(
              state.journal,
              key,
              previous.revision,
              Map.put(
                record,
                "previous",
                Map.take(previous.value, ~w(status evidence started_at))
              )
            ),
          else: {:error, :effect_requires_reconciliation}

      error ->
        error
    end
  end

  defp reconcile_record(state, job, "budget", decision) do
    cost = decision["spent_usd"]

    with true <- is_number(cost) and cost >= 0,
         true <- cost + 0.000001 >= Recovery.measured_cost(state.journal, job["id"]),
         :ok <- Recovery.assess(state.journal, job),
         {:ok, record} <- Journal.read(state.journal, "budget-" <> job["id"]),
         true <- not is_number(record.value["spent_usd"]) or cost >= record.value["spent_usd"] do
      {:ok, _record} =
        Journal.write(
          state.journal,
          record.key,
          record.revision,
          Map.merge(record.value, %{
            "spent_usd" => cost,
            "reserved_usd" => 0,
            "active" => 0,
            "unmeasured" => 0,
            "reconciliation" => decision
          })
        )

      :ok
    else
      false -> {:error, :invalid_accounting}
      error -> error
    end
  end

  defp reconcile_record(state, job, key, decision) do
    with true <- is_binary(key) and String.starts_with?(key, "effect-" <> job["id"] <> "-"),
         true <- decision["status"] in ["completed", "not_run"],
         {:ok, record} <- Journal.read(state.journal, key),
         true <- record.value["status"] == "started",
         true <- Recovery.valid_reconciliation?(record.value["effect"], decision) do
      {:ok, _record} =
        Journal.write(
          state.journal,
          key,
          record.revision,
          Map.merge(record.value, Map.take(decision, ~w(status result evidence)))
        )

      :ok
    else
      false -> {:error, :invalid_effect_reconciliation}
      error -> error
    end
  end

  defp read_authorized(state, id, authority) do
    with {:ok, job} <- job(state, id),
         :ok <- state.authorize.(:read, job, authority),
         do:
           {:ok,
            Map.merge(job, %{
              "budget" => Ledger.snapshot(state.journal, id),
              "pending" => Recovery.pending(state.store, job["sessions"])
            })}
  end

  defp job(state, id) when is_binary(id) do
    case Journal.read(state.journal, "job-" <> id) do
      {:ok, record} -> {:ok, record.value}
      error -> error
    end
  end

  defp job(_state, _id), do: {:error, :invalid_job_id}

  defp queue_room(state) do
    if map_size(state.queued) + map_size(state.active) < state.max_pending,
      do: :ok,
      else: {:error, :queue_full}
  end

  defp valid_cursor(nil), do: :ok
  defp valid_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 200, do: :ok
  defp valid_cursor(_cursor), do: {:error, :invalid_cursor}

  defp save!(state, id, changes) do
    {:ok, record} = Journal.update(state.journal, "job-" <> id, &Map.merge(&1, changes))
    record.value
  end

  defp resolve_session(session, call, {:decision, decision}),
    do: Session.resolve_tool(session, call, decision)

  defp resolve_session(session, call, {:answer, answer}),
    do: Session.answer(session, call, answer)

  defp observer_room(state, key) do
    if Map.has_key?(state.subscribers, key) or map_size(state.subscribers) < state.max_subscribers,
      do: :ok,
      else: {:error, :observer_limit}
  end

  defp broadcast(state, id, event) do
    Enum.reduce(state.subscribers, state, fn {{job_id, subscriber} = key, monitor}, current ->
      if job_id == id, do: deliver(current, key, subscriber, monitor, event), else: current
    end)
  end

  defp deliver(state, {id, _subscriber} = key, subscriber, monitor, event) do
    case Process.info(subscriber, :message_queue_len) do
      {:message_queue_len, length} when length < 256 ->
        send(subscriber, {:lemieux_job, id, event})
        state

      _slow_or_gone ->
        send(subscriber, {:lemieux_job, id, {:detached, :slow_consumer}})
        Process.demonitor(monitor, [:flush])
        %{state | subscribers: Map.delete(state.subscribers, key)}
    end
  end

  defp effect_key(id, effect),
    do:
      "effect-" <>
        id <>
        "-" <> Contract.digest(Map.take(effect, ~w(kind session_id request_id wave_id call_id)))

  defp drained(state, job) do
    if Enum.any?(job["sessions"], &match?({:ok, _pid}, Lemieux.session(state.runtime, &1))),
      do: {:error, :still_running},
      else: :ok
  end

  defp has_prompt?(state, job) do
    case Store.read(state.store, job["session_id"]) do
      {:ok, entries} -> Enum.any?(entries, &(&1.type == :user))
      _missing -> false
    end
  end

  defp watch_preparation(runtime, task, host) do
    Task.Supervisor.start_child(Sup.task_supervisor(runtime), fn ->
      owner = Process.monitor(host)
      child = Process.monitor(task)

      receive do
        {:DOWN, ^owner, :process, _pid, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^child, :process, _pid, _reason} -> :ok
      end

      Process.demonitor(owner, [:flush])
      Process.demonitor(child, [:flush])
    end)
  end

  defp watch_host(runtime, session, host) do
    Task.Supervisor.start_child(Sup.task_supervisor(runtime), fn ->
      owner = Process.monitor(host)
      child = Process.monitor(session)

      receive do
        {:DOWN, ^owner, :process, _pid, _reason} ->
          if Process.alive?(session) do
            DynamicSupervisor.terminate_child(Sup.session_supervisor(runtime), session)
          end

        {:DOWN, ^child, :process, _pid, _reason} ->
          :ok
      end

      Process.demonitor(owner, [:flush])
      Process.demonitor(child, [:flush])
    end)
  end

  defp valid_intent(intent), do: Intent.validate(intent)
  defp nonempty?(value), do: is_binary(value) and String.trim(value) != ""
  defp due?(job), do: due_at?(job["intent"]["run_at"])
  defp expired?(job), do: not is_nil(job["deadline_at"]) and due_at?(job["deadline_at"])

  defp due_at?(nil), do: true

  defp due_at?(value) do
    {:ok, time, 0} = DateTime.from_iso8601(value)
    DateTime.compare(time, DateTime.utc_now()) != :gt
  end

  defp deadline(job) do
    if job["intent"]["timeout_ms"],
      do:
        DateTime.utc_now()
        |> DateTime.add(job["intent"]["timeout_ms"], :millisecond)
        |> DateTime.to_iso8601()
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp terminal_status(:stop), do: "completed"
  defp terminal_status(:cancelled), do: "cancelled"
  defp terminal_status({:budget, _reason}), do: "limited"
  defp terminal_status(reason) when reason in [:max_turns, :length, :no_progress], do: "limited"
  defp terminal_status(_reason), do: "failed"
end
