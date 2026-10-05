defmodule Lemieux.Learning.Discovery.State do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Append-only, restartable state for one foreground or host-orchestrated search.

  The projection records candidate and evaluation idempotency keys before a
  host launches more work. Encoding and restoring it preserves those keys, so
  recovery cannot silently repeat an already recorded evaluation. Lemieux
  does not schedule or persist this state for the host.

  Budget accounting is metered by default: a fact that is missing marks the
  whole budget unknown and the search stops. A plan whose budget says
  `"unknown_cost" => "allow"` opts into quota accounting, where dollars may be
  unknown but tokens and time still count — see `account/4` for why.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan

  @version 1
  @statuses ~w(planned running budget_exhausted completed aborted failed)a

  @type status :: :planned | :running | :budget_exhausted | :completed | :aborted | :failed
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          plan_id: String.t(),
          plan_sha256: String.t(),
          status: status(),
          candidates: [map()],
          evaluations: [map()],
          evaluation_keys: [String.t()],
          budget: map(),
          frontier: map() | nil,
          events: [map()]
        }

  @enforce_keys [
    :id,
    :sha256,
    :plan_id,
    :plan_sha256,
    :status,
    :candidates,
    :evaluations,
    :evaluation_keys,
    :budget,
    :events
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            plan_id: nil,
            plan_sha256: nil,
            status: :planned,
            candidates: [],
            evaluations: [],
            evaluation_keys: [],
            budget: %{},
            frontier: nil,
            events: []

  @doc "Creates the planned state for one frozen discovery plan."
  @spec new(plan :: Plan.t()) :: t()
  def new(%Plan{} = plan) do
    id = "discovery_" <> Lemieux.ID.generate()

    state = %__MODULE__{
      id: id,
      sha256: "",
      plan_id: plan.id,
      plan_sha256: plan.sha256,
      status: :planned,
      candidates: [],
      evaluations: [],
      evaluation_keys: [],
      budget: %{
        "candidates" => 0,
        "tokens" => 0,
        "cost_usd" => 0.0,
        "time_ms" => 0,
        "state" => "complete"
      },
      events: [event("planned", %{"plan_sha256" => plan.sha256})]
    }

    rehash(state)
  end

  @doc "Transitions a planned discovery to running."
  @spec start(state :: t()) :: {:ok, t()} | {:error, term()}
  def start(%__MODULE__{status: :planned} = state),
    do: {:ok, transition(state, :running, "started", %{})}

  def start(%__MODULE__{} = state),
    do: {:error, {:invalid_discovery_state, state.status, :running}}

  @doc "Records one immutable candidate and optional proposer accounting facts."
  @spec record_candidate(
          state :: t(),
          plan :: Plan.t(),
          candidate :: Candidate.t(),
          facts :: map()
        ) ::
          {:ok, t()} | {:error, term()}
  def record_candidate(state, plan, candidate, facts \\ %{})

  def record_candidate(
        %__MODULE__{status: :running} = state,
        %Plan{} = plan,
        %Candidate{} = candidate,
        facts
      )
      when is_map(facts) do
    with :ok <- plan_identity(state, plan),
         :ok <- Candidate.verify(candidate),
         true <- candidate.plan_id == plan.id and candidate.plan_sha256 == plan.sha256,
         :ok <- candidate_absent(state, candidate),
         :ok <- candidate_budget_available(state, plan) do
      reference = %{
        "id" => candidate.id,
        "sha256" => candidate.sha256,
        "content_sha256" => Candidate.content_sha256(candidate)
      }

      state =
        state
        |> Map.update!(:candidates, &(&1 ++ [reference]))
        |> account(plan, facts, 1)
        |> append_event("candidate_recorded", reference)
        |> maybe_exhaust(plan)

      {:ok, state}
    else
      false -> {:error, {:duplicate_or_invalid_candidate, candidate.id}}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_candidate(%__MODULE__{} = state, %Plan{}, %Candidate{}, _facts),
    do: {:error, {:invalid_discovery_state, state.status, :record_candidate}}

  @doc "Records one evaluation exactly once by id and candidate/split/case key."
  @spec record_evaluation(state :: t(), plan :: Plan.t(), evaluation :: Evaluation.t()) ::
          {:ok, t()} | {:error, term()}
  def record_evaluation(
        %__MODULE__{status: :running} = state,
        %Plan{} = plan,
        %Evaluation{} = evaluation
      ) do
    key = evaluation_key(evaluation)

    with :ok <- plan_identity(state, plan),
         :ok <- Evaluation.verify(evaluation),
         true <- evaluation.plan_id == plan.id and evaluation.plan_sha256 == plan.sha256,
         true <- candidate_recorded?(state, evaluation),
         :ok <- evaluation_absent(state, evaluation, key) do
      reference = %{
        "id" => evaluation.id,
        "sha256" => evaluation.sha256,
        "candidate_id" => evaluation.candidate_id,
        "candidate_content_sha256" => evaluation.candidate_content_sha256,
        "split" => evaluation.split,
        "case_id" => evaluation.case_id
      }

      facts = %{
        "tokens" => evaluation.usage["total_tokens"],
        "cost_usd" => evaluation.cost["usd"],
        "time_ms" => evaluation.latency["milliseconds"]
      }

      state =
        state
        |> Map.update!(:evaluations, &(&1 ++ [reference]))
        |> Map.update!(:evaluation_keys, &(&1 ++ [key]))
        |> account(plan, facts, 0)
        |> append_event("evaluation_recorded", Map.put(reference, "key", key))
        |> maybe_exhaust(plan)

      {:ok, state}
    else
      false -> {:error, {:duplicate_or_invalid_evaluation, evaluation.id, key}}
      {:error, reason} -> {:error, reason}
    end
  end

  def record_evaluation(%__MODULE__{} = state, %Plan{}, %Evaluation{}),
    do: {:error, {:invalid_discovery_state, state.status, :record_evaluation}}

  @doc "Completes running or exhausted discovery with a deterministic frontier."
  @spec complete(state :: t(), plan :: Plan.t(), frontier :: Frontier.t()) ::
          {:ok, t()} | {:error, term()}
  def complete(%__MODULE__{status: status} = state, %Plan{} = plan, %Frontier{} = frontier)
      when status in [:running, :budget_exhausted] do
    with :ok <- plan_identity(state, plan),
         true <- frontier.plan_id == plan.id and frontier.plan_sha256 == plan.sha256 do
      reference = %{"id" => frontier.id, "sha256" => frontier.sha256}

      {:ok,
       state
       |> Map.put(:frontier, reference)
       |> transition(:completed, "completed", reference)}
    else
      false -> {:error, :frontier_plan_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete(%__MODULE__{} = state, %Plan{}, %Frontier{}),
    do: {:error, {:invalid_discovery_state, state.status, :completed}}

  @doc """
  Appends a free-form search event without changing status or budget.

  The search loop records selection decisions, vetoes and incomplete
  attempts here so a restart projection explains *why* the archive has the
  shape it has, not only what it contains. Facts must be JSON-shaped.
  """
  @spec note(state :: t(), type :: String.t(), facts :: map()) :: {:ok, t()} | {:error, term()}
  def note(%__MODULE__{status: status} = state, type, facts)
      when status in [:running, :budget_exhausted] and is_binary(type) and type != "" and
             is_map(facts) do
    {:ok, append_event(state, type, Contract.json(facts))}
  end

  def note(%__MODULE__{} = state, _type, _facts),
    do: {:error, {:invalid_discovery_state, state.status, :note}}

  @doc "Records an operator or policy abort."
  @spec abort(state :: t(), reason :: String.t()) :: {:ok, t()} | {:error, term()}
  def abort(%__MODULE__{status: status} = state, reason)
      when status in [:planned, :running, :budget_exhausted] and is_binary(reason) and
             reason != "" do
    {:ok, transition(state, :aborted, "aborted", %{"reason" => reason})}
  end

  def abort(%__MODULE__{} = state, _reason),
    do: {:error, {:invalid_discovery_state, state.status, :aborted}}

  @doc "Records a terminal discovery failure category without arbitrary error content."
  @spec fail(state :: t(), category :: String.t()) :: {:ok, t()} | {:error, term()}
  def fail(%__MODULE__{status: status} = state, category)
      when status in [:planned, :running, :budget_exhausted] and is_binary(category) and
             category != "" do
    {:ok, transition(state, :failed, "failed", %{"category" => category})}
  end

  def fail(%__MODULE__{} = state, _category),
    do: {:error, {:invalid_discovery_state, state.status, :failed}}

  @doc "Returns the JSON-shaped state projection."
  @spec to_map(state :: t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      "schema_version" => state.schema_version,
      "id" => state.id,
      "sha256" => state.sha256,
      "plan_id" => state.plan_id,
      "plan_sha256" => state.plan_sha256,
      "status" => Atom.to_string(state.status),
      "candidates" => state.candidates,
      "evaluations" => state.evaluations,
      "evaluation_keys" => state.evaluation_keys,
      "budget" => state.budget,
      "frontier" => state.frontier,
      "events" => state.events
    }
  end

  @doc "Encodes a canonical restart projection."
  @spec encode!(state :: t()) :: String.t()
  def encode!(%__MODULE__{} = state), do: state |> to_map() |> Contract.encode!()

  @doc "Decodes state only under the exact plan it belongs to."
  @spec decode(plan :: Plan.t(), json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(%Plan{} = plan, json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         true <- map["plan_id"] == plan.id and map["plan_sha256"] == plan.sha256,
         :ok <- verify(map),
         {:ok, status} <- status(map["status"]) do
      {:ok,
       %__MODULE__{
         id: map["id"],
         sha256: map["sha256"],
         plan_id: map["plan_id"],
         plan_sha256: map["plan_sha256"],
         status: status,
         candidates: map["candidates"],
         evaluations: map["evaluations"],
         evaluation_keys: map["evaluation_keys"],
         budget: map["budget"],
         frontier: map["frontier"],
         events: map["events"]
       }}
    else
      false -> {:error, :discovery_state_plan_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Verifies version and projection digest."
  @spec verify(state_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = state), do: state |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_discovery_state}

  defp plan_identity(state, plan) do
    if state.plan_id == plan.id and state.plan_sha256 == plan.sha256,
      do: :ok,
      else: {:error, :discovery_state_plan_mismatch}
  end

  defp candidate_recorded?(state, evaluation) do
    Enum.any?(state.candidates, fn candidate ->
      candidate["id"] == evaluation.candidate_id and
        candidate["content_sha256"] == evaluation.candidate_content_sha256
    end)
  end

  defp candidate_absent(state, candidate) do
    if Enum.any?(state.candidates, &(&1["id"] == candidate.id)),
      do: {:error, {:duplicate_or_invalid_candidate, candidate.id}},
      else: :ok
  end

  defp candidate_budget_available(state, plan) do
    if length(state.candidates) < plan.budget["maximum_candidates"],
      do: :ok,
      else: {:error, :candidate_budget_exhausted}
  end

  defp evaluation_absent(state, evaluation, key) do
    if Enum.any?(state.evaluations, &(&1["id"] == evaluation.id)) or
         key in state.evaluation_keys,
       do: {:error, {:duplicate_or_invalid_evaluation, evaluation.id, key}},
       else: :ok
  end

  # One key per candidate, split, case and attempt. The first attempt keeps the
  # historical three-part key, so an archive persisted before repeated attempts
  # existed still refuses to re-record its evaluations on resume; later attempts are
  # told apart by the `"attempt"` the evaluator records. An evaluator that never
  # tags attempts therefore still gets exactly one evaluation per case.
  defp evaluation_key(evaluation) do
    base = Enum.join([evaluation.candidate_id, evaluation.split, evaluation.case_id], "|")

    case evaluation.observations["attempt"] do
      attempt when is_integer(attempt) and attempt > 1 ->
        base <> "|" <> Integer.to_string(attempt)

      _first ->
        base
    end
  end

  defp account(state, plan, facts, candidates) do
    required = Enum.map(required_facts(plan), &facts[&1])
    budget = Map.update!(state.budget, "candidates", &(&1 + candidates))

    budget =
      if Enum.any?(required, &is_nil/1) do
        Map.put(budget, "state", "unknown")
      else
        budget
        |> Map.update!("tokens", &(&1 + facts["tokens"]))
        |> Map.update!("time_ms", &(&1 + facts["time_ms"]))
        |> account_cost(facts["cost_usd"])
      end

    %{state | budget: budget}
  end

  # A quota-billed provider cannot say what a request cost in dollars, but it does
  # say how many tokens it took and how long. Under the default every nil fact
  # marks the whole budget unknown and stops the search — right for a metered
  # provider, where an unpriced request is one nobody can bound, and wrong for a
  # quota one, where it would stop every search at its first candidate.
  # `"unknown_cost" => "allow"` is the opt-in: dollars become a lower bound marked
  # unknown, while tokens and time still count and still exhaust. Only that exact
  # value opts in, and the key is written only when a cost is actually missing, so
  # the encoded bytes of every existing state are unchanged.
  defp required_facts(%Plan{budget: %{"unknown_cost" => "allow"}}), do: ~w(tokens time_ms)
  defp required_facts(%Plan{}), do: ~w(tokens cost_usd time_ms)

  defp account_cost(budget, nil), do: Map.put(budget, "cost_state", "unknown")
  defp account_cost(budget, cost_usd), do: Map.update!(budget, "cost_usd", &(&1 + cost_usd))

  defp maybe_exhaust(state, plan) do
    exhausted? =
      state.budget["state"] == "unknown" or
        state.budget["tokens"] > plan.budget["maximum_tokens"] or
        state.budget["cost_usd"] > plan.budget["maximum_cost_usd"] or
        state.budget["time_ms"] > plan.budget["maximum_time_ms"]

    if exhausted? and state.status == :running,
      do: transition(state, :budget_exhausted, "budget_exhausted", state.budget),
      else: rehash(state)
  end

  defp append_event(state, type, facts),
    do: rehash(%{state | events: state.events ++ [event(type, facts)]})

  defp transition(state, status, type, facts),
    do: rehash(%{state | status: status, events: state.events ++ [event(type, facts)]})

  defp event(type, facts) do
    %{"type" => type, "facts" => facts, "at" => DateTime.to_iso8601(DateTime.utc_now())}
  end

  defp rehash(state) do
    map = state |> to_map() |> Map.delete("sha256")
    %{state | sha256: Contract.digest(map)}
  end

  defp status(value) do
    case Enum.find(@statuses, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:unknown_discovery_status, value}}
      status -> {:ok, status}
    end
  end
end
