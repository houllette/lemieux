defmodule Lemieux.CLI.Learning.StudyBudgetTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetPolicy
  alias Lemieux.CLI.Learning.AssetSearch
  alias Lemieux.CLI.Learning.StudyBudget

  test "selective single-kind budgets fund four probes and every possible editor call" do
    protocol = AssetSearch.protocol(kinds: ["skill"], selection_policy: AssetPolicy.policy())
    budget = StudyBudget.research(12, false, true, asset_protocol: protocol)
    assert budget.asset_requests == 4 * 12 + 3
    assert budget.allowance["requests"] == budget.asset_requests + 2 * 12 + 2

    combined =
      AssetSearch.protocol(
        kinds: ["skill", "configuration"],
        selection_policy: AssetPolicy.policy()
      )

    assert StudyBudget.research(12, false, true, asset_protocol: combined).asset_requests ==
             8 * 12 + 4

    assert StudyBudget.research(12, false, true).asset_requests == 8 * 12 + 4
  end

  test "every allowed horizon funds complete experiments plus originals, final executions and reflection" do
    for requests <- [8, 12, 24, 64, 200],
        {profile?, assets?} <- [{true, false}, {false, true}, {true, true}] do
      budget = StudyBudget.research(requests, profile?, assets?)
      final_runs = Enum.count([profile?, assets?], & &1)

      assert budget.allowance["requests"] >=
               budget.profile_requests + budget.asset_requests + requests * (1 + final_runs) + 2

      assert budget.allowance["tokens"] > budget.experiment_tokens * final_runs
      assert budget.allowance["time_ms"] > budget.profile_time_ms + budget.asset_time_ms
      if profile?, do: assert(budget.profile_requests >= 8 * requests + 32)
      if assets?, do: assert(budget.asset_requests >= 8 * requests + 4)
    end
  end

  test "long horizons increase token and deadline bounds without changing model output limits" do
    short = StudyBudget.research(8, true, true)
    long = StudyBudget.research(200, true, true)
    assert long.experiment_tokens > short.experiment_tokens
    assert long.task_time_ms > short.task_time_ms
    assert long.allowance["requests"] <= 4096
    assert long.asset_requests <= 2048
    assert long.profile_requests <= 2048
  end
end
