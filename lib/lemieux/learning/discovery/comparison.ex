defmodule Lemieux.Learning.Discovery.Comparison do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Comparative evidence for the proposer, assembled from development-split
  evaluations.

  A proposer conditioned on one failure trajectory sees every locus the task
  touched and has no way to tell the defect from the incidental: it edits what
  it can see, and most of what it can see is fine. The Mendel Gödel Machine
  (arXiv 2608.07645) takes its signal from comparison instead. The same
  candidate failing several cases narrows the defect to what those
  trajectories share (`reaction_norm/4`), and a second candidate that
  succeeded on the same case is a contrastive control that isolates the
  difference (`cross_lineage/5`). The single-trajectory case survives as the
  `"clonal"` operator so a host can measure what the comparative operators buy
  over it with `acceptance_by_operator/2` instead of assuming it.

  Everything here is a pure query. `select_operator/3` takes the `:rand` state
  it draws from and hands the advanced state back, so a resumed or replayed
  search draws the same operator sequence from the same transcript; drawing
  from the process-default generator would let two replays of one plan
  diverge, and the per-operator acceptance counts would then describe runs
  nobody can reproduce. Success is always `Policy.success?/2` on the plan's
  declared objective and never re-derived here, so this module and the
  frontier cannot disagree about what a failure is.

  A cross-lineage pair prefers a succeeding reference and falls back to a
  failing one only when no listed candidate solved the case, flagging it with
  `"reference_success" => false`. Without the flag the proposer would read two
  failures as a control and conclude the case is unsolvable rather than that
  both lineages share the defect.
  """

  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  @typedoc ~S(An operator name: `"clonal"`, `"reaction_norm"`, `"cross_lineage"` or `"consolidate"`.)
  @type operator :: String.t()

  @typedoc "JSON-shaped evidence handed to the proposer with the operator that produced it."
  @type evidence :: %{required(String.t()) => term()}

  @typedoc "One candidate's result on one development case."
  @type case_outcome :: %{required(String.t()) => boolean() | String.t()}

  @typedoc "A candidate's development outcomes keyed by case id."
  @type candidate_outcomes :: %{String.t() => case_outcome()}

  @typedoc "Development outcomes keyed by candidate id, then case id."
  @type outcomes :: %{String.t() => candidate_outcomes()}

  @doc """
  Development-split outcomes keyed by candidate id and case id.

  Validation evaluations and cases outside the plan's development split are
  ignored: the proposer may only see development evidence. When one candidate
  has several evaluations on one case the case counts as a success only if
  every evaluation succeeded, and the reported evaluation id is the last one
  in `evaluations`, so a flaky case is treated as failing rather than as
  solved by its luckiest run.
  """
  @spec outcomes(plan :: Plan.t(), evaluations :: [Evaluation.t()], policy :: Policy.t()) ::
          outcomes()
  def outcomes(%Plan{} = plan, evaluations, policy)
      when is_list(evaluations) and is_map(policy) do
    development = MapSet.new(plan.development_case_ids)

    evaluations
    |> Enum.filter(&(Policy.development?(&1) and MapSet.member?(development, &1.case_id)))
    |> Enum.group_by(& &1.candidate_id)
    |> Map.new(fn {candidate_id, observed} -> {candidate_id, case_outcomes(observed, policy)} end)
  end

  @doc """
  Reaction-norm evidence: the cases one candidate failed, so the proposer can
  intersect their trajectories. Eligible only with at least two development
  failures; one failure is the clonal operator's evidence, not a norm.
  """
  @spec reaction_norm(
          plan :: Plan.t(),
          candidate_id :: String.t(),
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: {:ok, evidence()} | :ineligible
  def reaction_norm(%Plan{} = plan, candidate_id, evaluations, policy)
      when is_binary(candidate_id) do
    plan
    |> outcomes(evaluations, policy)
    |> failures(candidate_id)
    |> then(&reaction_norm_evidence(candidate_id, &1))
  end

  @doc """
  Cross-lineage evidence: for each development case the target failed, one
  other listed candidate that was evaluated on the same case. A succeeding
  reference is preferred, ties broken by lowest candidate id; a failing
  reference is used only when nobody succeeded and is flagged. Eligible when at
  least one pair exists. Pairs are sorted by case id.
  """
  @spec cross_lineage(
          plan :: Plan.t(),
          candidate_id :: String.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: {:ok, evidence()} | :ineligible
  def cross_lineage(%Plan{} = plan, candidate_id, candidates, evaluations, policy)
      when is_binary(candidate_id) and is_list(candidates) do
    outcomes = outcomes(plan, evaluations, policy)
    cross_lineage_evidence(candidate_id, failures(outcomes, candidate_id), candidates, outcomes)
  end

  @doc """
  Every operator the proposer may apply to the candidate, each with its
  evidence, in the fixed order clonal, reaction_norm, cross_lineage,
  consolidate. Clonal needs one development failure, the comparative operators
  need their evidence, and consolidate is a policy switch independent of the
  candidate's outcomes.
  """
  @spec eligible_operators(
          plan :: Plan.t(),
          candidate_id :: String.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: [{operator(), evidence()}]
  def eligible_operators(%Plan{} = plan, candidate_id, candidates, evaluations, policy)
      when is_binary(candidate_id) and is_list(candidates) do
    outcomes = outcomes(plan, evaluations, policy)
    failed = failures(outcomes, candidate_id)

    [
      clonal_evidence(candidate_id, failed),
      reaction_norm_evidence(candidate_id, failed),
      cross_lineage_evidence(candidate_id, failed, candidates, outcomes),
      consolidate_evidence(candidate_id, policy)
    ]
    |> Enum.flat_map(fn
      {:ok, %{"operator" => operator} = evidence} -> [{operator, evidence}]
      :ineligible -> []
    end)
  end

  @doc """
  Draws one eligible operator with probability proportional to
  `policy["operator_weights"]`, threading the `:rand` state so the draw is
  reproducible. An operator without a positive weight is excluded; when nothing
  is left the state is returned untouched with `:none`.
  """
  @spec select_operator(
          eligible :: [{operator(), evidence()}],
          policy :: Policy.t(),
          rng :: :rand.state()
        ) :: {{operator(), evidence()}, :rand.state()} | {:none, :rand.state()}
  def select_operator(eligible, policy, rng) when is_list(eligible) and is_map(policy) do
    weights = operator_weights(policy)

    weighted =
      Enum.flat_map(eligible, fn {operator, _evidence} = choice ->
        case Map.get(weights, operator) do
          weight when is_number(weight) and weight > 0 -> [{choice, weight}]
          _unweighted -> []
        end
      end)

    draw(
      weighted,
      Enum.reduce(weighted, 0, fn {_choice, weight}, total -> total + weight end),
      rng
    )
  end

  @doc """
  Proposals and frontier members per `mutation_kind`, so a host can see which
  operators earn their weight instead of trusting the defaults.
  """
  @spec acceptance_by_operator(candidates :: [Candidate.t()], frontier :: Frontier.t()) ::
          %{operator() => %{String.t() => non_neg_integer()}}
  def acceptance_by_operator(candidates, %Frontier{} = frontier) when is_list(candidates) do
    members = MapSet.new(frontier.members, & &1["candidate_id"])

    candidates
    |> Enum.group_by(& &1.mutation_kind)
    |> Map.new(fn {operator, proposed} ->
      {operator,
       %{
         "proposed" => length(proposed),
         "frontier_members" => Enum.count(proposed, &MapSet.member?(members, &1.id))
       }}
    end)
  end

  defp case_outcomes(evaluations, policy) do
    evaluations
    |> Enum.group_by(& &1.case_id)
    |> Map.new(fn {case_id, observed} ->
      {case_id,
       %{
         "success" => Enum.all?(observed, &Policy.success?(&1, policy)),
         "evaluation_id" => List.last(observed).id
       }}
    end)
  end

  # Failed development cases as `{case_id, outcome}` pairs sorted by case id.
  defp failures(outcomes, candidate_id) do
    outcomes
    |> Map.get(candidate_id, %{})
    |> Enum.reject(fn {_case_id, outcome} -> outcome["success"] end)
    |> Enum.sort_by(fn {case_id, _outcome} -> case_id end)
  end

  defp clonal_evidence(_candidate_id, []), do: :ineligible

  defp clonal_evidence(candidate_id, failed),
    do: {:ok, failure_evidence("clonal", candidate_id, failed)}

  defp reaction_norm_evidence(candidate_id, [_first, _second | _rest] = failed),
    do: {:ok, failure_evidence("reaction_norm", candidate_id, failed)}

  defp reaction_norm_evidence(_candidate_id, _fewer), do: :ineligible

  defp failure_evidence(operator, candidate_id, failed) do
    %{
      "operator" => operator,
      "candidate_id" => candidate_id,
      "failed_case_ids" => Enum.map(failed, fn {case_id, _outcome} -> case_id end),
      "evaluation_ids" => Enum.map(failed, fn {_case_id, outcome} -> outcome["evaluation_id"] end)
    }
  end

  defp cross_lineage_evidence(candidate_id, failed, candidates, outcomes) do
    references =
      candidates
      |> Enum.map(& &1.id)
      |> Enum.reject(&(&1 == candidate_id))
      |> Enum.sort()

    case Enum.flat_map(failed, &contrast_pair(&1, references, outcomes)) do
      [] ->
        :ineligible

      pairs ->
        {:ok, %{"operator" => "cross_lineage", "candidate_id" => candidate_id, "pairs" => pairs}}
    end
  end

  # `references` is sorted by id, so the first succeeding reference is the
  # lowest succeeding id and the first reference overall is the lowest id seen.
  defp contrast_pair({case_id, target}, references, outcomes) do
    seen =
      Enum.flat_map(references, fn reference_id ->
        case get_in(outcomes, [reference_id, case_id]) do
          nil -> []
          outcome -> [{reference_id, outcome}]
        end
      end)

    case Enum.find(seen, fn {_reference_id, outcome} -> outcome["success"] end) ||
           List.first(seen) do
      nil ->
        []

      {reference_id, reference} ->
        [
          %{
            "case_id" => case_id,
            "target_evaluation_id" => target["evaluation_id"],
            "reference_candidate_id" => reference_id,
            "reference_evaluation_id" => reference["evaluation_id"],
            "reference_success" => reference["success"]
          }
        ]
    end
  end

  defp consolidate_evidence(candidate_id, %{"consolidate_enabled" => true}),
    do: {:ok, %{"operator" => "consolidate", "candidate_id" => candidate_id}}

  defp consolidate_evidence(_candidate_id, _policy), do: :ineligible

  defp operator_weights(%{"operator_weights" => weights}) when is_map(weights), do: weights
  defp operator_weights(_policy), do: %{}

  defp draw([], _total, rng), do: {:none, rng}

  defp draw(weighted, total, rng) do
    {uniform, rng} = :rand.uniform_s(rng)
    {pick(weighted, uniform * total), rng}
  end

  # The last choice absorbs whatever floating-point slack the subtraction leaves.
  defp pick([{choice, _weight}], _point), do: choice
  defp pick([{choice, weight} | _rest], point) when point < weight, do: choice
  defp pick([{_choice, weight} | rest], point), do: pick(rest, point - weight)
end
