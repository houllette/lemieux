defmodule Lemieux.Learning.Discovery.Calibration do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Scores the proposer's predictions, not the harness's scores.

  Agentic Harness Engineering (arXiv 2604.25850) pairs every edit with a
  falsifiable prediction — which cases it fixes, which it puts at risk — and
  "Harness Updating Is Not Harness Benefit" (arXiv 2605.30621) finds that the
  capability limiting self-improvement is judging which candidate is better,
  not producing candidates. Frontier deltas alone cannot show whether that
  judgment is improving: an edit that helped by accident and one whose author
  understood the defect look identical on the frontier, so a proposer that is
  getting luckier is indistinguishable from one that is getting better.
  Comparing each prediction with what the candidate actually did to its
  parent's development outcomes is what separates the two.

  Predictions live in `candidate.extensions["prediction"]` rather than in a
  new contract field for the same reason search policy lives in
  `plan.extensions["search"]`: a proposer that makes none keeps its bytes and
  its digest. An unpredicted candidate is still scored on the Brier rule under
  the "nothing changes" baseline — every compared case is forecast to keep its
  parent's outcome — so a proposer that stops predicting cannot look better by
  dropping out of the aggregate; it only flips the summary to
  `"uncalibrated"`. Precision and recall are `nil` rather than `0.0` when
  their denominator is empty, because "predicted no fixes and none happened"
  is not a miss, and averaging it as one would punish the honest prediction.

  Only the first parent is compared, on the development cases both it and the
  candidate were evaluated on. A seed parent or an unevaluated parent has no
  such outcomes and yields `{:error, :no_parent_evidence}` instead of a score
  built on nothing.
  """

  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Comparison
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  @typedoc ~S(A normalized prediction: sorted, de-duplicated case ids under `"fixes"` and `"at_risk"`.)
  @type prediction :: %{required(String.t()) => [String.t()]}

  @typedoc "What actually changed between a candidate and its first parent."
  @type realized :: %{required(String.t()) => String.t() | [String.t()]}

  @typedoc "One candidate's calibration score."
  @type score :: %{required(String.t()) => boolean() | float() | nil | non_neg_integer()}

  @no_change %{"fixes" => [], "at_risk" => []}

  @doc """
  The candidate's prediction with both keys present, or `nil` when the
  candidate carries no `"prediction"` map at all. An empty map is an explicit
  "nothing changes" prediction, which is different from not predicting.
  """
  @spec prediction(candidate :: Candidate.t()) :: prediction() | nil
  def prediction(%Candidate{extensions: %{"prediction" => prediction}}) when is_map(prediction) do
    %{"fixes" => case_ids(prediction["fixes"]), "at_risk" => case_ids(prediction["at_risk"])}
  end

  def prediction(%Candidate{}), do: nil

  @doc """
  Compares the candidate's development outcomes with its first parent's on the
  cases both were evaluated on. `"fixed"` cases the parent failed and the
  candidate solved; `"regressed"` the reverse; `"unchanged"` the rest. Every
  list is sorted.
  """
  @spec realized(
          plan :: Plan.t(),
          candidate :: Candidate.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: {:ok, realized()} | {:error, :no_parent_evidence}
  def realized(%Plan{} = plan, %Candidate{} = candidate, candidates, evaluations, policy)
      when is_list(candidates) do
    realized_from(candidate, candidates, Comparison.outcomes(plan, evaluations, policy))
  end

  @doc """
  Scores one prediction against what was realized.

  Precision and recall are computed over the compared cases only; a predicted
  case nobody evaluated on both sides neither helps nor hurts. Brier error is
  the mean squared distance between the forecast and the outcome over the
  compared cases, where a case in `"fixes"` is forecast solved, a case in
  `"at_risk"` (and not in `"fixes"`) is forecast failed, and every other case
  is forecast to keep its parent's outcome. An unpredicted candidate gets the
  carry-forward Brier score and `nil` precision and recall.
  """
  @spec score(
          candidate :: Candidate.t(),
          realized :: realized(),
          parent_outcomes :: Comparison.candidate_outcomes(),
          candidate_outcomes :: Comparison.candidate_outcomes()
        ) :: score()
  def score(%Candidate{} = candidate, realized, parent_outcomes, candidate_outcomes)
      when is_map(realized) and is_map(parent_outcomes) and is_map(candidate_outcomes) do
    compared = realized["compared_case_ids"]
    prediction = prediction(candidate)
    %{"fixes" => fixes, "at_risk" => at_risk} = prediction || @no_change
    fixes = Enum.filter(fixes, &(&1 in compared))
    at_risk = Enum.filter(at_risk, &(&1 in compared))

    %{
      "predicted" => prediction != nil,
      "fix_precision" => precision(prediction, fixes, realized["fixed"]),
      "fix_recall" => recall(prediction, fixes, realized["fixed"]),
      "risk_precision" => precision(prediction, at_risk, realized["regressed"]),
      "risk_recall" => recall(prediction, at_risk, realized["regressed"]),
      "brier" => brier(compared, fixes, at_risk, parent_outcomes, candidate_outcomes),
      "compared" => length(compared)
    }
  end

  @doc """
  Calibration for every candidate under one plan. Candidates without parent
  evidence appear as `%{"error" => "no_parent_evidence"}`; means skip `nil`
  entries and errors; the status is `"uncalibrated"` when no candidate carries
  a prediction.
  """
  @spec summarize(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: map()
  def summarize(%Plan{} = plan, candidates, evaluations, policy) when is_list(candidates) do
    outcomes = Comparison.outcomes(plan, evaluations, policy)
    scored = Map.new(candidates, &{&1.id, score_or_error(&1, candidates, outcomes)})
    predicted = Enum.count(candidates, &(prediction(&1) != nil))

    %{
      "status" => if(predicted > 0, do: "calibrated", else: "uncalibrated"),
      "candidates" => scored,
      "aggregate" => %{
        "predicted_candidates" => predicted,
        "unpredicted_candidates" => length(candidates) - predicted,
        "mean_brier" => mean(scored, "brier"),
        "mean_fix_precision" => mean(scored, "fix_precision"),
        "mean_fix_recall" => mean(scored, "fix_recall"),
        "mean_risk_precision" => mean(scored, "risk_precision"),
        "mean_risk_recall" => mean(scored, "risk_recall")
      }
    }
  end

  defp case_ids(value) when is_list(value),
    do: value |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()

  defp case_ids(_value), do: []

  defp realized_from(candidate, candidates, outcomes) do
    with {:ok, parent_id} <- first_parent(candidate, candidates),
         {:ok, parent_outcomes} <- evaluated(outcomes, parent_id) do
      {:ok, compare(parent_id, parent_outcomes, Map.get(outcomes, candidate.id, %{}))}
    end
  end

  defp first_parent(%Candidate{parents: [%{"id" => parent_id} | _rest]}, candidates) do
    if Enum.any?(candidates, &(&1.id == parent_id)),
      do: {:ok, parent_id},
      else: {:error, :no_parent_evidence}
  end

  defp first_parent(_candidate, _candidates), do: {:error, :no_parent_evidence}

  defp evaluated(outcomes, parent_id) do
    case Map.get(outcomes, parent_id) do
      parent_outcomes when is_map(parent_outcomes) and map_size(parent_outcomes) > 0 ->
        {:ok, parent_outcomes}

      _unevaluated ->
        {:error, :no_parent_evidence}
    end
  end

  defp compare(parent_id, parent_outcomes, candidate_outcomes) do
    compared =
      parent_outcomes
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(candidate_outcomes, &1))
      |> Enum.sort()

    grouped =
      Enum.group_by(compared, fn case_id ->
        transition(parent_outcomes[case_id]["success"], candidate_outcomes[case_id]["success"])
      end)

    %{
      "parent_id" => parent_id,
      "compared_case_ids" => compared,
      "fixed" => Map.get(grouped, :fixed, []),
      "regressed" => Map.get(grouped, :regressed, []),
      "unchanged" => Map.get(grouped, :unchanged, [])
    }
  end

  defp transition(false, true), do: :fixed
  defp transition(true, false), do: :regressed
  defp transition(same, same), do: :unchanged

  defp precision(nil, _predicted, _actual), do: nil
  defp precision(_prediction, [], _actual), do: nil
  defp precision(_prediction, predicted, actual), do: hits(predicted, actual) / length(predicted)

  defp recall(nil, _predicted, _actual), do: nil
  defp recall(_prediction, _predicted, []), do: nil
  defp recall(_prediction, predicted, actual), do: hits(predicted, actual) / length(actual)

  defp hits(predicted, actual), do: Enum.count(predicted, &(&1 in actual))

  defp brier([], _fixes, _at_risk, _parent_outcomes, _candidate_outcomes), do: nil

  defp brier(compared, fixes, at_risk, parent_outcomes, candidate_outcomes) do
    errors =
      Enum.map(compared, fn case_id ->
        forecast = forecast(case_id, fixes, at_risk, parent_outcomes)
        actual = probability(candidate_outcomes[case_id]["success"])
        (forecast - actual) * (forecast - actual)
      end)

    Enum.sum(errors) / length(errors)
  end

  defp forecast(case_id, fixes, at_risk, parent_outcomes) do
    cond do
      case_id in fixes -> 1.0
      case_id in at_risk -> 0.0
      true -> probability(parent_outcomes[case_id]["success"])
    end
  end

  defp probability(true), do: 1.0
  defp probability(_failed), do: 0.0

  defp score_or_error(candidate, candidates, outcomes) do
    case realized_from(candidate, candidates, outcomes) do
      {:ok, realized} ->
        score(
          candidate,
          realized,
          Map.fetch!(outcomes, realized["parent_id"]),
          Map.get(outcomes, candidate.id, %{})
        )

      {:error, reason} ->
        %{"error" => Atom.to_string(reason)}
    end
  end

  defp mean(scored, key) do
    case scored |> Map.values() |> Enum.map(&Map.get(&1, key)) |> Enum.filter(&is_number/1) do
      [] -> nil
      values -> Enum.sum(values) / length(values)
    end
  end
end
