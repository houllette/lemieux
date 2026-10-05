defmodule Lemieux.Experiment.Decision do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Lexicographic experiment decisions with paired uncertainty.

  Safety and critical regressions are hard failures. Only after those gates
  pass does the declared held-out primary effect decide pass/fail/inconclusive;
  cost and latency are retained as secondary evidence and never compensate for
  unsafe behavior.

  ## Two verdict lanes, one gate order

  Under the fixed-n rule (`%{"minimum_pairs", "confidence"}`) the verdict is a
  normal-approximation interval over the paired holdout differences,
  deliberately small and dependency-free for the first bounded experiment
  lane. That interval is only honest if the sample size was fixed in advance:
  reading it after every new pair and stopping at the first favorable one is
  adaptive multiple testing, and PACE (arXiv 2606.08106) measured greedy
  "keep if it scored higher" acceptance committing 13–21 spurious edits per
  run.

  Under the `e_process` rule the interval is still reported (at `1 - alpha`,
  so the two lanes read alike), but the verdict comes from two Hoeffding test
  supermartingales over the paired differences `d_i = variant - control`, with
  `R = hi - lo` the declared range, `δ` the plan's minimum effect and `λ` the
  bet:

      E⁺ = ∏ exp(λ (d_i − δ) − λ² R² / 8)   against H0: μ ≤ δ  (no real improvement)
      E⁻ = ∏ exp(λ (δ − d_i) − λ² R² / 8)   against H0: μ ≥ δ  (improvement of at least δ)

  Each is a nonnegative supermartingale starting at 1 under its null, so by
  Ville's inequality `P(sup E ≥ 1/α) ≤ α` at *every* stopping time. A host may
  stop the moment `E⁺ ≥ 1/α` (commit) or `E⁻ ≥ 1/α` (reject), or keep
  sampling, and the false-commit rate stays at `α`. Both products are
  accumulated in log space and compared there, so a long run of decisive pairs
  cannot overflow a float before the verdict is read; the reported e-values
  are the exponentials, clamped only where a float could not hold them.

  `λ` is fixed for the whole run: the plan's `"lambda"` if declared, otherwise
  `min(4δ / R², 1 / R)` (the Hoeffding-optimal bet if the true effect were
  `2δ`, capped so the bet never exceeds the range), or `1 / R` when `δ ≤ 0`.
  A fixed `λ` is a valid but conservative bet: it wastes evidence when the
  true effect sits far from the one it was tuned for. A predictable plug-in
  (`λ_i` chosen from `d_1..d_{i-1}`) keeps validity and would recover that
  power. It can replace this choice later without changing the
  preregistration, because the plan only fixes the rule kind, `α`, the range,
  the minimum sample, and optionally `λ` itself.
  """

  alias Lemieux.Experiment.Plan

  # Past this exponent a float overflows and `:math.exp/1` raises. Evidence
  # beyond it is decisive at any α a plan can declare, so clamping the
  # reported e-value loses nothing the verdict needs.
  @max_log_e_value 700.0

  @type verdict :: :pass | :fail | :inconclusive | :safety_failure | :critical_regression
  @type t :: %__MODULE__{
          verdict: verdict(),
          reason: atom(),
          development: map(),
          holdout: map(),
          safety_failures: list(),
          critical_regressions: list()
        }

  @enforce_keys [
    :verdict,
    :reason,
    :development,
    :holdout,
    :safety_failures,
    :critical_regressions
  ]
  defstruct [
    :verdict,
    :reason,
    :development,
    :holdout,
    safety_failures: [],
    critical_regressions: []
  ]

  @doc """
  Evaluates evidence under a frozen plan.

  The holdout summary always carries `count`, `effect`, `standard_error` and
  `interval`. Under an `e_process` rule it additionally carries an
  `"e_process"` map with the two e-values (`"improvement"`,
  `"no_improvement"`), their logs, the `"threshold"` `1 / alpha`, the
  `"lambda"` actually bet, and the number of `"pairs"` they were accumulated
  over, so a report can show why the run stopped or kept going.
  """
  @spec evaluate(plan :: Plan.t(), evidence :: map()) :: {:ok, t()} | {:error, term()}
  def evaluate(%Plan{} = plan, evidence) when is_map(evidence) do
    with {:ok, development} <- summarize(Map.get(evidence, "development", []), plan),
         {:ok, holdout} <- summarize(Map.get(evidence, "holdout", []), plan) do
      safety = Map.get(evidence, "safety_failures", [])
      regressions = Map.get(evidence, "critical_regressions", [])
      {verdict, reason} = verdict(safety, regressions, holdout, plan)

      {:ok,
       %__MODULE__{
         verdict: verdict,
         reason: reason,
         development: development,
         holdout: holdout,
         safety_failures: safety,
         critical_regressions: regressions
       }}
    end
  end

  defp verdict([_ | _], _regressions, _holdout, _plan),
    do: {:safety_failure, :safety_failure}

  defp verdict([], [_ | _], _holdout, _plan),
    do: {:critical_regression, :critical_regression}

  defp verdict([], [], %{count: count} = holdout, %Plan{
         stopping_rule: %{"kind" => "e_process"} = rule
       }) do
    e_process = holdout["e_process"]
    log_threshold = -:math.log(rule["alpha"])

    cond do
      count < rule["minimum_pairs"] -> {:inconclusive, :minimum_sample_not_met}
      e_process["log_improvement"] >= log_threshold -> {:pass, :e_process_commit}
      e_process["log_no_improvement"] >= log_threshold -> {:fail, :e_process_reject}
      true -> {:inconclusive, :e_process_continue}
    end
  end

  defp verdict([], [], %{count: count, interval: %{lower: lower, upper: upper}}, plan) do
    minimum_pairs = plan.stopping_rule["minimum_pairs"]
    minimum = plan.metric["minimum_effect"]

    cond do
      count < minimum_pairs -> {:inconclusive, :minimum_sample_not_met}
      lower >= minimum -> {:pass, :minimum_effect_met}
      upper < minimum -> {:fail, :minimum_effect_unreachable}
      true -> {:inconclusive, :uncertainty_crosses_threshold}
    end
  end

  defp summarize(pairs, %Plan{} = plan) when is_list(pairs) do
    with {:ok, differences} <- differences(pairs, plan.metric["kind"]),
         :ok <- within_range(differences, plan.stopping_rule) do
      count = length(differences)
      effect = mean(differences)
      standard_error = standard_error(differences, effect)
      confidence = confidence(plan.stopping_rule)
      z = z_score(confidence)

      summary = %{
        count: count,
        effect: effect,
        standard_error: standard_error,
        interval: %{
          lower: effect - z * standard_error,
          upper: effect + z * standard_error,
          confidence: confidence
        }
      }

      {:ok, put_e_process(summary, differences, plan)}
    end
  end

  defp confidence(%{"kind" => "e_process", "alpha" => alpha}), do: 1 - alpha
  defp confidence(%{"confidence" => confidence}), do: confidence

  # A difference outside the declared range voids the supermartingale
  # guarantee; refusing the evidence is the only honest response, because
  # clamping it would report a bound the data never obeyed.
  defp within_range(differences, %{"kind" => "e_process", "range" => [low, high]}) do
    if Enum.all?(differences, &(&1 >= low and &1 <= high)),
      do: :ok,
      else: {:error, :difference_outside_declared_range}
  end

  defp within_range(_differences, _rule), do: :ok

  defp put_e_process(summary, differences, %Plan{
         stopping_rule: %{"kind" => "e_process"} = rule,
         metric: %{"minimum_effect" => minimum_effect}
       }) do
    Map.put(summary, "e_process", e_process(differences, rule, minimum_effect))
  end

  defp put_e_process(summary, _differences, _plan), do: summary

  defp e_process(differences, rule, minimum_effect) do
    [low, high] = rule["range"]
    range = high - low
    lambda = lambda(rule["lambda"], minimum_effect, range)
    penalty = lambda * lambda * range * range / 8

    log_improvement =
      Enum.reduce(differences, 0.0, &(&2 + lambda * (&1 - minimum_effect) - penalty))

    log_no_improvement =
      Enum.reduce(differences, 0.0, &(&2 + lambda * (minimum_effect - &1) - penalty))

    %{
      "improvement" => bounded_exp(log_improvement),
      "no_improvement" => bounded_exp(log_no_improvement),
      "log_improvement" => log_improvement,
      "log_no_improvement" => log_no_improvement,
      "threshold" => 1 / rule["alpha"],
      "lambda" => lambda,
      "pairs" => length(differences)
    }
  end

  defp lambda(fixed, _minimum_effect, _range) when is_number(fixed), do: fixed
  defp lambda(nil, minimum_effect, range) when minimum_effect <= 0, do: 1 / range

  defp lambda(nil, minimum_effect, range),
    do: min(4 * minimum_effect / (range * range), 1 / range)

  defp bounded_exp(log_value), do: :math.exp(min(log_value, @max_log_e_value))

  defp differences(pairs, "binary") do
    values =
      Enum.map(pairs, fn
        %{"control" => control, "variant" => variant}
        when is_boolean(control) and is_boolean(variant) ->
          numeric(variant) - numeric(control)

        _invalid ->
          :invalid
      end)

    if :invalid in values, do: {:error, :invalid_binary_pair}, else: {:ok, values}
  end

  defp differences(pairs, "continuous") do
    values =
      Enum.map(pairs, fn
        %{"control" => control, "variant" => variant}
        when is_number(control) and is_number(variant) ->
          variant - control

        _invalid ->
          :invalid
      end)

    if :invalid in values, do: {:error, :invalid_continuous_pair}, else: {:ok, values}
  end

  defp numeric(true), do: 1.0
  defp numeric(false), do: 0.0

  defp mean([]), do: 0.0
  defp mean(values), do: Enum.sum(values) / length(values)

  defp standard_error(values, _mean) when length(values) < 2, do: 0.0

  defp standard_error(values, mean) do
    variance = Enum.sum(Enum.map(values, &:math.pow(&1 - mean, 2))) / (length(values) - 1)
    :math.sqrt(variance / length(values))
  end

  # The first implementation accepts arbitrary declared confidence while using
  # the common normal critical values. Exact/bootstrap methods can replace this
  # summary without changing the preregistration or gate ordering.
  defp z_score(confidence) when confidence >= 0.99, do: 2.576
  defp z_score(confidence) when confidence >= 0.95, do: 1.96
  defp z_score(confidence) when confidence >= 0.90, do: 1.645
  defp z_score(_confidence), do: 1.282
end
