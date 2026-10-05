defmodule Lemieux.Learning.Discovery.Policy do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Search policy for one discovery plan, read from `plan.extensions["search"]`.

  The discovery contracts (`Plan`, `Candidate`, `Evaluation`, `State`,
  `Frontier`) are digest-verified wire objects shared with hosts. Search
  policy — which objective counts as success, how parents are sampled, how
  many cases a first evaluation uses — is deliberately not a new contract
  field: it lives in the plan's free-form `extensions` map, so a plan that
  says nothing keeps its bytes and its digest, and a plan that opts in freezes
  its search policy under the same digest as everything else the proposer is
  allowed to see.

  Every reader of the policy goes through `read/2` so the defaults are stated
  once. Success is a threshold on one declared objective, not on a blend: a
  candidate that is cheaper but fails more is not "half successful", and the
  frontier's Pareto comparison already keeps cost visible without letting it
  compensate for a failed case.

  ## Repeated attempts

  Model behaviour is random, so one run of a case is one sample of it. Two
  live cycles in a row had the same seed profile fail
  `refuse-purge-customer-records` once and pass it the next time, which let a
  single run decide whether an edit was "safe". `"attempts"` (default 1) is
  how many times every development case runs per evaluation and
  `"always_attempts"` (default: the same) overrides it for the
  `"always_case_ids"`, so a plan can repeat only its safety-critical cases.
  A case counts as solved only when **every** attempt succeeds:
  `Lemieux.Learning.Discovery.Comparison.outcomes/3`, the frontier's
  `no_solved_regression` gate and the campaign report all apply that rule,
  and the frontier's eligibility gate already fails a candidate on one
  unsafe attempt. Repeats multiply cost and time in proportion; nothing
  beyond the plan's token, cost and time budget bounds them, so a policy
  that repeats every case should shrink its tiers or candidate budget to
  match.
  """

  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan

  @type t :: %{required(String.t()) => term()}

  @defaults %{
    "success_objective" => nil,
    "success_threshold" => 1.0,
    "widening_alpha" => 0.5,
    "failed_case_weight" => 3.0,
    "fidelity_tiers" => nil,
    "always_case_ids" => [],
    "attempts" => 1,
    "always_attempts" => nil,
    "prior" => [1, 1],
    "clade" => true,
    "seed" => 0,
    "operator_weights" => %{
      "clonal" => 1.0,
      "reaction_norm" => 1.0,
      "cross_lineage" => 1.0,
      "consolidate" => 0.5
    },
    "consolidate_enabled" => false
  }

  @doc "Returns the default policy values before any plan or caller override."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc """
  Resolves the effective policy: defaults, then `plan.extensions["search"]`,
  then caller overrides. The success objective defaults to the plan's first
  maximized objective; fidelity tiers default to one tier covering every
  development case; an attempt count that is not a positive integer is
  treated as unset.
  """
  @spec read(plan :: Plan.t(), overrides :: map()) :: t()
  def read(%Plan{} = plan, overrides \\ %{}) when is_map(overrides) do
    declared = Map.get(plan.extensions, "search", %{})
    declared = if is_map(declared), do: declared, else: %{}

    policy =
      @defaults
      |> Map.merge(declared)
      |> Map.merge(overrides)

    policy
    |> Map.update!("success_objective", &(&1 || default_objective(plan)))
    |> Map.update!("fidelity_tiers", &normalize_tiers(&1, length(plan.development_case_ids)))
    |> Map.update!("attempts", &normalize_attempts(&1, 1))
    |> Map.update!("always_attempts", &normalize_attempts(&1, nil))
  end

  @doc """
  How many times one evaluation runs `case_id`: `"always_attempts"` for a
  case in `"always_case_ids"` when the policy sets it, `"attempts"` otherwise.
  """
  @spec attempts(policy :: t(), case_id :: String.t()) :: pos_integer()
  def attempts(policy, case_id) when is_map(policy) and is_binary(case_id) do
    default = normalize_attempts(policy["attempts"], 1)

    if case_id in always_case_ids(policy),
      do: normalize_attempts(policy["always_attempts"], default),
      else: default
  end

  @doc """
  True when the evaluation's success objective reaches the policy threshold
  **and** its hard evidence is valid: terminal, within budget, and safe.

  A grader that passed while the agent wrote outside its allowlist is not a
  success the search may learn from; treating it as one would let the
  proposer optimize toward the very behavior the frontier excludes. The first
  live campaign produced exactly that case, so the rule lives here rather
  than in each caller.
  """
  @spec success?(evaluation :: Evaluation.t(), policy :: t()) :: boolean()
  def success?(%Evaluation{} = evaluation, policy) when is_map(policy) do
    hard_evidence_ok? =
      evaluation.terminal and evaluation.within_budget and
        evaluation.safety["passed"] == true

    case Map.fetch(evaluation.objectives, policy["success_objective"]) do
      {:ok, value} when is_number(value) ->
        hard_evidence_ok? and value >= policy["success_threshold"]

      _missing ->
        false
    end
  end

  @doc "True for evaluations on the proposer-visible development split."
  @spec development?(evaluation :: Evaluation.t()) :: boolean()
  def development?(%Evaluation{split: "development"}), do: true
  def development?(%Evaluation{}), do: false

  defp default_objective(%Plan{objectives: objectives}) do
    case Enum.find(objectives, &(&1["direction"] == "maximize")) || List.first(objectives) do
      %{"name" => name} -> name
      nil -> nil
    end
  end

  defp normalize_tiers(tiers, total) when is_list(tiers) and tiers != [] do
    tiers
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.map(&min(&1, total))
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> [total]
      valid -> if List.last(valid) < total, do: valid ++ [total], else: valid
    end
  end

  defp normalize_tiers(_tiers, total), do: [max(total, 1)]

  defp always_case_ids(%{"always_case_ids" => ids}) when is_list(ids), do: ids
  defp always_case_ids(_policy), do: []

  # A count that is not a positive integer is treated as unset, like a
  # malformed tier list: `read/2` has no error path, and a search that ran
  # zero attempts would record no evidence while looking as if it had run.
  defp normalize_attempts(count, _default) when is_integer(count) and count > 0, do: count
  defp normalize_attempts(_count, default), do: default
end
