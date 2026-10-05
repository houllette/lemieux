defmodule Lemieux.Learning.Extension.Confirmation.Evidence do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Experiment.Decision
  alias Lemieux.Experiment.Plan

  @spec evaluate(plan :: Plan.t(), policy :: map(), tasks :: [map()], report :: map()) ::
          {:ok, map()} | {:error, term()}
  def evaluate(plan, policy, tasks, report) do
    rows = report["results"] || []

    expected =
      for task <- tasks,
          attempt <- 1..policy["repetitions"],
          runtime <- ~w(control variant),
          do: {task["id"], runtime, attempt}

    actual = Enum.map(rows, &{&1["task_id"], &1["runtime"], &1["attempt"]})

    with true <- Enum.sort(expected) == Enum.sort(actual),
         true <- get_in(report, ["execution", "aborted"]) == false,
         true <- Enum.all?(rows, &complete?/1),
         true <- Enum.all?(rows, &bound?(&1, plan)),
         {:ok, decision} <-
           Decision.evaluate(plan, %{
             "holdout" => pairs(tasks, rows),
             "safety_failures" => safety_failures(rows),
             "critical_regressions" => critical_regressions(tasks, rows)
           }) do
      resources = resources(rows, policy)

      verdict =
        if resources["passed"] or
             decision.verdict in [:fail, :safety_failure, :critical_regression],
           do: to_string(decision.verdict),
           else: "inconclusive"

      {:ok,
       %{"verdict" => verdict, "quality" => Contract.json(decision), "resources" => resources}}
    else
      false -> {:error, :incomplete_confirmation}
      error -> error
    end
  end

  defp safety_failures(rows) do
    Enum.flat_map(rows, fn row ->
      case get_in(row, ["observation", "safety_violations"]) do
        violations when is_list(violations) -> violations
        nil -> []
        _invalid -> ["invalid_safety_observation"]
      end
    end)
  end

  defp critical_regressions(tasks, rows) do
    critical =
      tasks
      |> Enum.filter(&(get_in(&1, ["metadata", "critical"]) == true))
      |> Enum.map(& &1["id"])

    rows
    |> Enum.filter(&(&1["task_id"] in critical))
    |> Enum.group_by(&{&1["task_id"], &1["attempt"]})
    |> Enum.flat_map(fn {{id, attempt}, pair} ->
      values = Map.new(pair, &{&1["runtime"], &1["passed"]})

      if values["control"] and not values["variant"],
        do: [%{"case_id" => id, "attempt" => attempt}],
        else: []
    end)
  end

  defp bound?(row, plan) do
    expected =
      if row["runtime"] == "variant", do: plan.variant["digest"], else: plan.control["digest"]

    get_in(row, ["observation", "frozen_build_sha256"]) == expected
  end

  defp complete?(row) do
    row["error"] == nil and get_in(row, ["observation", "status"]) == "completed" and
      is_number(row["wall_time_ms"]) and row["wall_time_ms"] >= 0 and
      is_boolean(row["passed"]) and is_map(row["grader"]) and
      get_in(row, ["grader", "timed_out"]) == false
  end

  # Repetitions and related cases contribute to one cluster mean, never to n.
  defp pairs(tasks, rows) do
    tasks
    |> Enum.group_by(&get_in(&1, ["metadata", "cluster_id"]))
    |> Enum.sort()
    |> Enum.map(fn {_cluster, members} ->
      ids = Enum.map(members, & &1["id"])
      group = Enum.filter(rows, &(&1["task_id"] in ids))

      Map.new(~w(control variant), &{&1, pass_rate(group, &1)})
    end)
  end

  defp pass_rate(group, runtime) do
    values =
      group
      |> Enum.filter(&(&1["runtime"] == runtime))
      |> Enum.map(&if(&1["passed"], do: 1, else: 0))

    Enum.sum(values) / length(values)
  end

  defp resources(rows, policy) do
    candidate = Enum.filter(rows, &(&1["runtime"] == "variant"))
    costs = Enum.map(rows, &get_in(&1, ["observation", "usage", "cost_usd"]))
    tokens = Enum.map(candidate, &tokens/1)
    latency = Enum.sum(Enum.map(candidate, & &1["wall_time_ms"])) / length(candidate)
    cost = total(costs)
    observed_cost = costs |> Enum.filter(&(is_number(&1) and &1 >= 0)) |> Enum.sum()
    token_total = total(tokens)

    cost_ok = cost_ok?(cost, observed_cost, policy)
    requests = Enum.map(rows, &get_in(&1, ["observation", "tool_metrics", "requests"]))

    token_ok =
      policy["maximum_total_tokens"] == nil or
        (is_number(token_total) and token_total <= policy["maximum_total_tokens"])

    %{
      "passed" =>
        cost_ok and valid_costs?(costs) and requests_ok?(requests, policy) and
          token_ok and latency <= policy["maximum_mean_latency_ms"],
      "cost_usd" => cost,
      "observed_cost_usd" => observed_cost,
      "direct_requests" => total(requests),
      "usage_mode" => policy["usage_mode"] || "metered",
      "candidate_total_tokens" => token_total,
      "candidate_mean_latency_ms" => latency,
      "unknown_cost_policy" => policy["unknown_cost"]
    }
  end

  defp cost_ok?(_cost, _observed, %{"usage_mode" => "quota"}), do: true

  defp cost_ok?(nil, observed, policy),
    do: policy["unknown_cost"] == "allow" and observed <= policy["maximum_cost_usd"]

  defp cost_ok?(cost, observed, policy),
    do: cost <= policy["maximum_cost_usd"] and observed <= policy["maximum_cost_usd"]

  defp requests_ok?(requests, %{"usage_mode" => "quota"} = policy) do
    Enum.all?(
      requests,
      &(is_integer(&1) and &1 >= 0 and &1 <= policy["max_requests_per_attempt"])
    ) and
      Enum.sum(requests) <= policy["maximum_requests"]
  end

  defp requests_ok?(_requests, _policy), do: true

  defp valid_costs?(costs), do: Enum.all?(costs, &(&1 == nil or (is_number(&1) and &1 >= 0)))

  defp tokens(row) do
    case get_in(row, ["observation", "resources"]) do
      %{"tokens_complete" => true, "full_input_tokens" => input, "output_tokens" => output}
      when is_number(input) and input >= 0 and is_number(output) and output >= 0 ->
        input + output

      _other ->
        nil
    end
  end

  defp total(values) do
    if Enum.all?(values, &(is_number(&1) and &1 >= 0)), do: Enum.sum(values), else: nil
  end
end
