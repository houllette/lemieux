defmodule Lemieux.Learning.Qualification.Endpoints do
  @moduledoc """
  **Experimental.** Not part of the stable public API.

  Explicitly registered quality and efficiency endpoints for research studies.

  Historical qualification decisions remain unchanged. This supplement runs
  only when its exact policy is frozen in the runtime before dispatch. Quality
  tests confirmation success against disabled execution and equal-allowance
  retries and an otherwise matched improver with its experience withheld.
  Efficiency additionally requires paired successful streams, fewer
  total physical requests including all acquisition/search/reflection work,
  and a conservative upper bound on quality regression. It cannot turn cheap
  failures into an efficiency gain. Six primary tests share one alpha budget.

  Related tasks and repetitions remain one stream. A declared stream is an
  independence assumption, not proof; exposed or synthetic development data
  cannot establish independent real-repository generalization.
  """
  alias Lemieux.Contract
  alias Lemieux.Learning.Qualification
  alias Lemieux.Learning.Qualification.Paired

  @policy %{
    "id" => "separate_quality_efficiency/v1",
    "minimum_request_saving" => 0.2,
    "minimum_paired_success_fraction" => 0.8,
    "maximum_quality_regression" => 0.1,
    "primary_tests" => 6
  }

  @spec policy() :: map()
  def policy, do: @policy

  @doc "Checks power for the three registered quality comparisons before independent confirmation dispatch."
  @spec preflight(plan :: map()) :: :ok | {:error, term()}
  def preflight(plan) do
    with :ok <- Qualification.verify(plan),
         true <- get_in(plan, ["runtime", "research_protocol", "endpoints"]) == @policy,
         true <- plan["ablation"] == "withheld_proposer_experience/v1",
         true <- powered?(plan) do
      :ok
    else
      _invalid -> {:error, :unregistered_or_underpowered_endpoints}
    end
  end

  @spec report(plan :: map(), rows :: [map()]) :: {:ok, map()} | {:error, term()}
  def report(plan, rows) do
    with :ok <- preflight(plan),
         {:ok, ordinary} <- Qualification.report(plan, rows),
         true <- is_map(plan["analysis"]),
         {:ok, seeds} <- seed_requests(plan) do
      streams = stream_rows(plan, rows)

      comparisons =
        Map.new(~w(disabled retry no_experience), fn arm ->
          {arm, compare(streams, arm, seeds, plan)}
        end)

      mechanism = mechanism?(ordinary)
      complete = ordinary["mechanics"] == "passed" and mechanism

      quality? =
        complete and
          Enum.all?(comparisons, fn {_arm, comparison} -> comparison["quality_supported"] end)

      efficiency? =
        complete and
          Enum.all?(comparisons, fn {_arm, comparison} -> comparison["efficiency_supported"] end)

      result = %{
        "schema_version" => 1,
        "kind" => "research_endpoints",
        "plan_sha256" => plan["sha256"],
        "policy" => @policy,
        "mechanics" => ordinary["mechanics"],
        "mechanism_exercised" => mechanism,
        "quality_power" => quality_power(plan),
        "efficiency_power" => "not_estimated_no_quality_power_claim_for_efficiency",
        "comparisons" => comparisons,
        "quality" => verdict(quality?),
        "efficiency" => verdict(efficiency?),
        "independent_confirmation" => plan["claim"] == "independent_confirmation",
        "interpretation" => "conditional_on_registered_scope_not_a_cross_domain_or_release_claim"
      }

      {:ok, Map.put(result, "sha256", Contract.digest(result))}
    else
      _invalid -> {:error, :unregistered_or_incomplete_research_endpoints}
    end
  end

  defp mechanism?(report) do
    updating = report["arms"]["updating"]

    profile =
      updating["candidate_count"] > 0 and updating["promotion_count"] > 0 and
        updating["promotion_count"] == updating["rollback_count"]

    assets =
      updating["asset_candidate_count"] > 0 and updating["asset_application_count"] > 0 and
        updating["asset_application_count"] == updating["asset_restoration_count"]

    profile or assets
  end

  defp powered?(%{"claim" => "independent_confirmation"} = plan) do
    quality_power(plan)["all_three_lower_bound"] >= plan["analysis"]["desired_power"]
  end

  defp powered?(_development), do: true

  defp quality_power(plan) do
    n = plan["tasks"] |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> length()

    power = Paired.power(n, plan["analysis"], plan["alpha"] / @policy["primary_tests"])

    power
    |> Map.drop(["both_primary_lower_bound"])
    |> Map.put("method", "exact_multinomial_union_bound_three_quality_tests")
    |> Map.put("all_three_lower_bound", max(0.0, 3 * power["per_comparison"] - 2))
    |> Map.put("alpha_per_test", plan["alpha"] / @policy["primary_tests"])
  end

  defp seed_requests(plan) do
    clusters = plan["tasks"] |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> Enum.sort()
    seeds = get_in(plan, ["runtime", "seed_usage", "requests_by_stream"])

    if is_map(seeds) and Enum.sort(Map.keys(seeds)) == clusters and
         valid_seed_counts?(seeds, plan),
       do: {:ok, seeds},
       else: {:error, :seed_accounting_required}
  end

  defp valid_seed_counts?(seeds, plan),
    do:
      Enum.all?(seeds, fn {_stream, value} -> is_integer(value) and value >= 0 end) and
        Enum.sum(Map.values(seeds)) == get_in(plan, ["runtime", "seed_usage", "requests"])

  defp stream_rows(plan, rows) do
    tasks = Map.new(plan["tasks"], &{&1["id"], &1})

    rows
    |> Enum.group_by(&tasks[&1["task_id"]]["cluster"])
    |> Enum.map(fn {id, chosen} ->
      {id,
       Map.new(Enum.group_by(chosen, & &1["arm"]), fn {arm, values} ->
         confirmation = Enum.filter(values, &(tasks[&1["task_id"]]["phase"] == "confirmation"))

         {arm,
          %{
            "passed" => Enum.all?(confirmation, & &1["passed"]),
            "requests" => Enum.sum(Enum.map(values, & &1["requests"]))
          }}
       end)}
    end)
  end

  defp compare(streams, arm, seeds, plan) do
    alpha = plan["alpha"] / @policy["primary_tests"]

    quality_pairs =
      Enum.map(streams, fn {_id, values} ->
        {values[arm]["passed"], values["updating"]["passed"]}
      end)

    quality = Paired.compare(quality_pairs, alpha)

    efficient =
      Enum.map(streams, fn {id, values} ->
        efficiency_pair(values[arm], values["updating"], seeds[id])
      end)

    efficiency = Paired.compare(efficient, alpha)
    eligible = Enum.count(quality_pairs, &(&1 == {true, true})) / length(streams)
    regression_upper = upper_bound(quality["regressions"], length(streams), alpha)
    total_control = Enum.sum(Enum.map(streams, fn {_id, values} -> values[arm]["requests"] end))

    total_candidate =
      Enum.sum(
        Enum.map(streams, fn {id, values} -> values["updating"]["requests"] + seeds[id] end)
      )

    saving = 1 - total_candidate / max(1, total_control)

    %{
      "quality" => quality,
      "efficiency" => efficiency,
      "paired_success_fraction" => eligible,
      "quality_regression_upper_bound" => regression_upper,
      "total_request_saving" => saving,
      "candidate_requests_including_acquisition" => total_candidate,
      "control_requests" => total_control,
      "quality_supported" =>
        quality["effect"] >= plan["analysis"]["minimum_effect"] and
          quality["regression_rate"] <= plan["analysis"]["maximum_regression_rate"] and
          quality["p_value"] <= alpha,
      "efficiency_supported" =>
        eligible >= @policy["minimum_paired_success_fraction"] and
          regression_upper <= @policy["maximum_quality_regression"] and
          saving >= @policy["minimum_request_saving"] and efficiency["p_value"] <= alpha
    }
  end

  defp efficiency_pair(
         %{"passed" => true} = control,
         %{"passed" => true} = candidate,
         acquisition
       ) do
    requests = candidate["requests"] + acquisition

    cond do
      requests <= control["requests"] * (1 - @policy["minimum_request_saving"]) -> {false, true}
      requests > control["requests"] -> {true, false}
      true -> {false, false}
    end
  end

  defp efficiency_pair(%{"passed" => true}, %{"passed" => false}, _acquisition), do: {true, false}
  defp efficiency_pair(_control, _candidate, _acquisition), do: {false, false}

  # Exact one-sided binomial upper bound for the marginal probability of a
  # quality regression. Zero observed regressions in a tiny pilot is not enough.
  defp upper_bound(losses, n, _alpha) when losses == n, do: 1.0
  defp upper_bound(0, n, alpha), do: 1 - :math.pow(alpha, 1 / n)

  defp upper_bound(losses, n, alpha) do
    {low, high} =
      Enum.reduce(1..50, {0.0, 1.0}, fn _, {low, high} ->
        mid = (low + high) / 2
        if binomial_cdf(n, losses, mid) > alpha, do: {mid, high}, else: {low, mid}
      end)

    (low + high) / 2
  end

  defp binomial_cdf(n, maximum, probability) do
    {terms, _} =
      Enum.map_reduce(0..maximum, 0.0, fn k, log_combination ->
        mass =
          :math.exp(
            log_combination + k * :math.log(probability) + (n - k) * :math.log(1 - probability)
          )

        {mass, log_combination + :math.log(n - k) - :math.log(k + 1)}
      end)

    Enum.sum(terms)
  end

  defp verdict(true), do: "supported_in_registered_scope"
  defp verdict(false), do: "inconclusive"
end
