defmodule Lemieux.Learning.Controller do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Bounded refinement inside the host's existing job allowance.

  The host supplies a `Lemieux.JobBudget` and explicitly authorizes token/time
  ceilings and a finite learning allocation. Every role, including the ordinary
  task, uses this controller before dispatch. It reserves requests and dollars
  in that same ledger; learning has no independent spend allowance. Default
  learning allocation is zero. Merely loading this module starts nothing.

  Estimates are admission bounds, as in `Lemieux.JobBudget`, not a guarantee
  against a provider misreporting or exceeding them. Actual overruns and missing
  usage are retained and close further admission. Quota mode may leave dollars
  unknown, but never substitutes zero or relaxes the outer dollar ceiling.
  Hosts must route all token-consuming work through this controller from the
  beginning of the job. Previously untracked parent usage stays unknown.

  `run/5` guards child lifetime and time; `reserve/4` is for a host that enforces
  the returned deadline itself. Failed, retried and cancelled dispatches consume
  their requests. Reconciliation is idempotent. Current host authority always
  comes from initialization options, never a checkpoint. A restored active
  attempt becomes interrupted/unknown and is never reissued. For durable
  recovery, both the job ledger and controller require synchronous host-owned
  persistence; callbacks must write before returning and must not call the
  session invoking them. Without persistence, snapshots support explicit
  host-managed recovery only.

  Trigger inspection and baseline selection make no provider call. An admitted
  experiment keeps its original plan; later budget exhaustion is an incomplete
  experiment, never permission to reduce its preregistered sample counts.
  """
  use GenServer, restart: :temporary
  alias Lemieux.Contract
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller.Accounting
  alias Lemieux.Learning.Controller.Checkpoint
  alias Lemieux.Learning.Controller.Provider, as: ControlledProvider
  alias Lemieux.Providers.Scripted
  alias Lemieux.RepositoryContext.Worker

  @roles ~w(task proposer critic probe composition reflection confirmation)
  @signals ~w(verification_failure repeated_tool_failure correction verification_recovery tool_recovery bounded_research_review)

  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Reserves before one physical attempt; retries require distinct identities."
  @spec reserve(server :: GenServer.server(), id :: String.t(), role :: atom(), estimate :: map()) ::
          {:ok, map()} | {:skip, map()}
  def reserve(server, id, role, estimate),
    do:
      GenServer.call(
        server,
        {:reserve, id, to_string(role),
         estimate
         |> Contract.json()
         |> Map.take(~w(tokens time_ms cost_usd requests))
         |> Map.put_new("requests", 1)}
      )

  @doc "Settles once; missing facts stay unknown. Information is an optional evidence digest."
  @spec reconcile(
          server :: GenServer.server(),
          id :: String.t(),
          usage :: map() | nil,
          opts :: keyword()
        ) :: :ok
  def reconcile(server, id, usage, opts \\ []),
    do:
      GenServer.call(
        server,
        {:reconcile, id, usage_facts(usage), Keyword.get(opts, :information, :unobserved)}
      )

  defp usage_facts(usage) when is_map(usage) do
    facts = Contract.json(usage)

    %{
      "tokens" => known_count(facts["tokens"]),
      "time_ms" => known_count(facts["time_ms"]),
      "cost_usd" => known_dollars(facts["cost_usd"])
    }
  end

  defp usage_facts(_missing), do: nil
  defp known_count(value) when is_integer(value) and value >= 0, do: value
  defp known_count(_unknown), do: nil
  defp known_dollars(value) when is_number(value) and value >= 0, do: value
  defp known_dollars(_unknown), do: nil

  @doc "Returns bounded accounting/decisions without resolving or invoking a provider."
  @spec snapshot(server :: GenServer.server()) :: map()
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Inspects a deterministic signal; readiness is not dispatch authorization."
  @spec consider(server :: GenServer.server(), signal :: map()) :: {:noop | :ready, map()}
  def consider(server, signal), do: GenServer.call(server, {:consider, signal})

  @doc "Keeps the baseline unless a supported candidate's lower bound exceeds its upper bound."
  @spec select(server :: GenServer.server(), baseline :: map(), candidates :: [map()]) ::
          {:ok, map(), map()}
  def select(server, baseline, candidates),
    do: GenServer.call(server, {:select, baseline, candidates})

  @doc "Runs guarded host work returning `{result, usage}` within one reserved attempt."
  @spec run(
          server :: GenServer.server(),
          id :: String.t(),
          role :: atom(),
          estimate :: map(),
          work :: (-> {term(), map() | nil})
        ) :: {:ok, term(), map()} | {:skip, map()}
  def run(server, id, role, estimate, work) do
    case reserve(server, id, role, estimate) do
      {:ok, permit} -> execute(server, id, work, permit)
      {:skip, _receipt} = skipped -> skipped
    end
  end

  defp execute(server, id, work, permit) do
    started = System.monotonic_time(:millisecond)
    timeout = permit["timeout_ms"] - (started - permit["issued_monotonic_ms"])

    {result, usage} =
      case guarded_work(work, timeout) do
        {:ok, {result, usage}} when is_map(usage) or is_nil(usage) -> {result, usage}
        _interrupted -> {{:error, :controller_work_incomplete}, nil}
      end

    usage =
      if is_map(usage),
        do:
          usage
          |> Contract.json()
          |> Map.put("time_ms", System.monotonic_time(:millisecond) - started),
        else: nil

    :ok = reconcile(server, id, usage)
    {:ok, result, snapshot(server)["records"][key(id)]}
  end

  defp guarded_work(work, timeout) when timeout > 0, do: Worker.run(work, timeout)
  defp guarded_work(_work, _expired), do: {:error, :deadline_exhausted}

  @doc """
  Checks a complete frozen experiment without changing its plan or dispatching work.

  Refusals preserve the underlying admission reason and stop/skip decision.
  Unknown usage needs reconciliation, not a larger allowance. An outer job
  ledger refusal also retains its data-only `cause` (kind, spent, estimate, cap).
  """
  @spec admit(server :: GenServer.server(), plan :: map(), required :: map()) ::
          {:ok, map()} | {:skip, map()}
  def admit(server, plan, required),
    do: GenServer.call(server, {:admit, Contract.json(plan), Contract.json(required)})

  @doc "Reserves an entire frozen experiment before mounting its bounded child controller."
  @spec experiment(
          server :: GenServer.server(),
          id :: String.t(),
          plan :: map(),
          required :: map(),
          work :: (GenServer.server() -> term())
        ) :: {:ok, term(), map()} | {:skip, map()}
  def experiment(server, id, plan, required, work) do
    with {:ok, _admission} <- admit(server, plan, required) do
      mode = snapshot(server)["limits"]["cost_mode"]

      run(server, id, :probe, required, fn ->
        allocation(id, Contract.json(required), mode, work)
      end)
    end
  end

  defp allocation(id, required, mode, work) do
    {:ok, budget} =
      JobBudget.start_link(max_requests: required["requests"], max_cost_usd: required["cost_usd"])

    {:ok, controller} =
      start_link(
        job_id: "allocation_" <> Contract.sha256(id),
        job_budget: budget,
        max_tokens: required["tokens"],
        max_time_ms: required["time_ms"],
        cost_mode: if(mode == "quota", do: :quota, else: :metered),
        max_records: 4096,
        learning: [
          max_requests: required["requests"],
          max_tokens: required["tokens"],
          max_time_ms: required["time_ms"],
          max_cost_usd: required["cost_usd"]
        ]
      )

    try do
      result = work.(controller)
      snapshot = snapshot(controller)

      facts =
        if snapshot["job_budget"]["active"] == 0,
          do: %{
            tokens: snapshot["accounting"]["tokens"],
            cost_usd: snapshot["job_budget"]["spent_usd"]
          },
          else: nil

      {result, facts}
    after
      GenServer.stop(controller)
      GenServer.stop(budget)
    end
  end

  @doc "Wraps the existing provider seam; it implements no provider API or credentials."
  @spec provider(
          server :: GenServer.server(),
          role :: atom(),
          provider :: Lemieux.Provider.t() | nil,
          opts :: keyword()
        ) :: Lemieux.Provider.t()
  def provider(server, role, provider, opts \\ []),
    do: ControlledProvider.new(server, role, provider, opts)

  @doc false
  @spec scripted?(provider :: Lemieux.Provider.t()) :: boolean()
  def scripted?({ControlledProvider, %{provider: provider}}), do: scripted?(provider)
  def scripted?({Scripted, _state}), do: true
  def scripted?(_provider), do: false

  @doc "Records a provider-free skip, such as absent provider or unsupported hypothesis."
  @spec skip(server :: GenServer.server(), role :: atom(), reason :: String.t()) :: map()
  def skip(server, role, reason), do: GenServer.call(server, {:skip, to_string(role), reason})

  @impl true
  def init(opts) do
    budget = Keyword.fetch!(opts, :job_budget)
    outer = JobBudget.snapshot(budget)
    now = System.system_time(:millisecond)

    learning =
      opts
      |> Keyword.get(:learning, max_requests: 0, max_tokens: 0, max_time_ms: 0, max_cost_usd: 0)
      |> Map.new()
      |> Contract.json()

    state = %{
      budget: budget,
      job_id: Keyword.fetch!(opts, :job_id),
      max_tokens: Keyword.fetch!(opts, :max_tokens),
      deadline: now + Keyword.fetch!(opts, :max_time_ms),
      mono_deadline: System.monotonic_time(:millisecond) + Keyword.fetch!(opts, :max_time_ms),
      learning: learning,
      cost_mode: Keyword.get(opts, :cost_mode, :metered),
      records: %{},
      seen: [],
      refs: %{},
      leases: %{},
      stop: nil,
      learning_stop: nil,
      information: nil,
      stagnant: 0,
      max_stagnant: Keyword.get(opts, :max_uninformative, 2),
      max_records: Keyword.get(opts, :max_records, 512),
      initial_requests: outer.requests,
      initial_tokens: if(outer.requests == 0, do: 0),
      persist: opts[:persist],
      persist_failed: false
    }

    with :ok <- configuration(state, outer, opts[:max_time_ms]),
         {:ok, state} <- restore(state, opts[:recorded]) do
      {:ok, persist(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp configuration(state, outer, max_time) do
    valid =
      valid_job?(state.job_id) and runtime_configuration?(state, max_time) and
        learning_configuration?(state.learning) and within_outer?(state, outer, max_time)

    if valid, do: :ok, else: {:error, :invalid_controller_allocation}
  end

  defp valid_job?(id), do: is_binary(id) and byte_size(id) in 1..128
  defp ceiling?(value), do: is_integer(value) and value >= 0

  defp runtime_configuration?(state, max_time) do
    Enum.all?([state.max_tokens, max_time], &ceiling?/1) and state.cost_mode in [:metered, :quota] and
      state.max_records in 1..4096 and state.max_stagnant in 1..32
  end

  defp learning_configuration?(learning),
    do: Enum.all?(~w(max_requests max_tokens max_time_ms), &ceiling?(learning[&1]))

  defp within_outer?(state, outer, max_time) do
    bounds = [
      {state.learning["max_tokens"], state.max_tokens},
      {state.learning["max_time_ms"], max_time},
      {state.learning["max_requests"], outer.max_requests}
    ]

    Enum.all?(bounds, &within?/1) and
      valid_dollars?(state.learning["max_cost_usd"], outer.max_cost_usd)
  end

  defp within?({_value, nil}), do: true
  defp within?({value, maximum}), do: value <= maximum

  defp valid_dollars?(nil, nil), do: true
  defp valid_dollars?(value, nil), do: is_number(value) and value >= 0
  defp valid_dollars?(value, cap), do: is_number(value) and value >= 0 and value <= cap

  defp restore(state, nil), do: {:ok, state}

  defp restore(state, recorded) do
    with :ok <- Checkpoint.verify(recorded, state.job_id, state.max_records),
         1 <- recorded["schema_version"],
         true <- recorded["job_id"] == state.job_id,
         records when is_map(records) <- recorded["records"],
         true <- map_size(records) <= state.max_records + 1 do
      records = Map.new(records, fn {id, record} -> {id, interrupted(record)} end)

      {:ok,
       %{
         state
         | records: records,
           seen: recorded["seen"],
           deadline: min(state.deadline, recorded["deadline_ms"]),
           mono_deadline:
             min(
               state.mono_deadline,
               System.monotonic_time(:millisecond) +
                 max(0, recorded["deadline_ms"] - System.system_time(:millisecond))
             ),
           initial_tokens: recorded["initial_tokens"],
           initial_requests: recorded["initial_requests"],
           stop: recorded["stop"],
           stagnant: recorded["stagnant"],
           information: recorded["information"],
           learning_stop: recorded["learning_stop"]
       }}
    else
      _invalid -> {:error, :invalid_controller_checkpoint}
    end
  end

  defp interrupted(%{"status" => "reserved"} = record),
    do: Map.merge(record, %{"status" => "interrupted", "usage" => nil})

  defp interrupted(record), do: record

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = state |> reconcile_dead() |> persist()
    {:reply, view(state), state}
  end

  def handle_call({:reserve, id, role, estimate}, {owner, _tag}, state) do
    state = reconcile_dead(state)

    case admission(state, id, role, estimate) do
      :ok ->
        reserve_attempt(state, id, role, estimate, owner)

      {decision, reason} ->
        {receipt, state} = decision(state, role, Atom.to_string(decision), reason)
        {:reply, {:skip, receipt}, persist(state)}
    end
  end

  def handle_call({:reconcile, id, usage, information}, _from, state) do
    {:reply, :ok, state |> settle(id, usage, information) |> persist()}
  end

  def handle_call({:skip, role, reason}, _from, state) do
    {receipt, state} = decision(state, role, "skip", bounded(reason))
    {:reply, receipt, persist(state)}
  end

  def handle_call({:consider, signal}, _from, state) do
    signature = Contract.digest(Map.take(signal, ~w(id kind hypothesis_supported)))
    {outcome, reason} = trigger(signal, signature in state.seen)

    {receipt, state} =
      decision(state, "reflection", if(outcome == :ready, do: "consider", else: "skip"), reason)

    state = %{state | seen: Enum.take(Enum.uniq([signature | state.seen]), state.max_records)}
    outcome = if receipt["decision"] == "stop", do: :noop, else: outcome
    {:reply, {outcome, receipt}, persist(state)}
  end

  def handle_call({:admit, plan, required}, _from, state) do
    allocation = Map.take(required, ~w(tokens time_ms cost_usd requests))

    result =
      with :ok <- frozen_allocation(plan, allocation),
           :ok <- admission(state, "experiment-admission", "probe", allocation),
           true <-
             System.monotonic_time(:millisecond) + allocation["time_ms"] <= state.mono_deadline,
           do: JobBudget.check(state.budget, allocation["cost_usd"], allocation["requests"])

    {action, reason, cause} = admission_outcome(result)
    {receipt, state} = decision(state, "probe", action, reason)

    receipt = Map.put(receipt, "plan_sha256", plan["sha256"])
    receipt = if cause, do: Map.put(receipt, "cause", cause), else: receipt
    state = %{state | records: Map.put(state.records, receipt["id"], receipt)}
    {:reply, {if(result == :ok, do: :ok, else: :skip), receipt}, persist(state)}
  end

  def handle_call({:select, baseline, candidates}, _from, state) do
    winner =
      candidates
      |> Enum.take(128)
      |> Enum.filter(&better?(&1, baseline))
      |> Enum.sort_by(&{-&1.score, &1.id})
      |> List.first()

    selected = winner || baseline

    {receipt, state} =
      decision(
        state,
        "composition",
        "select",
        if(winner, do: "supported_improvement", else: "baseline_retained")
      )

    {:reply, {:ok, selected, receipt}, persist(state)}
  end

  # Keep refusals distinguishable: collapsing unknown usage into affordability
  # made hosts recommend more quota when the blocked work needed reconciliation.
  defp admission_outcome(:ok), do: {"admit", "frozen_experiment_admitted", nil}

  defp admission_outcome({action, reason}) when action in [:skip, :stop],
    do: {Atom.to_string(action), reason, nil}

  defp admission_outcome({:error, reason}) when is_atom(reason),
    do: {"skip", Atom.to_string(reason), nil}

  defp admission_outcome({:error, %{spent: nil} = cause}),
    do: {"stop", "usage_unknown", Contract.json(cause)}

  defp admission_outcome({:error, %{kind: :cost, estimate: nil} = cause}),
    do: {"skip", "price_unknown", Contract.json(cause)}

  defp admission_outcome({:error, cause}) when is_map(cause),
    do: {"skip", "outer_allowance_exhausted", Contract.json(cause)}

  defp admission_outcome(false), do: {"skip", "experiment_deadline_exceeded", nil}

  defp frozen_allocation(%{"sha256" => sha, "budget" => budget}, required)
       when is_binary(sha) and byte_size(sha) == 64 and is_map(budget) do
    if frozen_counts?(required, budget) and frozen_dollars?(required["cost_usd"], budget) and
         valid_requests?(required["requests"]),
       do: :ok,
       else: {:error, :incomplete_experiment_allocation}
  end

  defp frozen_allocation(_plan, _required), do: {:error, :invalid_frozen_experiment}

  defp frozen_counts?(required, budget) do
    Enum.all?(
      [
        {"tokens", "maximum_tokens"},
        {"time_ms", "maximum_time_ms"},
        {"requests", "maximum_requests"}
      ],
      fn {key, maximum} ->
        is_integer(required[key]) and required[key] > 0 and
          required[key] >= Map.get(budget, maximum, 0)
      end
    )
  end

  defp frozen_dollars?(nil, budget),
    do: budget["unknown_cost"] == "allow" or budget["usage_mode"] == "quota"

  defp frozen_dollars?(dollars, budget),
    do: is_number(dollars) and dollars >= Map.get(budget, "maximum_cost_usd", 0)

  defp trigger(_signal, true), do: {:noop, "duplicate_signal"}
  defp trigger(%{"kind" => "healthy"}, false), do: {:noop, "healthy_task"}

  defp trigger(%{"kind" => kind, "hypothesis_supported" => true}, false) when kind in @signals,
    do: {:ready, "supported_signal"}

  defp trigger(_signal, false), do: {:noop, "no_supported_improvement"}

  defp better?(%{score: score, uncertainty: uncertainty, supported: true}, %{
         score: baseline_score,
         uncertainty: baseline_uncertainty
       })
       when is_number(score) and is_number(uncertainty) and uncertainty >= 0 and
              is_number(baseline_score) and is_number(baseline_uncertainty) and
              baseline_uncertainty >= 0,
       do: score - uncertainty > baseline_score + baseline_uncertainty

  defp better?(_candidate, _baseline), do: false

  defp admission(state, id, role, estimate) do
    cond do
      not (is_binary(id) and byte_size(id) in 1..128 and role in @roles and
             valid_estimate?(estimate) and valid_requests?(estimate["requests"])) ->
        {:skip, "invalid_attempt"}

      Map.has_key?(state.records, key(id)) ->
        {:skip, "duplicate_attempt"}

      untracked?(state) ->
        {:stop, "untracked_parent_usage"}

      true ->
        Accounting.capacity(state, role, estimate, System.monotonic_time(:millisecond))
    end
  end

  defp untracked?(state) do
    total = JobBudget.snapshot(state.budget).requests
    tracked = Accounting.summarize(state.records, state.initial_tokens)["requests"]
    not is_integer(total) or total != state.initial_requests + tracked
  end

  defp valid_estimate?(%{"tokens" => tokens, "time_ms" => time, "cost_usd" => cost}),
    do:
      is_integer(tokens) and tokens >= 0 and is_integer(time) and time > 0 and
        (is_nil(cost) or (is_number(cost) and cost >= 0))

  defp valid_estimate?(_invalid), do: false

  defp valid_requests?(requests), do: is_integer(requests) and requests in 1..2048

  defp reserve_attempt(state, id, role, estimate, owner) do
    case JobBudget.reserve(state.budget, estimate["cost_usd"], estimate["requests"]) do
      {:ok, lease} ->
        :ok = JobBudget.checkpoint(state.budget)
        ref = Process.monitor(owner)

        receipt = %{
          "id" => key(id),
          "decision" => "run",
          "reason" => "reserved",
          "role" => role,
          "status" => "reserved",
          "reservation" => estimate,
          "usage" => nil,
          "issued_monotonic_ms" => System.monotonic_time(:millisecond),
          "timeout_ms" =>
            min(
              estimate["time_ms"],
              max(0, state.mono_deadline - System.monotonic_time(:millisecond))
            ),
          "deadline_ms" =>
            min(state.deadline, System.system_time(:millisecond) + estimate["time_ms"])
        }

        state =
          %{
            state
            | records: Map.put(state.records, key(id), receipt),
              leases: Map.put(state.leases, key(id), lease),
              refs: Map.put(state.refs, ref, {id, owner})
          }
          |> persist()

        if state.persist_failed do
          state = settle(state, id, nil, nil)
          {failure, state} = decision(state, role, "stop", "persistence_unavailable")
          {:reply, {:skip, failure}, state}
        else
          {:reply, {:ok, receipt}, state}
        end

      {:error, _outer_limit} ->
        {receipt, state} = decision(state, role, "skip", "outer_allowance_exhausted")
        {:reply, {:skip, receipt}, persist(state)}
    end
  end

  defp settle(state, id, usage, information) do
    case Map.pop(state.leases, key(id)) do
      {nil, _leases} ->
        state

      {lease, leases} ->
        :ok = JobBudget.settle(state.budget, lease, if(is_map(usage), do: usage["cost_usd"]))
        {ref, _owner} = Enum.find(state.refs, fn {_ref, {attempt, _owner}} -> attempt == id end)
        Process.demonitor(ref, [:flush])

        receipt =
          state.records[key(id)]
          |> Map.put("status", if(is_map(usage), do: "completed", else: "unknown"))
          |> Map.put("usage", usage)

        %{
          state
          | leases: leases,
            refs: Map.delete(state.refs, ref),
            records: Map.put(state.records, key(id), receipt)
        }
        |> close_overrun(receipt)
        |> information(receipt, information)
    end
  end

  defp close_overrun(state, %{"usage" => usage, "reservation" => reservation})
       when is_map(usage) do
    overrun =
      Enum.any?(~w(tokens time_ms cost_usd), fn key ->
        is_number(usage[key]) and is_number(reservation[key]) and usage[key] > reservation[key]
      end)

    if overrun, do: %{state | stop: "reservation_overrun"}, else: state
  end

  defp close_overrun(state, _unknown), do: state

  defp information(state, _receipt, :unobserved), do: state

  defp information(state, %{"role" => "task"}, _digest), do: state

  defp information(state, _receipt, digest) do
    useful = is_binary(digest) and byte_size(digest) == 64 and digest != state.information
    stagnant = if useful, do: 0, else: state.stagnant + 1

    %{
      state
      | stagnant: stagnant,
        information: if(useful, do: digest, else: state.information),
        learning_stop:
          if(stagnant >= state.max_stagnant,
            do: "diminishing_information",
            else: state.learning_stop
          )
    }
  end

  defp reconcile_dead(state) do
    Enum.reduce(state.refs, state, fn {_ref, {id, owner}}, state ->
      if Process.alive?(owner), do: state, else: settle(state, id, nil, nil)
    end)
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state =
      case state.refs[ref] do
        {id, _owner} -> settle(state, id, nil, nil)
        nil -> state
      end

    {:noreply, persist(state)}
  end

  defp decision(state, role, action, reason) do
    if map_size(state.records) >= state.max_records do
      receipt =
        Map.get(state.records, "decision/limit") ||
          receipt("decision/limit", "controller", "stop", "decision_limit")

      {receipt, %{state | records: Map.put_new(state.records, "decision/limit", receipt)}}
    else
      id = "decision/#{map_size(state.records)}"
      receipt = receipt(id, role, action, reason)
      {receipt, %{state | records: Map.put_new(state.records, id, receipt)}}
    end
  end

  defp receipt(id, role, action, reason),
    do: %{
      "id" => id,
      "role" => role,
      "decision" => action,
      "reason" => reason,
      "accounting" => %{"requests" => 0, "tokens" => 0, "cost_usd" => 0, "time_ms" => 0}
    }

  defp key(id), do: "attempt/" <> Contract.sha256(id)
  defp bounded(reason) when is_binary(reason), do: String.slice(reason, 0, 128)

  defp view(state) do
    outer = Contract.json(JobBudget.snapshot(state.budget))
    accounting = Accounting.summarize(state.records, state.initial_tokens)

    accounting =
      if is_integer(outer["requests"]) and is_integer(state.initial_requests) and
           outer["requests"] == state.initial_requests + accounting["requests"],
         do: accounting,
         else: Map.put(accounting, "tokens", nil)

    base = %{
      "schema_version" => 1,
      "limits" => %{
        "max_tokens" => state.max_tokens,
        "learning" => state.learning,
        "cost_mode" => Atom.to_string(state.cost_mode)
      },
      "job_id" => state.job_id,
      "records" => state.records,
      "seen" => state.seen,
      "deadline_ms" => state.deadline,
      "initial_tokens" => state.initial_tokens,
      "initial_requests" => state.initial_requests,
      "stop" => state.stop,
      "stagnant" => state.stagnant,
      "information" => state.information,
      "learning_stop" => state.learning_stop,
      "accounting" => accounting,
      "job_budget" => outer
    }

    Map.put(base, "sha256", Contract.digest(base))
  end

  defp persist(%{persist: nil} = state), do: state
  defp persist(%{persist_failed: true} = state), do: state

  defp persist(state) do
    if persist_boundary(state.persist, view(state)) == :ok,
      do: state,
      else: %{state | persist_failed: true}
  end

  defp persist_boundary(callback, snapshot) do
    callback.(snapshot)
  rescue
    _error -> {:error, :persistence_unavailable}
  catch
    _kind, _reason -> {:error, :persistence_unavailable}
  end
end
