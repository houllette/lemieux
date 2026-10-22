defmodule Lemieux.Learning.Qualification.Paired do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Fixed-sample exact inference for independent paired binary stream outcomes.

  A stream, including its learning history, is one experimental unit. Related
  tasks and repetitions are collapsed before this module sees an outcome. The
  exact one-sided McNemar test conditions on discordant streams; it tests equal
  win/loss probabilities, not a particular percentage-point improvement. The
  effect threshold is a separate, preregistered practical acceptance condition.
  The interval describes the win probability *among discordant streams*, not
  the success-rate difference. This distinction prevents a narrow conditional
  interval being misreported as certainty about absolute task improvement.

  Power integrates the same exact rejection rule over the preregistered
  multinomial win/loss/tie model. Its assumptions are predictions, not evidence.
  No asymptotic approximation or additional dependency is needed.
  """

  @spec compare(pairs :: [{boolean(), boolean()}], alpha :: float()) :: map()
  def compare(pairs, alpha) do
    wins = Enum.count(pairs, &(&1 == {false, true}))
    losses = Enum.count(pairs, &(&1 == {true, false}))
    discordant = wins + losses

    %{
      "clusters" => length(pairs),
      "wins" => wins,
      "regressions" => losses,
      "ties" => length(pairs) - discordant,
      "effect" => (wins - losses) / length(pairs),
      "regression_rate" => losses / length(pairs),
      "p_value" => tail(discordant, wins, 0.5),
      "alpha_per_comparison" => alpha,
      "discordant_win_probability_interval" => interval(wins, discordant, alpha),
      "interval_estimand" => "win_probability_conditional_on_discordance",
      "method" => "exact_one_sided_mcnemar_independent_streams"
    }
  end

  @spec power(clusters :: pos_integer(), assumptions :: map(), alpha :: float()) :: map()
  def power(clusters, assumptions, alpha) do
    discordance = assumptions["win_probability"] + assumptions["loss_probability"]
    conditional = assumptions["win_probability"] / discordance
    minimum_effect = assumptions["minimum_effect"]
    maximum_loss = floor(assumptions["maximum_regression_rate"] * clusters)

    probability =
      distribution(clusters, discordance)
      |> Enum.with_index()
      |> Enum.reduce(0.0, fn {mass, d}, acc ->
        threshold =
          Enum.max([
            critical(d, alpha),
            ceil((minimum_effect * clusters + d) / 2 - 1.0e-12),
            d - maximum_loss
          ])

        acc + mass * tail(d, threshold, conditional)
      end)

    %{
      "clusters" => clusters,
      "per_comparison" => probability,
      "both_primary_lower_bound" => max(0.0, 2 * probability - 1),
      "assumptions" => assumptions,
      "method" => "exact_multinomial_union_bound_two_primary_tests"
    }
  end

  defp critical(n, alpha) do
    distribution(n, 0.5)
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({n + 1, 0.0}, fn {mass, k}, {threshold, sum} ->
      next = sum + mass
      if next <= alpha, do: {:cont, {k, next}}, else: {:halt, {threshold, next}}
    end)
    |> elem(0)
  end

  defp interval(_wins, 0, _alpha), do: [0.0, 1.0]

  defp interval(wins, n, alpha) do
    lower = if wins == 0, do: 0.0, else: quantile(n, wins, alpha / 2)
    upper = if wins == n, do: 1.0, else: 1 - quantile(n, n - wins, alpha / 2)
    [lower, upper]
  end

  defp quantile(n, k, probability) do
    {low, high} =
      Enum.reduce(1..50, {0.0, 1.0}, fn _, {low, high} ->
        mid = (low + high) / 2
        if tail(n, k, mid) < probability, do: {mid, high}, else: {low, mid}
      end)

    (low + high) / 2
  end

  defp tail(_n, k, _p) when k <= 0, do: 1.0
  defp tail(n, k, _p) when k > n, do: 0.0
  defp tail(n, k, p), do: distribution(n, p) |> Enum.drop(k) |> Enum.sum() |> min(1.0)

  defp distribution(0, _p), do: [1.0]

  defp distribution(n, p) do
    {values, _log_combination} =
      Enum.map_reduce(0..n, 0.0, fn k, log_combination ->
        mass = :math.exp(log_combination + k * :math.log(p) + (n - k) * :math.log(1 - p))

        next =
          if k == n,
            do: log_combination,
            else: log_combination + :math.log(n - k) - :math.log(k + 1)

        {mass, next}
      end)

    values
  end
end
