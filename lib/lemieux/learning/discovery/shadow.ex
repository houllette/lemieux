defmodule Lemieux.Learning.Discovery.Shadow do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Foreground shadow discovery over host-supplied proposer and evaluator calls.

  This helper deliberately has no scheduler, persistence, sandbox client, or
  activation path. The caller supplies an externally secured sandbox context,
  exposed corpus manifest, and callbacks. The returned archive is useful to a
  standalone host or tests; an orchestrating host persists and resumes the
  same pure state transitions in durable jobs.

  ## Two loops

  The original loop is linear: propose, evaluate, propose. It remains the
  default because a host that drives its own selection needs nothing more.

  `search: true` turns the loop into an archive search. Each iteration asks
  `Lemieux.Learning.Discovery.Selection` whether to expand a parent or to
  evaluate an existing candidate on more cases (Huxley-Gödel Machine's
  widening rule over Thompson-sampled clade posteriors), chooses the
  evidence operator for an expansion through
  `Lemieux.Learning.Discovery.Comparison` (the Mendel Gödel Machine's
  comparative operators), and hands the proposer the digest, the planner's
  landscape and the calibration of earlier predictions. A candidate the critic
  vetoed or the surface validator rejected is recorded and never evaluated:
  that is the rejected-edit buffer, and it costs no rollouts.

  The loop never decides that a candidate is good. It records; the frontier
  computed at the end and the human-owned confirmation lane decide.
  """

  alias Lemieux.Learning.Discovery.Calibration
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Comparison
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Discovery.Selection
  alias Lemieux.Learning.Discovery.State

  @type result :: %{
          state: State.t(),
          candidates: [Candidate.t()],
          evaluations: [Evaluation.t()],
          frontier: Frontier.t(),
          artifacts: %{String.t() => binary()},
          incomplete: [map()],
          calibration: map() | nil,
          digest: map() | nil,
          selection: map() | nil,
          acceptance: map() | nil
        }

  @type proposer ::
          (Plan.t(), State.t(), map() -> {:ok, Candidate.t(), map()} | :done | {:error, term()})
  @type evaluator ::
          (Plan.t(), Candidate.t(), map() ->
             {:ok, [Evaluation.t()]}
             | {:ok, %{evaluations: [Evaluation.t()], artifacts: map(), incomplete: [map()]}}
             | {:error, term()})

  # A search that keeps re-selecting a case the evaluator cannot finish is
  # burning budget on infrastructure, not on candidates.
  @max_incomplete_per_case 3

  @doc """
  Runs bounded discovery synchronously and returns an immutable archive.

  Options: `:mode` (must be `:shadow`), `:sandbox` and `:exposed_corpus`
  (immutable `%{"id","sha256"}` references), `:search` (default `false`),
  `:policy` (overrides for `Lemieux.Learning.Discovery.Policy`), `:artifacts`
  (initial SHA-256 to bytes map, normally the seed content),
  `:proposer_context` and `:evaluator_context` (maps merged into every
  callback's context; a search evaluation also receives `:case_ids` and
  `:attempts`, the `%{case_id => count}` map `Policy.attempts/2` derives from
  the policy), `:resume` (a map with `:state`, `:candidates`,
  `:evaluations`, `:artifacts` and `:incomplete` as persisted from an earlier
  run; the state must still be running or budget-exhausted and must list
  exactly the supplied candidates and evaluations), and `:observer` (an
  arity-one function that receives
  `{:candidate, candidate, artifacts}`, `{:evaluations, evaluations, artifacts,
  incomplete}` and `{:state, state}` as they happen, so a host can persist the
  archive while the search is still paying for it).
  """
  @spec run(plan :: Plan.t(), proposer :: proposer(), evaluator :: evaluator(), opts :: keyword()) ::
          {:ok, result()} | {:error, term(), State.t()}
  def run(%Plan{} = plan, proposer, evaluator, opts)
      when is_function(proposer, 3) and is_function(evaluator, 3) and is_list(opts) do
    with {:ok, context} <- context(plan, opts),
         {:ok, state, acc} <- starting_point(plan, context, Keyword.get(opts, :resume)) do
      if context.search? do
        search(plan, state, acc, proposer, evaluator, context)
      else
        loop(plan, state, acc.candidates, acc.evaluations, proposer, evaluator, context)
      end
    else
      {:error, reason} -> {:error, reason, State.new(plan)}
    end
  end

  # A resumed search starts from the archive a host persisted through the
  # observer: the state's idempotency keys make re-recording impossible, so
  # the only way to repeat paid work is to forget it, and this refuses to.
  defp starting_point(plan, context, nil) do
    with {:ok, state} <- plan |> State.new() |> State.start() do
      {:ok, state,
       %{
         candidates: [],
         evaluations: [],
         artifacts: context.artifacts,
         incomplete: [],
         rng: :rand.seed_s(:exsss, context.policy["seed"]),
         iterations: 0
       }}
    end
  end

  defp starting_point(plan, context, %{state: %State{} = state} = resume) do
    candidates = Map.get(resume, :candidates, [])
    evaluations = Map.get(resume, :evaluations, [])

    with :ok <- resumable(state, plan),
         :ok <- archive_matches(state, candidates, evaluations) do
      {:ok, state,
       %{
         candidates: candidates,
         evaluations: evaluations,
         artifacts: Map.merge(context.artifacts, Map.get(resume, :artifacts, %{})),
         incomplete: Map.get(resume, :incomplete, []),
         rng: :rand.seed_s(:exsss, context.policy["seed"] * 1_000_003 + length(state.events)),
         iterations: 0
       }}
    end
  end

  defp starting_point(_plan, _context, _resume), do: {:error, :invalid_resume}

  defp resumable(%State{status: status} = state, plan) do
    cond do
      state.plan_id != plan.id or state.plan_sha256 != plan.sha256 ->
        {:error, :discovery_state_plan_mismatch}

      status in [:running, :budget_exhausted] ->
        :ok

      true ->
        {:error, {:not_resumable, status}}
    end
  end

  defp archive_matches(state, candidates, evaluations) do
    recorded_candidates = state.candidates |> Enum.map(& &1["id"]) |> Enum.sort()
    recorded_evaluations = state.evaluations |> Enum.map(& &1["id"]) |> Enum.sort()

    cond do
      Enum.sort(Enum.map(candidates, & &1.id)) != recorded_candidates ->
        {:error, :resume_candidates_mismatch}

      Enum.sort(Enum.map(evaluations, & &1.id)) != recorded_evaluations ->
        {:error, :resume_evaluations_mismatch}

      true ->
        :ok
    end
  end

  @doc "Returns options that force one fresh root session for a proposer iteration."
  @spec fresh_session_options(plan :: Plan.t(), ordinal :: pos_integer()) :: keyword()
  def fresh_session_options(%Plan{} = plan, ordinal) when is_integer(ordinal) and ordinal > 0 do
    id = "discovery_session_" <> Lemieux.ID.generate()

    [
      id: id,
      root_session_id: id,
      entries: [],
      correlation_ids: %{
        "discovery_plan_id" => plan.id,
        "discovery_plan_sha256" => plan.sha256,
        "candidate_ordinal" => ordinal
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Search loop

  defp search(plan, state, acc, proposer, evaluator, context) do
    limit = iteration_limit(plan)

    cond do
      state.status == :budget_exhausted ->
        finish(plan, state, acc, context)

      acc.iterations >= limit ->
        {:ok, state} = State.note(state, "iteration_limit", %{"limit" => limit})
        finish(plan, state, acc, context)

      true ->
        {action, rng} =
          Selection.next_action(plan, acc.candidates, acc.evaluations, context.policy, acc.rng)

        acc = %{acc | rng: rng, iterations: acc.iterations + 1}
        step(action, plan, state, acc, proposer, evaluator, context)
    end
  end

  defp step(:done, plan, state, acc, _proposer, _evaluator, context),
    do: finish(plan, state, acc, context)

  defp step({:expand, parent}, plan, state, acc, proposer, evaluator, context) do
    if length(acc.candidates) >= plan.budget["maximum_candidates"] do
      finish(plan, state, acc, context)
    else
      expand(parent, plan, state, acc, proposer, evaluator, context)
    end
  end

  defp step({:evaluate, candidate_id, case_ids}, plan, state, acc, proposer, evaluator, context) do
    case Enum.find(acc.candidates, &(&1.id == candidate_id)) do
      nil ->
        fail(state, "selection_unknown_candidate")

      candidate ->
        evaluate_candidate(candidate, case_ids, plan, state, acc, proposer, evaluator, context)
    end
  end

  defp expand(parent, plan, state, acc, proposer, evaluator, context) do
    {operator, evidence, rng} = choose_operator(parent, plan, acc, context.policy)
    acc = %{acc | rng: rng}
    ordinal = length(acc.candidates) + 1
    {:ok, store} = Agent.start_link(fn -> %{} end)

    proposer_context =
      context.proposer_context
      |> Map.merge(context.base_context)
      |> Map.merge(%{
        ordinal: ordinal,
        parent: parent,
        operator: operator,
        evidence: evidence,
        candidates: acc.candidates,
        evaluations: acc.evaluations,
        artifacts: acc.artifacts,
        digest: Digest.build(plan, acc.evaluations, acc.artifacts, context.policy),
        calibration: Calibration.summarize(plan, acc.candidates, acc.evaluations, context.policy),
        frontier_ids: frontier_ids(plan, acc),
        retain: fn sha, bytes -> Agent.update(store, &Map.put(&1, sha, bytes)) end
      })

    outcome = proposer.(plan, state, proposer_context)
    retained = Agent.get(store, & &1)
    Agent.stop(store)

    {:ok, state} =
      State.note(state, "action_selected", %{
        "action" => "expand",
        "parent" => parent_facts(parent),
        "operator" => operator,
        "ordinal" => ordinal
      })

    case outcome do
      :done ->
        finish(plan, state, acc, context)

      {:ok, %Candidate{} = candidate, accounting} when is_map(accounting) ->
        with :ok <- Candidate.verify(candidate),
             :ok <- Candidate.verify_lineage(acc.candidates ++ [candidate], plan.seeds),
             {:ok, state} <- State.record_candidate(state, plan, candidate, accounting),
             {:ok, state} <- note_fate(state, candidate) do
          observe(context, {:candidate, candidate, retained})
          observe(context, {:state, state})

          acc = %{
            acc
            | candidates: acc.candidates ++ [candidate],
              artifacts: Map.merge(acc.artifacts, retained)
          }

          search(plan, state, acc, proposer, evaluator, context)
        else
          {:error, reason} -> fail(state, "invalid_candidate", reason)
        end

      {:error, reason} ->
        fail(state, "proposer_failed", reason)

      _invalid ->
        fail(state, "invalid_proposer_return", :invalid_proposer_return)
    end
  end

  defp evaluate_candidate(candidate, case_ids, plan, state, acc, proposer, evaluator, context) do
    # The case list stays the unit of scheduling; the attempt count per case
    # rides beside it so the evaluator can repeat a case without selection
    # having to know that a repeat is not a new case.
    attempts = Map.new(case_ids, &{&1, Policy.attempts(context.policy, &1)})

    evaluator_context =
      context.evaluator_context
      |> Map.merge(context.base_context)
      |> Map.merge(%{case_ids: case_ids, attempts: attempts, artifacts: acc.artifacts})

    {:ok, state} =
      State.note(state, "action_selected", %{
        "action" => "evaluate",
        "candidate_id" => candidate.id,
        "case_ids" => case_ids,
        "attempts" => attempts
      })

    case normalize_evaluation(evaluator.(plan, candidate, evaluator_context)) do
      {:ok, %{evaluations: evaluations, artifacts: artifacts, incomplete: incomplete}} ->
        with {:ok, state} <- record_all(state, plan, evaluations),
             {:ok, state, acc} <- note_incomplete(state, acc, candidate, incomplete) do
          observe(context, {:evaluations, evaluations, artifacts, incomplete})
          observe(context, {:state, state})

          acc = %{
            acc
            | evaluations: acc.evaluations ++ evaluations,
              artifacts: Map.merge(acc.artifacts, artifacts)
          }

          search(plan, state, acc, proposer, evaluator, context)
        else
          {:error, reason} -> fail(state, "invalid_evaluation", reason)
          {:fail, state, category} -> fail(state, category)
        end

      {:error, reason} ->
        fail(state, "evaluator_failed", reason)

      :invalid ->
        fail(state, "invalid_evaluator_return", :invalid_evaluator_return)
    end
  end

  defp normalize_evaluation({:ok, evaluations}) when is_list(evaluations),
    do: {:ok, %{evaluations: evaluations, artifacts: %{}, incomplete: []}}

  defp normalize_evaluation({:ok, %{evaluations: evaluations} = result})
       when is_list(evaluations),
       do: {:ok, Map.merge(%{artifacts: %{}, incomplete: []}, result)}

  defp normalize_evaluation({:error, reason}), do: {:error, reason}
  defp normalize_evaluation(_other), do: :invalid

  defp record_all(state, plan, evaluations) do
    Enum.reduce_while(evaluations, {:ok, state}, fn evaluation, {:ok, state} ->
      case State.record_evaluation(state, plan, evaluation) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp note_incomplete(state, acc, _candidate, []), do: {:ok, state, acc}

  defp note_incomplete(state, acc, candidate, incomplete) do
    rows = Enum.map(incomplete, &Map.put(&1, "candidate_id", candidate.id))
    acc = %{acc | incomplete: acc.incomplete ++ rows}

    repeated =
      acc.incomplete
      |> Enum.frequencies_by(&{&1["candidate_id"], &1["case_id"]})
      |> Enum.any?(fn {_key, count} -> count >= @max_incomplete_per_case end)

    {:ok, state} =
      State.note(state, "evaluation_incomplete", %{
        "candidate_id" => candidate.id,
        "attempts" => rows
      })

    if repeated, do: {:fail, state, "evaluation_incomplete_repeatedly"}, else: {:ok, state, acc}
  end

  defp note_fate(state, %Candidate{} = candidate) do
    cond do
      candidate.interface_validation["status"] != "passed" ->
        State.note(state, "candidate_interface_failed", %{
          "candidate_id" => candidate.id,
          "detail" => candidate.interface_validation["detail"]
        })

      get_in(candidate.extensions, ["critic", "verdict"]) == "veto" ->
        State.note(state, "candidate_vetoed", %{
          "candidate_id" => candidate.id,
          "reason" => get_in(candidate.extensions, ["critic", "reason"])
        })

      true ->
        {:ok, state}
    end
  end

  defp choose_operator(_parent, _plan, %{candidates: []} = acc, _policy),
    do: {"seed", %{}, acc.rng}

  defp choose_operator({:seed, _seed}, _plan, acc, _policy), do: {"clonal", %{}, acc.rng}

  defp choose_operator({:candidate, id}, plan, acc, policy) do
    eligible = Comparison.eligible_operators(plan, id, acc.candidates, acc.evaluations, policy)

    case Comparison.select_operator(eligible, policy, acc.rng) do
      {{operator, evidence}, rng} -> {operator, evidence, rng}
      {:none, rng} -> {"clonal", %{"operator" => "clonal", "candidate_id" => id}, rng}
    end
  end

  defp frontier_ids(plan, acc) do
    case Frontier.compute(plan, acc.candidates, acc.evaluations) do
      {:ok, frontier} -> Enum.map(frontier.members, & &1["candidate_id"])
      {:error, _reason} -> []
    end
  end

  defp parent_facts({:seed, seed}), do: %{"kind" => "seed", "id" => seed["id"]}
  defp parent_facts({:candidate, id}), do: %{"kind" => "candidate", "id" => id}

  defp iteration_limit(plan) do
    cases = max(length(plan.development_case_ids), 1)
    plan.budget["maximum_candidates"] * (cases + 2) * 2
  end

  defp finish(plan, state, acc, context) do
    with {:ok, frontier} <- Frontier.compute(plan, acc.candidates, acc.evaluations),
         {:ok, state} <- summarize(plan, state, acc, frontier, context),
         {:ok, state} <- State.complete(state, plan, frontier) do
      observe(context, {:state, state})

      {:ok,
       %{
         state: state,
         candidates: acc.candidates,
         evaluations: acc.evaluations,
         frontier: frontier,
         artifacts: acc.artifacts,
         incomplete: acc.incomplete,
         calibration:
           Calibration.summarize(plan, acc.candidates, acc.evaluations, context.policy),
         digest: Digest.build(plan, acc.evaluations, acc.artifacts, context.policy),
         selection: Selection.summary(plan, acc.candidates, acc.evaluations, context.policy),
         acceptance: Comparison.acceptance_by_operator(acc.candidates, frontier)
       }}
    else
      {:error, reason} -> fail(state, "invalid_frontier", reason)
    end
  end

  defp summarize(plan, state, acc, frontier, context) do
    calibration = Calibration.summarize(plan, acc.candidates, acc.evaluations, context.policy)

    State.note(state, "search_summary", %{
      "calibration" => Map.take(calibration, ["status", "aggregate"]),
      "acceptance" => Comparison.acceptance_by_operator(acc.candidates, frontier),
      "incomplete" => length(acc.incomplete),
      "frontier_members" => Enum.map(frontier.members, & &1["candidate_id"])
    })
  end

  # ---------------------------------------------------------------------------
  # Legacy linear loop

  defp loop(plan, state, candidates, evaluations, proposer, evaluator, context) do
    cond do
      state.status == :budget_exhausted ->
        finish_linear(plan, state, candidates, evaluations, context)

      length(candidates) >= plan.budget["maximum_candidates"] ->
        finish_linear(plan, state, candidates, evaluations, context)

      true ->
        propose(plan, state, candidates, evaluations, proposer, evaluator, context)
    end
  end

  defp propose(plan, state, candidates, evaluations, proposer, evaluator, context) do
    proposer_context = Map.merge(context.base_context, %{ordinal: length(candidates) + 1})

    case proposer.(plan, state, proposer_context) do
      :done ->
        finish_linear(plan, state, candidates, evaluations, context)

      {:ok, %Candidate{} = candidate, accounting} when is_map(accounting) ->
        with :ok <- Candidate.verify(candidate),
             :ok <- Candidate.verify_lineage(candidates ++ [candidate], plan.seeds),
             {:ok, next_state} <- State.record_candidate(state, plan, candidate, accounting) do
          evaluate(
            plan,
            next_state,
            candidates ++ [candidate],
            evaluations,
            candidate,
            proposer,
            evaluator,
            context
          )
        else
          {:error, reason} -> fail(state, "invalid_candidate", reason)
        end

      {:error, reason} ->
        fail(state, "proposer_failed", reason)

      _invalid ->
        fail(state, "invalid_proposer_return", :invalid_proposer_return)
    end
  end

  defp evaluate(
         plan,
         %{status: :budget_exhausted} = state,
         candidates,
         evaluations,
         _candidate,
         _proposer,
         _evaluator,
         context
       ) do
    finish_linear(plan, state, candidates, evaluations, context)
  end

  defp evaluate(plan, state, candidates, evaluations, candidate, proposer, evaluator, context) do
    case normalize_evaluation(evaluator.(plan, candidate, context.base_context)) do
      {:ok, %{evaluations: recorded}} ->
        case record_all(state, plan, recorded) do
          {:ok, next_state} ->
            loop(
              plan,
              next_state,
              candidates,
              evaluations ++ recorded,
              proposer,
              evaluator,
              context
            )

          {:error, reason} ->
            fail(state, "invalid_evaluation", reason)
        end

      {:error, reason} ->
        fail(state, "evaluator_failed", reason)

      :invalid ->
        fail(state, "invalid_evaluator_return", :invalid_evaluator_return)
    end
  end

  defp finish_linear(plan, state, candidates, evaluations, context) do
    acc = %{
      candidates: candidates,
      evaluations: evaluations,
      artifacts: context.artifacts,
      incomplete: []
    }

    with {:ok, frontier} <- Frontier.compute(plan, candidates, evaluations),
         {:ok, state} <- State.complete(state, plan, frontier) do
      {:ok,
       %{
         state: state,
         candidates: candidates,
         evaluations: evaluations,
         frontier: frontier,
         artifacts: acc.artifacts,
         incomplete: [],
         calibration: nil,
         digest: nil,
         selection: nil,
         acceptance: nil
       }}
    else
      {:error, reason} -> fail(state, "invalid_frontier", reason)
    end
  end

  # ---------------------------------------------------------------------------

  defp fail(state, category, reason \\ nil) do
    case State.fail(state, category) do
      {:ok, failed} -> {:error, {String.to_atom(category), reason}, failed}
      {:error, _} -> {:error, {String.to_atom(category), reason}, state}
    end
  end

  # Observers are best-effort persistence, never control flow: a host that
  # cannot write its archive learns that from the returned result, not by
  # having the search die halfway through paid work.
  defp observe(%{observer: observer}, event) when is_function(observer, 1) do
    observer.(event)
    :ok
  rescue
    _error -> :ok
  end

  defp observe(_context, _event), do: :ok

  defp context(plan, opts) do
    with {:ok, sandbox} <- immutable(Keyword.get(opts, :sandbox), :external_sandbox_required),
         {:ok, corpus} <- immutable(Keyword.get(opts, :exposed_corpus), :exposed_corpus_required),
         :shadow <- Keyword.get(opts, :mode, :none) do
      policy = Policy.read(plan, Keyword.get(opts, :policy, %{}))

      {:ok,
       %{
         search?: Keyword.get(opts, :search, false) == true,
         policy: policy,
         artifacts: Keyword.get(opts, :artifacts, %{}),
         proposer_context: Keyword.get(opts, :proposer_context, %{}),
         evaluator_context: Keyword.get(opts, :evaluator_context, %{}),
         observer: Keyword.get(opts, :observer),
         base_context: %{sandbox: sandbox, exposed_corpus: corpus, mode: :shadow, policy: policy}
       }}
    else
      {:error, reason} -> {:error, reason}
      _mode -> {:error, :shadow_mode_required}
    end
  end

  defp immutable(%{"id" => id, "sha256" => sha256}, _reason)
       when is_binary(id) and id != "" and is_binary(sha256) and byte_size(sha256) == 64,
       do: {:ok, %{"id" => id, "sha256" => sha256}}

  defp immutable(_value, reason), do: {:error, reason}
end
