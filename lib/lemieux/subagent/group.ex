defmodule Lemieux.Subagent.Group do
  @moduledoc """
  The monitored coordinator for one foreground, all-settled child fan-out.

  A group owns only orchestration state: ordered requests, admission, child
  monitors, deadlines, cancellation, steering provenance, and aggregation.
  Each child is a complete temporary `Lemieux.Session`, so this process never
  duplicates the model/tool loop. It monitors rather than links its parent and
  children; one failed investigation cannot take down its siblings or writer.

  Completed groups remain addressable until their runtime stops. Their durable
  truth is still the parent and child transcripts, so a coordinator crash is
  never restarted and cannot repeat paid work.

  ## Reserve, then record

  Admission runs before a single spawn intent is written. The other order
  looked harmless and was not: a refused fan-out left the parent transcript
  holding spawn intents for children that never existed, so replaying it
  produced a group nobody had admitted. When admission refuses, the refusal
  itself is recorded as an empty group result — the parent asked, and the
  answer was no, which is a fact about the run rather than an absence.

  ## One deadline, composed once

  A child had three clocks and no relationship between them: its own
  `timeout`, the group's, and whatever the host thought it had allowed. The
  effective deadline is now computed once from all of them, persisted in each
  spawn intent, and every child timer is clamped to what is left of it. A
  child therefore cannot outlive the group, and a group cannot outlive the
  host's allowance, however generous a definition is.

  ## The deadline is soft until the ceiling

  That composed deadline used to be two minutes by default, and it was the
  wrong guard: it killed children mid-answer while never being what caught a
  loop — budgets and the repeat rules do that. See `Lemieux.Progress` for the
  session that proved it. A child's clock now fires every
  `progress_interval` and *assesses* the child instead of cancelling it: a
  progressing child is given another interval, a stalled one is cancelled as
  `:failed` with the reason in its envelope, and only the hard deadline —
  the definition's `timeout`, the group's `:timeout` or the host's
  `:deadline_ms`, whichever is shortest — still cancels unconditionally.

  The assessment runs in a supervised task, never in this process: it takes
  a bounded snapshot of the child and may ask a model, and a coordinator
  that blocked on either could not answer a cancel. A verdict that arrives
  after the child finished, or after a newer check began, is dropped by its
  reference.

  ## Cancellation says why, and waits

  A cancellation carries a reason from whoever asked for it, and that reason
  reaches the child's own envelope rather than being discarded at the
  boundary. Children are cancelled concurrently — serially, one hung child
  delayed every sibling behind it — and the group then waits a bounded grace
  interval for them to settle before terminating whatever is left. The caller
  is answered when the last child is terminal or when the grace expires,
  whichever comes first, so `cancel/3` still means "they have stopped" while
  no longer meaning "one at a time".
  """

  use GenServer, restart: :temporary

  alias Lemieux.Clock
  alias Lemieux.OpenTelemetry
  alias Lemieux.Progress
  alias Lemieux.Session
  alias Lemieux.Subagent.Admission
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Group.Result, as: GroupResult
  alias Lemieux.Subagent.Request, as: SubagentRequest
  alias Lemieux.Subagent.Result
  alias Lemieux.Subagent.Snapshot
  alias Lemieux.Subagent.Task, as: SubagentTask
  alias Lemieux.Supervisor, as: Sup
  alias Lemieux.Telemetry
  alias Lemieux.Tool
  alias Lemieux.Usage

  # The group's own deadline when the caller names none: a ceiling on waiting, not
  # a guard against loops — those are the budgets and the repeat rules — so it is
  # set where a working child never meets it. There is deliberately no runtime
  # maximum above it; the one this replaced was three minutes, could not be raised
  # by any host, and was the clock that killed working scouts.
  @default_group_timeout :timer.hours(1)
  # How long a check waits for the child's snapshot. A child that cannot
  # answer in this long has its own problem, and its own clocks; the check
  # falls open rather than letting the child's state wedge the coordinator.
  @check_snapshot_ms 5_000
  @default_judge_timeout :timer.seconds(60)
  # How long a cancelled child is given to checkpoint its own work before the
  # group stops waiting for it. Long enough for a session to finish persisting
  # a turn, short enough that a hung child cannot hold a `cancel/3` caller
  # for the group's whole remaining deadline.
  @default_cancel_grace :timer.seconds(5)
  @terminal [:ok, :failed, :timeout, :cancelled, :budget_exhausted]
  @authorized_actions [:child_refs, :await, :inspect, :steer, :cancel]

  @doc """
  The control actions an optional `:authorize` callback is consulted about.

  Published so a host writes its policy against a closed vocabulary instead of
  a set it inferred from the calls it happened to see. A new action added here
  is a change a host has to notice, which is the point: a policy that silently
  allows something it has never heard of is not a policy.
  """
  @spec authorized_actions() :: [atom()]
  def authorized_actions, do: @authorized_actions

  @doc "Starts a temporary group under `Lemieux.Supervisor`."
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    supervisor = Keyword.fetch!(opts, :supervisor)
    name = {:via, Registry, {Sup.registry(supervisor), {:subagent_group, id}}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  @spec group_ref(group :: GenServer.server()) :: Lemieux.Subagent.Group.Ref.t()
  def group_ref(group), do: GenServer.call(group, :group_ref)

  @doc false
  @spec child_refs(group :: GenServer.server(), token :: reference()) ::
          {:ok, [Lemieux.Subagent.Ref.t()]} | {:error, :unauthorized}
  def child_refs(group, token), do: GenServer.call(group, {:child_refs, token})

  @doc false
  @spec await(group :: GenServer.server(), token :: reference(), timeout()) ::
          {:ok, GroupResult.t()} | {:error, term()}
  def await(group, token, timeout), do: GenServer.call(group, {:await, token}, timeout)

  @doc false
  @spec await_child(
          group :: GenServer.server(),
          token :: reference(),
          child_id :: String.t(),
          timeout()
        ) ::
          {:ok, Result.t()} | {:error, term()}
  def await_child(group, token, child_id, timeout),
    do: GenServer.call(group, {:await_child, token, child_id}, timeout)

  @doc false
  @spec inspect_child(group :: GenServer.server(), token :: reference(), child_id :: String.t()) ::
          {:ok, Snapshot.t()} | {:error, term()}
  def inspect_child(group, token, child_id),
    do: GenServer.call(group, {:inspect_child, token, child_id})

  @doc false
  @spec steer_child(
          group :: GenServer.server(),
          token :: reference(),
          child_id :: String.t(),
          instruction :: String.t()
        ) :: :ok | {:error, term()}
  def steer_child(group, token, child_id, instruction),
    do: GenServer.call(group, {:steer_child, token, child_id, instruction})

  @doc false
  @spec cancel_child(
          group :: GenServer.server(),
          token :: reference(),
          child_id :: String.t(),
          reason :: term()
        ) :: :ok | {:error, term()}
  def cancel_child(group, token, child_id, reason),
    do: GenServer.call(group, {:cancel_child, token, child_id, reason}, :infinity)

  @doc false
  @spec cancel(group :: GenServer.server(), token :: reference(), reason :: term()) ::
          :ok | {:error, term()}
  def cancel(group, token, reason), do: GenServer.call(group, {:cancel, token, reason}, :infinity)

  @impl GenServer
  def init(opts) do
    parent = Keyword.fetch!(opts, :parent)
    parent_id = Session.id(parent)
    id = Keyword.fetch!(opts, :id)
    token = Keyword.fetch!(opts, :control_token)
    supervisor = Keyword.fetch!(opts, :supervisor)
    requests = Keyword.fetch!(opts, :requests)
    child_ids = Keyword.fetch!(opts, :child_ids)
    root_budget = Keyword.fetch!(opts, :max_cost_usd)
    root_requests = Keyword.get(opts, :max_requests)
    context = Session.delegation_context(parent)
    parent_monitor = Process.monitor(parent)
    # Every deadline, check and grace period this group keeps is measured on
    # this clock — the real one unless a test hands it a
    # `Lemieux.Clock.Manual`. Telemetry durations stay on native monotonic
    # time: they measure what happened, they do not decide anything.
    clock = Keyword.get(opts, :clock)
    deadline = deadline(opts, requests, clock)
    group_timer = Clock.send_after(clock, self(), :group_timeout, deadline.budget_ms)

    children =
      requests
      |> Enum.zip(child_ids)
      |> Enum.with_index()
      |> Map.new(fn {{request, child_id}, index} ->
        {child_id,
         %{
           id: child_id,
           index: index,
           request: request,
           status: :queued,
           session: nil,
           monitor: nil,
           timer: nil,
           result: nil,
           # Why this child is being cancelled, as the caller gave it. Kept on
           # the child rather than the group because a single `cancel_child/4`
           # and a whole-group cancellation have different reasons and both
           # belong in the envelope the parent reads.
           cancel_reason: nil,
           # The terminal status a cancellation asked for. A session always
           # reports `:cancelled` however it was stopped, so without this a
           # child killed by its own deadline arrived at the parent looking
           # like one somebody cancelled on purpose.
           cancel_status: nil,
           queued_at: System.monotonic_time(),
           # The child's own clocks. `checked_seq` is the last transcript entry
           # the previous check read, so each check judges only its own
           # interval; `check_ref` identifies the check in flight, so a stale
           # verdict cannot act on a newer state.
           started_at: nil,
           deadline_at: nil,
           checks: 0,
           checked_seq: nil,
           check_ref: nil,
           check_monitor: nil,
           assessment_usage: []
         }}
      end)

    state = %{
      id: id,
      token: token,
      supervisor: supervisor,
      parent: parent,
      parent_id: parent_id,
      parent_monitor: parent_monitor,
      root_id: context.root_session_id,
      context: context,
      children: children,
      order: child_ids,
      status: :running,
      result: nil,
      waiters: [],
      child_waiters: %{},
      cancel_waiters: [],
      # The children this cancellation is still waiting on. `cancel_child/4` waits for
      # that child, not for every sibling: the whole-group version held its caller
      # until the last unrelated child finished, which made cancelling one child cost
      # the group's remaining deadline.
      cancel_pending: MapSet.new(),
      cancel_timer_ref: nil,
      cancel_started_at: nil,
      # How many children the grace deadline had to terminate, recorded before
      # they are completed: completing the last one settles the cancellation
      # from inside, and a count computed afterwards would always be zero.
      cancel_terminated: 0,
      cancel_grace: Keyword.get(opts, :cancel_grace_ms, @default_cancel_grace),
      deadline: deadline,
      group_timer: group_timer,
      progress: progress_policy(opts),
      root_budget: root_budget,
      authorize: Keyword.get(opts, :authorize),
      provider_factory: Keyword.get(opts, :provider_factory),
      providers: Keyword.get(opts, :providers, %{}),
      child_options: Keyword.get(opts, :child_options, []),
      policy: Keyword.get(opts, :policy, %{}),
      clock: clock
    }

    :ok = Session.register_subagent_group(parent, id, self())

    admission_children =
      Enum.map(child_ids, fn child_id ->
        child = Map.fetch!(children, child_id)

        %{
          id: child_id,
          duplicate_key: SubagentRequest.duplicate_key(child.request),
          # A request-bounded child reserves no dollars, because dollars are
          # not the currency on the route it runs on. It reserves requests
          # instead, against the tree's own request ceiling.
          reserved_cost_usd: child.request.definition.max_cost_usd || 0.0,
          reserved_requests: child.request.definition.max_requests
        }
      end)

    # Reserve first. Spawn intents written before admission described children
    # that a refusal then prevented from existing, and a replay of that prefix
    # reconstructed a fan-out nobody had admitted.
    case Admission.reserve(
           Sup.subagent_admission(supervisor),
           state.root_id,
           parent,
           id,
           self(),
           admission_children,
           root_budget,
           root_requests
         ) do
      :ok ->
        state = persist_spawn_intents(state)

        bind_child_parent_contexts(
          child_ids,
          Keyword.get(opts, :open_telemetry_parent_contexts, [])
        )

        Enum.each(child_ids, fn child_id ->
          Telemetry.event([:subagent, :admission, :start], %{}, %{
            group_id: id,
            child_id: child_id,
            root_session_id: state.root_id,
            session_id: parent_id
          })
        end)

        state = publish(state, :group_started, %{"children" => child_ids})
        {:ok, state}

      {:error, reason} ->
        record_refusal(state, reason)
        Session.unregister_subagent_group(parent, id)
        {:stop, reason}
    end
  end

  # The parent asked and was told no, which is a fact about the run. An empty
  # group result is the honest shape for it: no children, therefore no usage,
  # and the reason recorded where a replay will find it.
  defp record_refusal(state, reason) do
    payload =
      state.id
      |> GroupResult.new(state.parent_id, [])
      |> GroupResult.to_map()
      |> Map.merge(%{
        "refused" => %{
          "by" => "admission",
          "reason" => inspect(reason),
          "requested_children" => length(state.order)
        }
      })

    append_parent(state, :subagent_group_result, payload)
  end

  # One deadline, composed from every clock with a claim on the group: the caller's
  # timeout, an optional host allowance, and the longest child timeout the
  # definitions declare. A group outliving the shortest of those was outliving
  # whatever authorized it. The caller's own number is taken as given — a runtime
  # cap it could not raise was the deadline that killed working children — and
  # `deadline_source` still accepts the `"runtime_maximum"` those transcripts
  # recorded.
  defp deadline(opts, requests, clock) do
    requested = Keyword.get(opts, :timeout, @default_group_timeout)
    host = Keyword.get(opts, :deadline_ms, :infinity)
    longest_child = requests |> Enum.map(& &1.definition.timeout) |> Enum.max(fn -> 0 end)

    budget =
      [requested, host]
      |> Enum.filter(&is_integer/1)
      |> Enum.min()
      |> max(1)

    %{
      budget_ms: budget,
      at: Clock.now_ms(clock) + budget,
      source: source(requested, host, budget),
      longest_child_ms: longest_child
    }
  end

  defp source(requested, host, budget) do
    if is_integer(host) and host == budget and host < requested, do: "host", else: "group"
  end

  # Who decides at a soft deadline. `:model` (the default) lets the transcript
  # rules settle the clear cases and asks a model about the rest; `:activity` never
  # asks; `false` arms no checks, leaving the hard deadline as the only clock; a
  # function is the host's own assessor. The judge defaults to the child's own
  # provider and model, because that is the one route the group knows it has.
  defp progress_policy(opts) do
    policy = Keyword.get(opts, :progress, [])

    unless Keyword.keyword?(policy) do
      raise ArgumentError, "progress must be a keyword list, got: #{inspect(policy)}"
    end

    assess = Keyword.get(policy, :assess, :model)

    unless assess in [:model, :activity, false] or is_function(assess, 1) do
      raise ArgumentError,
            "progress assess must be :model, :activity, false or a one-argument function, " <>
              "got: #{inspect(assess)}"
    end

    %{
      assess: assess,
      provider: Keyword.get(policy, :provider),
      model: Keyword.get(policy, :model),
      timeout_ms: Keyword.get(policy, :timeout_ms, @default_judge_timeout)
    }
  end

  defp assess_label(%{assess: :model}), do: "model"
  defp assess_label(%{assess: :activity}), do: "activity"
  defp assess_label(%{assess: false}), do: "none"
  defp assess_label(%{assess: _fun}), do: "host"

  # What is left of the composed deadline, which is the ceiling on every child
  # timer. A definition may declare two minutes; if the group has thirty
  # seconds left, the child gets thirty seconds.
  defp remaining(state),
    do: max(state.deadline.at - Clock.now_ms(state.clock), 0)

  defp child_timeout(state, definition), do: min(definition.timeout, remaining(state))

  @impl GenServer
  def handle_call(:group_ref, _from, state), do: {:reply, build_group_ref(state), state}

  def handle_call({:child_refs, token}, _from, state) do
    case allowed(state, token, :child_refs, nil) do
      :ok -> {:reply, {:ok, Enum.map(state.order, &child_ref(state, &1))}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:await, token}, from, state) do
    case allowed(state, token, :await, nil) do
      {:error, _reason} = error ->
        {:reply, error, state}

      :ok ->
        if state.result,
          do: {:reply, {:ok, state.result}, state},
          else: {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call({:await_child, token, child_id}, from, state) do
    with :ok <- allowed(state, token, :await, child_id),
         {:ok, child} <- Map.fetch(state.children, child_id) do
      if child.result do
        {:reply, {:ok, child.result}, state}
      else
        waiters = Map.update(state.child_waiters, child_id, [from], &[from | &1])
        {:noreply, %{state | child_waiters: waiters}}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:inspect_child, token, child_id}, _from, state) do
    with :ok <- allowed(state, token, :inspect, child_id),
         {:ok, child} <- Map.fetch(state.children, child_id) do
      {:reply, {:ok, snapshot(state, child)}, state}
    else
      {:error, _reason} = error -> {:reply, error, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:steer_child, token, child_id, instruction}, _from, state) do
    with :ok <- allowed(state, token, :steer, child_id),
         {:ok, %{status: :running, session: session}} <- Map.fetch(state.children, child_id),
         :ok <- persist_steer(state, child_id, instruction),
         :ok <- Session.steer(session, instruction) do
      state = publish(state, :child_steered, %{"child_id" => child_id})
      {:reply, :ok, state}
    else
      :error -> {:reply, {:error, :not_found}, state}
      {:ok, _child} -> {:reply, {:error, :not_running}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:cancel_child, token, child_id, reason}, from, state) do
    with :ok <- allowed(state, token, :cancel, child_id),
         {:ok, child} <- Map.fetch(state.children, child_id) do
      if child.status in @terminal do
        {:reply, :ok, state}
      else
        {:noreply, begin_cancel(state, [child], :cancelled, reason, from)}
      end
    else
      {:error, _reason} = error -> {:reply, error, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:cancel, token, reason}, from, state) do
    case allowed(state, token, :cancel, nil) do
      :ok -> {:noreply, cancel_all(state, :cancelled, reason, from)}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl GenServer
  def handle_info({:subagent_admitted, child_id}, state) do
    case state.children[child_id] do
      %{status: :queued} = child -> {:noreply, start_child(state, child)}
      _terminal_or_unknown -> {:noreply, state}
    end
  end

  def handle_info({:child_prompted, _child_id, :ok}, state), do: {:noreply, state}

  def handle_info({:child_prompted, child_id, {:error, reason}}, state) do
    {:noreply, fail_child(state, child_id, {:prompt_failed, reason})}
  end

  def handle_info({:lemieux, child_id, event}, state) do
    state = publish_child_event(state, child_id, event)

    case event do
      {:finished, reason} -> {:noreply, finish_from_session(state, child_id, reason)}
      _event -> {:noreply, state}
    end
  end

  # The child's clock. Past the hard deadline it is a timeout, as it always
  # was; before it, it is a check, and the child keeps running while the
  # check decides.
  def handle_info({:child_clock, child_id}, state) do
    case state.children[child_id] do
      # A child already being cancelled has had its verdict; a check now
      # could only overwrite the reason it is being stopped for.
      %{status: :running, cancel_status: nil} = child ->
        if Clock.now_ms(state.clock) >= child.deadline_at,
          do: {:noreply, begin_cancel(state, [child], :timeout, :child_deadline, nil)},
          else: {:noreply, begin_check(state, child)}

      _cancelling_terminal_or_unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:child_verdict, child_id, ref, verdict, last_seq}, state) do
    case state.children[child_id] do
      %{status: :running, cancel_status: nil, check_ref: ^ref} = child ->
        {:noreply, conclude_check(state, child, verdict, last_seq)}

      _stale_cancelling_or_terminal ->
        {:noreply, state}
    end
  end

  # A child's session has replied to `cancel/2`, so it has checkpointed. Its
  # `{:finished, :cancelled}` event usually arrives first and completes it;
  # this covers the one that does not emit one.
  def handle_info({:child_cancel_requested, child_id}, state) do
    case state.children[child_id] do
      %{status: status} = child when status not in @terminal ->
        {:noreply, maybe_settled(force_complete(state, child))}

      _terminal_or_unknown ->
        {:noreply, state}
    end
  end

  def handle_info(:group_timeout, state),
    do: {:noreply, cancel_all(state, :timeout, {:deadline, state.deadline.source}, nil)}

  def handle_info({:parent_cancel, reason}, state),
    do: {:noreply, cancel_all(state, :cancelled, reason, nil)}

  # The grace interval is over. Whatever is still running did not checkpoint
  # itself in time, so it is terminated and recorded with whatever it had.
  def handle_info(:cancel_grace, state) do
    stragglers =
      state.cancel_pending
      |> Enum.map(&state.children[&1])
      |> Enum.reject(&(is_nil(&1) or &1.status in @terminal))

    state = %{state | cancel_timer_ref: nil, cancel_terminated: length(stragglers)}

    # Terminated first, then completed: a child that missed its grace may be wedged
    # in a way that makes every call into it block, including the snapshot and the
    # result append, so the coordinator stops talking to it before it needs anything
    # from it. Its transcript is durable, and the parent's copy is what replay reads.
    state =
      Enum.reduce(stragglers, state, fn child, state ->
        child = state.children[child.id]
        if child.session, do: terminate_session(state, child.session)
        force_complete(state, child)
      end)

    {:noreply, settled(state)}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{parent_monitor: ref, parent: pid} = state
      ) do
    state =
      cancel_all(
        %{state | parent: nil, status: :cancelling},
        :cancelled,
        {:parent_down, reason},
        nil
      )

    # A finished parent going away is the group's expected end of life, not a crash:
    # under a plain `{:parent_down, _}` reason every completed delegation logged an
    # error report. The `:shutdown` wrapper keeps the cause visible to anyone
    # monitoring the group and keeps the logger quiet.
    if state.result,
      do: {:stop, {:shutdown, {:parent_down, reason}}, state},
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.children, fn {_id, child} ->
           ref in [child.monitor, child.check_monitor]
         end) do
      {child_id, %{monitor: ^ref, status: status}} when status not in @terminal ->
        {:noreply, fail_child(state, child_id, {:session_crashed, reason})}

      # A check that died before answering must not leave the child without
      # a clock. It falls open, as a judge that could not answer does, and
      # the next interval is armed.
      {_child_id, %{check_monitor: ^ref, status: :running, check_ref: check} = child}
      when is_reference(check) ->
        verdict = %Progress.Verdict{
          outcome: :progressing,
          by: :error,
          note: "the check stopped before answering (#{inspect(reason)}) and fell open"
        }

        {:noreply,
         conclude_check(state, %{child | check_monitor: nil}, verdict, child.checked_seq)}

      _unknown_or_terminal ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    if is_nil(state.result) do
      state.children
      |> Map.values()
      |> Enum.filter(&(&1.status == :running and is_pid(&1.session)))
      |> Enum.each(fn child ->
        try do
          Session.cancel(child.session, :group_terminated)
        catch
          :exit, _reason -> :ok
        end
      end)
    end

    Admission.release_group(Sup.subagent_admission(state.supervisor), state.id)

    if state.parent && Process.alive?(state.parent),
      do: Session.unregister_subagent_group(state.parent, state.id)

    Enum.each(state.children, fn {_child_id, child} ->
      OpenTelemetry.drop_prompt_parent(child.id)
    end)

    :ok
  end

  defp start_child(state, child) do
    request = child.request
    definition = request.definition
    provider = provider(state, request)
    extra = child_options(state.child_options, request)

    protected = [
      id: child.id,
      supervisor: state.supervisor,
      provider: provider,
      provider_limiter: state.context.provider_limiter,
      provider_limit_key: state.context.provider_limit_key,
      root_session_id: state.root_id,
      store: state.context.store,
      model: definition.model,
      system: system_prompt(state, request, child.id),
      output_schema: output_schema(definition),
      tools: definition.tools,
      hooks: state.context.hooks,
      cwd: state.context.cwd,
      environment: state.context.environment,
      max_turns: definition.max_turns,
      max_cost_usd: definition.max_cost_usd,
      max_requests: definition.max_requests,
      # One time for the whole tree. A test that drives the group on a
      # `Lemieux.Clock.Manual` drives its children's deadlines and retry
      # backoff with the same clock, rather than leaving them on the real
      # clock, which no amount of advancing reaches.
      clock: state.clock,
      subscriber: self()
    ]

    case start_session(Keyword.merge(extra, protected)) do
      {:ok, session} ->
        monitor = Process.monitor(session)
        now = Clock.now_ms(state.clock)

        # Clamped, not taken as declared: a definition's hour cannot outlast a
        # group with thirty seconds left on the composed deadline.
        child =
          %{
            child
            | status: :running,
              session: session,
              monitor: monitor,
              started_at: now,
              deadline_at: now + child_timeout(state, definition)
          }
          |> arm_clock(state)

        state = put_in(state.children[child.id], child)

        Telemetry.stop(
          [:subagent, :admission],
          child.queued_at,
          %{
            group_id: state.id,
            child_id: child.id,
            root_session_id: state.root_id,
            definition_id: definition.id,
            outcome: :admitted
          }
        )

        state = publish(state, :child_started, %{"child_id" => child.id})
        prompt_child(state, child)
        pressure(state)

      {:error, reason} ->
        fail_child(state, child.id, {:start_failed, reason})
    end
  end

  # `Lemieux.start_session/1` raises in its caller for a provider that is not
  # a `{module, state}` pair — a host's mistake, reported where it was made.
  # Here the caller is this coordinator, and the provider is whatever a host's
  # `:provider_factory` or `:providers` map handed one child: the raise took
  # the whole group down with it, siblings and all, where before that check
  # only the child failed. So the shape is checked first, and a malformed
  # provider fails its own child as any other start failure does — named by
  # key, never by value, since a provider's state carries its credentials and
  # the reason is written into the envelope the parent model reads.
  defp start_session(opts) do
    case Keyword.get(opts, :provider) do
      {module, _state} when is_atom(module) and not is_nil(module) ->
        Lemieux.start_session(opts)

      _malformed ->
        {:error, {:invalid_session_options, :provider}}
    end
  end

  defp prompt_child(state, child) do
    group = self()
    prompt = SubagentTask.prompt(child.request.task)

    Task.Supervisor.start_child(Sup.task_supervisor(state.supervisor), fn ->
      send(group, {:child_prompted, child.id, Session.prompt(child.session, prompt)})
    end)
  end

  defp cancel_all(%{result: %GroupResult{}} = state, _status, _reason, from) do
    if from, do: GenServer.reply(from, :ok)
    state
  end

  defp cancel_all(state, status, reason, from) do
    running =
      state.order |> Enum.map(&state.children[&1]) |> Enum.reject(&(&1.status in @terminal))

    begin_cancel(%{state | status: :cancelling}, running, status, reason, from)
  end

  # Every child is asked to stop at once, and the group keeps running so their
  # answers can arrive. Cancelling serially meant a hung child delayed every
  # sibling behind it and then the caller; here one hung child costs only the
  # grace interval, once, for all of them.
  defp begin_cancel(state, [], _status, _reason, from) do
    if from, do: GenServer.reply(from, :ok)
    state
  end

  defp begin_cancel(state, children, status, reason, from) do
    started_at = state.cancel_started_at || System.monotonic_time()

    Telemetry.event([:subagent, :cancel, :start], %{children: length(children)}, %{
      group_id: state.id,
      root_session_id: state.root_id,
      stop_reason: status
    })

    state =
      Enum.reduce(children, state, fn child, state ->
        state |> remember_cancel(child, status, reason) |> ask_to_stop(child, status, reason)
      end)

    pending =
      children
      |> Enum.map(& &1.id)
      |> Enum.reject(&(state.children[&1].status in @terminal))
      |> MapSet.new()

    state = %{
      state
      | cancel_started_at: started_at,
        cancel_pending: MapSet.union(state.cancel_pending, pending),
        cancel_waiters: if(from, do: [from | state.cancel_waiters], else: state.cancel_waiters)
    }

    state = %{state | cancel_timer_ref: state.cancel_timer_ref || grace_timer(state)}

    # A queued child never started, so it is already terminal and there is
    # nothing left to wait for.
    maybe_finish(state)
  end

  defp remember_cancel(state, child, status, reason) do
    state
    |> put_in([:children, child.id, :cancel_reason], reason)
    |> put_in([:children, child.id, :cancel_status], status)
  end

  defp ask_to_stop(state, %{status: :queued} = child, status, _reason) do
    child = state.children[child.id]
    complete_child(state, child, status, [])
  end

  defp ask_to_stop(state, %{session: session} = child, status, reason) when is_pid(session) do
    state =
      publish(state, :child_cancelling, %{
        "child_id" => child.id,
        "status" => Atom.to_string(status),
        "reason" => describe_reason(reason)
      })

    group = self()

    Task.Supervisor.start_child(Sup.task_supervisor(state.supervisor), fn ->
      # The child's own status is the cancellation reason the session records; the
      # caller's reason travels beside it in the envelope, because a session's stop
      # reasons are a closed vocabulary and a host's are not. A stall is the exception:
      # the child's transcript should say it stalled, not that it failed.
      Session.cancel(session, session_reason(status, reason))
      send(group, {:child_cancel_requested, child.id})
    end)

    state
  end

  defp ask_to_stop(state, child, status, _reason),
    do: complete_child(state, state.children[child.id], status, [])

  defp grace_timer(state),
    do: Clock.send_after(state.clock, self(), :cancel_grace, state.cancel_grace)

  # A child whose session replied to `cancel/2` has checkpointed its work, so its
  # snapshot is worth reading now rather than at the grace deadline. Bounded,
  # because this also runs for a child that missed its grace and may never answer
  # again — an unbounded read there turns one wedged child into a wedged fan-out.
  # What is lost is the in-memory usage, and a reservation charged in full is the
  # right answer for a child nobody could measure.
  @force_snapshot_ms 250

  defp force_complete(state, child) do
    complete_child(state, child, child.cancel_status || :cancelled, entries(child))
  end

  defp entries(%{session: session}) when is_pid(session) do
    if Process.alive?(session),
      do: Session.snapshot(session, @force_snapshot_ms).entries,
      else: []
  catch
    :exit, _reason -> []
  end

  defp entries(_child), do: []

  defp finish_cancel(state) do
    terminated = state.cancel_terminated

    if state.cancel_started_at do
      Telemetry.stop(
        [:subagent, :cancel],
        state.cancel_started_at,
        %{group_id: state.id, root_session_id: state.root_id, outcome: outcome(terminated)},
        %{terminated: terminated}
      )
    end

    Enum.each(state.cancel_waiters, &GenServer.reply(&1, :ok))

    %{state | cancel_waiters: [], cancel_started_at: nil, cancel_terminated: 0}
  end

  defp outcome(0), do: :settled
  defp outcome(_terminated), do: :terminated

  defp terminate_session(state, session) do
    DynamicSupervisor.terminate_child(Sup.session_supervisor(state.supervisor), session)
  catch
    :exit, _reason -> :ok
  end

  defp describe_reason(reason) when is_binary(reason), do: reason
  defp describe_reason({:stalled, note}), do: "stalled: #{note}"
  defp describe_reason(reason), do: inspect(reason)

  defp session_reason(_status, {:stalled, _note}), do: :stalled
  defp session_reason(status, _reason), do: status

  # -- progress checks --------------------------------------------------------

  # Arms the child's next clock: the next check, or the hard deadline when
  # checks are off or it is nearer. One timer, so a child never has two
  # clocks racing.
  defp arm_clock(child, state) do
    remaining = max(child.deadline_at - Clock.now_ms(state.clock), 0)

    delay =
      case state.progress.assess do
        false -> remaining
        _assessing -> min(child.request.definition.progress_interval, remaining)
      end

    %{child | timer: Clock.send_after(state.clock, self(), {:child_clock, child.id}, delay)}
  end

  defp begin_check(state, child) do
    ref = make_ref()
    group = self()
    definition = child.request.definition
    progress = state.progress

    judge = [
      assess: progress.assess,
      provider: progress.provider || provider(state, child.request),
      model: progress.model || definition.model,
      timeout_ms: progress.timeout_ms,
      clock: state.clock
    ]

    evidence_opts = [
      since_seq: child.checked_seq,
      elapsed_ms: Clock.now_ms(state.clock) - child.started_at,
      interval_ms: definition.progress_interval,
      checks: child.checks,
      subject: %{
        kind: :subagent,
        id: child.id,
        definition_id: definition.id,
        objective: child.request.task.objective
      }
    ]

    session = child.session

    {:ok, task} =
      Task.Supervisor.start_child(Sup.task_supervisor(state.supervisor), fn ->
        {verdict, last_seq} = check(session, evidence_opts, judge)
        send(group, {:child_verdict, child.id, ref, verdict, last_seq})
      end)

    # Monitored, so a check that crashes still answers — see the `:DOWN`
    # clause. Without it the child kept running with no clock armed at all.
    monitor = Process.monitor(task)

    put_in(state.children[child.id], %{child | timer: nil, check_ref: ref, check_monitor: monitor})
  end

  # Runs in the check's own task. A child that will not answer a snapshot is
  # not judged on the strength of that silence: its own clocks will speak,
  # and a verdict built on nothing would be a guess dressed as a finding.
  defp check(session, evidence_opts, judge) do
    entries = Session.snapshot(session, @check_snapshot_ms).entries
    evidence = Progress.evidence(entries, evidence_opts)
    {Progress.assess(evidence, judge), evidence.last_seq}
  catch
    :exit, reason ->
      verdict = %Progress.Verdict{
        outcome: :progressing,
        by: :error,
        note: "the child did not answer a snapshot (#{inspect(reason)}); the check fell open"
      }

      {verdict, Keyword.get(evidence_opts, :since_seq)}
  end

  defp conclude_check(state, child, %Progress.Verdict{} = verdict, last_seq) do
    elapsed = Clock.now_ms(state.clock) - child.started_at
    if child.check_monitor, do: Process.demonitor(child.check_monitor, [:flush])

    child = %{
      child
      | check_ref: nil,
        check_monitor: nil,
        checks: child.checks + 1,
        checked_seq: last_seq,
        assessment_usage: List.wrap(verdict.usage) ++ child.assessment_usage
    }

    Telemetry.event([:subagent, :progress], %{elapsed_ms: elapsed, checks: child.checks}, %{
      group_id: state.id,
      child_id: child.id,
      root_session_id: state.root_id,
      definition_id: child.request.definition.id,
      outcome: verdict.outcome,
      assessed_by: verdict.by
    })

    state =
      publish(state, :child_assessed, %{
        "child_id" => child.id,
        "outcome" => Atom.to_string(verdict.outcome),
        "by" => Atom.to_string(verdict.by),
        "note" => verdict.note,
        "elapsed_ms" => elapsed,
        "checks" => child.checks
      })

    case verdict.outcome do
      :progressing ->
        put_in(state.children[child.id], arm_clock(child, state))

      :stalled ->
        state = put_in(state.children[child.id], child)
        begin_cancel(state, [child], :failed, {:stalled, verdict.note}, nil)
    end
  end

  defp finish_from_session(state, child_id, reason) do
    case state.children[child_id] do
      %{status: status} when status in @terminal ->
        state

      %{session: session} = child ->
        entries = Session.snapshot(session).entries
        # A session that was asked to stop reports `:cancelled` whatever the
        # reason was, so the status the group asked for wins over the one the
        # session reports: a child killed by its own deadline is a timeout.
        complete_child(state, child, child.cancel_status || terminal_status(reason), entries)

      nil ->
        state
    end
  end

  defp fail_child(state, child_id, reason) do
    case state.children[child_id] do
      %{status: status} when status in @terminal ->
        state

      %{session: session} = child when is_pid(session) ->
        entries = Session.snapshot(session).entries
        complete_child(state, child, :failed, entries, inspect(reason))

      child when is_map(child) ->
        complete_child(state, child, :failed, [], inspect(reason))

      nil ->
        state
    end
  end

  defp complete_child(state, child, status, entries, reason \\ nil) do
    OpenTelemetry.drop_prompt_parent(child.id)
    cancel_timer(state, child.timer)
    if child.monitor, do: Process.demonitor(child.monitor, [:flush])
    if child.check_monitor, do: Process.demonitor(child.check_monitor, [:flush])
    # The checks' own requests are part of what this child cost, so they are
    # billed to it: a fan-out whose assessments were free would understate
    # the tree's spend by exactly the overhead this feature adds.
    usage = Usage.sum([Result.usage(entries) | child.assessment_usage])
    result = Result.from_session(child.id, child.request.definition, status, entries, usage)

    result =
      if reason, do: %{result | uncertainties: [reason | result.uncertainties]}, else: result

    # The caller's own words for why this child was stopped, kept in the
    # envelope the parent reads. Dropping it at the boundary left every
    # cancellation looking identical, whatever provoked it.
    result =
      case child.cancel_reason do
        nil ->
          result

        cancel_reason ->
          %{
            result
            | uncertainties:
                result.uncertainties ++ ["cancelled: #{describe_reason(cancel_reason)}"]
          }
      end

    append_child_result(child, result)

    parent_payload = Result.to_map(result) |> Map.put("group_id", state.id)
    append_parent(state, :subagent_result, parent_payload)
    actual_cost = result.usage["cost_usd"]
    Admission.release(Sup.subagent_admission(state.supervisor), child.id, actual_cost)

    child = %{child | status: result.status, result: result, timer: nil, monitor: nil}

    state =
      state
      |> put_in([:children, child.id], child)
      |> Map.update!(:cancel_pending, &MapSet.delete(&1, child.id))

    state = reply_child_waiters(state, child.id, result)

    state =
      publish(state, :child_finished, %{
        "child_id" => child.id,
        "status" => Atom.to_string(result.status)
      })

    state |> pressure() |> maybe_finish()
  end

  # The child's own copy of its envelope is a convenience; the parent's is the
  # authority a replay reads. So a child that cannot take it — dead, or wedged
  # and about to be — costs nothing, rather than taking the coordinator down
  # with it.
  defp append_child_result(%{session: session}, result) when is_pid(session) do
    if Process.alive?(session),
      do: Session.append_subagent_entry(session, :subagent_result, Result.to_map(result))
  catch
    :exit, _reason -> :ok
  end

  defp append_child_result(_child, _result), do: :ok

  defp bind_child_parent_contexts(child_ids, contexts) do
    Enum.each(child_ids, &OpenTelemetry.bind_prompt_parent(&1, contexts))
  end

  defp maybe_finish(state) do
    if Enum.all?(state.children, fn {_id, child} -> child.status in @terminal end) do
      results = Enum.map(state.order, &state.children[&1].result)
      result = GroupResult.new(state.id, state.parent_id, results)
      append_parent(state, :subagent_group_result, GroupResult.to_map(result))
      cancel_timer(state, state.group_timer)

      if state.parent && Process.alive?(state.parent),
        do: Session.unregister_subagent_group(state.parent, state.id)

      Enum.each(state.waiters, &GenServer.reply(&1, {:ok, result}))

      state
      |> Map.merge(%{status: result.status, result: result, waiters: [], group_timer: nil})
      |> publish(:group_finished, %{"status" => Atom.to_string(result.status)})
      |> settled()
    else
      settled(state)
    end
  end

  # A cancellation is over as soon as every child it touched is terminal,
  # whether they stopped themselves or the grace deadline stopped them. The
  # caller is answered then rather than at the end of the grace interval,
  # so `cancel/3` costs the grace only when a child actually hangs.
  defp settled(%{cancel_started_at: nil} = state), do: state

  defp settled(state) do
    if Enum.empty?(state.cancel_pending) do
      cancel_timer(state, state.cancel_timer_ref)
      finish_cancel(%{state | cancel_timer_ref: nil})
    else
      state
    end
  end

  defp maybe_settled(state), do: settled(state)

  defp reply_child_waiters(state, child_id, result) do
    {waiters, child_waiters} = Map.pop(state.child_waiters, child_id, [])
    Enum.each(waiters, &GenServer.reply(&1, {:ok, result}))
    %{state | child_waiters: child_waiters}
  end

  defp snapshot(state, child) do
    session =
      if child.session && Process.alive?(child.session), do: Session.snapshot(child.session)

    %Snapshot{
      id: child.id,
      group_id: state.id,
      parent_id: state.parent_id,
      status: child.status,
      definition_id: child.request.definition.id,
      transcript_id: child.id,
      input: child_input(state, child, session),
      session: session,
      result: child.result
    }
  end

  defp persist_spawn_intents(state) do
    Enum.reduce(state.order, state, fn child_id, state ->
      child = state.children[child_id]
      request = child.request
      definition = request.definition
      {_definition_digest, _task_digest, snapshot_digest} = SubagentRequest.duplicate_key(request)

      payload = %{
        "child_id" => child_id,
        "group_id" => state.id,
        "parent_session_id" => state.parent_id,
        "root_session_id" => state.root_id,
        "depth" => 1,
        "definition_id" => definition.id,
        "definition_digest" => Definition.digest(definition),
        "brief_digest" => SubagentTask.digest(request.task),
        "task" => SubagentTask.to_map(request.task),
        "snapshot_digest" => snapshot_digest,
        "authority" => %{
          "read_only" => true,
          "tools" => Enum.map(definition.tools, &Tool.name/1)
        },
        "child_timeout_ms" => definition.timeout,
        "group_timeout_ms" => state.deadline.budget_ms,
        # The one clock that actually binds this child, and who imposed it.
        # Recorded so a replay can tell a child that ran out of its own time
        # from one cut short by the group's or the host's.
        "effective_deadline_ms" => min(definition.timeout, state.deadline.budget_ms),
        "deadline_source" => state.deadline.source,
        # The soft clock beside the hard one: how often this child is asked
        # whether it is still progressing, and who answers.
        "progress_interval_ms" => definition.progress_interval,
        "assess" => assess_label(state.progress),
        "reserved_cost_usd" => definition.max_cost_usd
      }

      append_parent(state, :subagent_spawn, payload)

      # The brief and the kind travel with the announcement rather than only into the
      # transcript: a front end drawing one row per child has to say what that child
      # was sent to do, and the alternative is reading the parent's transcript back for
      # something that was in hand here. The same two facts are on the `:subagent_spawn`
      # entry above, so a resumed transcript draws the same row.
      publish(state, :child_queued, %{
        "child_id" => child_id,
        "definition_id" => definition.id,
        "objective" => request.task.objective
      })
    end)
  end

  defp persist_steer(state, child_id, instruction) do
    payload = %{
      "child_id" => child_id,
      "group_id" => state.id,
      "instruction" => instruction,
      "source" => "authorized_controller"
    }

    append_parent(state, :subagent_steer, payload)
  end

  defp append_parent(%{parent: parent}, type, payload) when is_pid(parent) do
    {:ok, _entry} = Session.append_subagent_entry(parent, type, payload)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  defp append_parent(_state, _type, _payload), do: {:error, :parent_down}

  defp publish(state, kind, payload) do
    if state.parent && Process.alive?(state.parent) do
      Session.publish_subagent_event(
        state.parent,
        {:subagent, [state.root_id], {kind, Map.put(payload, "group_id", state.id)}}
      )
    end

    state
  end

  defp publish_child_event(state, child_id, event) do
    if state.parent && Process.alive?(state.parent) do
      Session.publish_subagent_event(state.parent, {:subagent, [state.root_id, child_id], event})
    end

    state
  end

  defp system_prompt(state, request, child_id) do
    definition = request.definition

    [
      "You are a depth-one delegated investigator. The parent owns the decision and every write.",
      "Use only the supplied read-only tools. Do not attempt to delegate, modify files, run shell commands, or mutate an external system.",
      "Your context is fresh by design. Treat the explicit brief, policy, snapshot, and references as complete; report uncertainty instead of inventing missing parent context.",
      definition.system_prompt,
      "Definition id: #{definition.id}",
      "Definition digest: #{Definition.digest(definition)}",
      "Root session id: #{state.root_id}",
      "Parent session id: #{state.parent_id}",
      "Group id: #{state.id}",
      "Child id: #{child_id}",
      "Inherited policy: #{JSON.encode!(state.policy)}",
      "Return exactly one JSON object matching this schema; do not wrap it in Markdown:\n#{JSON.encode!(definition.result_schema.schema())}"
    ]
    |> Enum.join("\n\n")
  end

  defp child_input(state, child, session) do
    request = child.request

    input = %{
      "definition_id" => request.definition.id,
      "definition_digest" => Definition.digest(request.definition),
      "model" => request.definition.model,
      "tools" => Enum.map(request.definition.tools, &Tool.name/1),
      "task" => SubagentTask.to_map(request.task),
      "system_prompt" => system_prompt(state, request, child.id),
      "user_prompt" => SubagentTask.prompt(request.task)
    }

    case session && Enum.find(session.entries, &(&1.type == :request)) do
      nil -> input
      entry -> Map.put(input, "request", entry.payload)
    end
  end

  defp provider(%{provider_factory: fun}, request) when is_function(fun, 1), do: fun.(request)

  defp provider(%{provider_factory: fun}, request) when is_function(fun, 2),
    do: fun.(request.definition, request.task)

  defp provider(state, request) do
    Map.get(state.providers, request.definition.id, state.context.provider)
  end

  defp child_options(fun, request) when is_function(fun, 1), do: fun.(request)
  defp child_options(options, _request) when is_list(options), do: options

  # Provider-native structured output is frequently a forced synthetic tool call.
  # Offering it beside investigative tools stops the child ever choosing `read`,
  # and Lemieux cannot execute the provider's private tool. Tool-using children
  # follow the schema in their system prompt and are validated after the final
  # assistant response.
  defp output_schema(%Definition{tools: []} = definition), do: definition.result_schema.schema()
  defp output_schema(%Definition{}), do: nil

  defp terminal_status({:budget, _payload}), do: :budget_exhausted
  defp terminal_status(:cancelled), do: :cancelled

  defp terminal_status(reason) when reason in [:error, :hook_failed, :max_turns, :no_progress],
    do: :failed

  defp terminal_status(_stop), do: :ok

  defp build_group_ref(state) do
    %Lemieux.Subagent.Group.Ref{
      id: state.id,
      parent_id: state.parent_id,
      supervisor: state.supervisor,
      control_token: state.token
    }
  end

  defp child_ref(state, child_id) do
    %Lemieux.Subagent.Ref{
      id: child_id,
      group_id: state.id,
      parent_id: state.parent_id,
      supervisor: state.supervisor,
      control_token: state.token
    }
  end

  # Whether a control call is allowed: the capability first, the host second.
  #
  # The unforgeable token remains the boundary — a public child id is not
  # authorization. What the optional `:authorize` callback adds is the question the
  # token cannot answer: *this* holder, doing *this* to *this* child, right now. An
  # embedding contract where inspecting a child's transcript is a different
  # permission from cancelling it cannot express that through one capability, and
  # the alternative is a tenant database in the core.
  #
  # The callback receives the action and a bounded context of ids, never the brief,
  # the prompt or the transcript: a policy that needs the content belongs to the
  # host's own tool layer, before the delegation starts. Raising, exiting, or
  # answering anything but `:ok` denies, because a policy hook that fails open is
  # not a policy.
  defp allowed(state, token, action, child_id) do
    cond do
      token != state.token -> {:error, :unauthorized}
      is_nil(state.authorize) -> :ok
      true -> host_decision(state, action, child_id)
    end
  end

  defp host_decision(state, action, child_id) do
    context = %{
      group_id: state.id,
      parent_session_id: state.parent_id,
      root_session_id: state.root_id,
      child_id: child_id,
      definition_id: definition_id(state, child_id)
    }

    case state.authorize.(action, context) do
      :ok -> :ok
      {:error, reason} -> {:error, {:denied, reason}}
      other -> {:error, {:denied, other}}
    end
  rescue
    error -> {:error, {:denied, Exception.message(error)}}
  catch
    _kind, _reason -> {:error, {:denied, :authorize_failed}}
  end

  defp definition_id(_state, nil), do: nil

  defp definition_id(state, child_id) do
    case state.children[child_id] do
      nil -> nil
      child -> child.request.definition.id
    end
  end

  # The coordinator's own pressure, which existing usage summaries cannot
  # report: a fan-out that outruns its group shows up here as a growing
  # mailbox long before it shows up as a lost child. Measured when a child
  # starts and when one finishes, which is when the shape changes.
  defp pressure(state) do
    info = Process.info(self(), [:message_queue_len, :memory])

    Telemetry.event(
      [:subagent, :group, :pressure],
      %{
        message_queue_len: info[:message_queue_len] || 0,
        memory_bytes: info[:memory] || 0,
        running: Enum.count(state.children, fn {_id, child} -> child.status == :running end),
        queued: Enum.count(state.children, fn {_id, child} -> child.status == :queued end)
      },
      %{group_id: state.id, root_session_id: state.root_id}
    )

    state
  end

  defp cancel_timer(_state, nil), do: :ok
  defp cancel_timer(state, timer), do: Clock.cancel(state.clock, timer)
end
