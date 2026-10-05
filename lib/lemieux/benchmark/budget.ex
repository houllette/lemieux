defmodule Lemieux.Benchmark.Budget do
  @moduledoc false

  @spec apply(report :: map(), cap :: number() | nil, estimate :: number() | nil) :: map()
  def apply(report, cap, estimate) do
    costs =
      report
      |> Map.get("results", [])
      |> Enum.map(&get_in(&1, ["observation", "usage", "cost_usd"]))

    known = Enum.filter(costs, &is_number/1)
    judge_cost = get_in(report, ["judge", "usage", "cost_usd"])
    actual_parts = known ++ if(is_number(judge_cost), do: [judge_cost], else: [])
    actual = if actual_parts == [], do: nil, else: Enum.sum(actual_parts)
    unknown = Enum.count(costs, &(not is_number(&1)))
    exceeded = is_number(cap) and is_number(actual) and actual > cap

    budget = %{
      "estimated_cost_usd" => estimate,
      "actual_cost_usd" => actual,
      "unknown_cost_runs" => unknown,
      "judge_cost_usd" => judge_cost,
      "cap_usd" => cap,
      "exceeded" => exceeded
    }

    report = Map.put(report, "budget", budget)

    if exceeded do
      failure = %{
        "runtime" => nil,
        "metric" => "cost_cap",
        "hard" => true,
        "actual_cost_usd" => actual,
        "cap_usd" => cap
      }

      report
      |> put_in(["gate", "passed"], false)
      |> update_in(["gate", "failures"], &[failure | &1])
    else
      report
    end
  end
end
