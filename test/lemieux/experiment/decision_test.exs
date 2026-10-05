defmodule Lemieux.Experiment.DecisionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Experiment.Decision
  alias Lemieux.Experiment.Plan

  test "returns inconclusive when held-out evidence cannot meet the declared rule" do
    {:ok, plan} = Plan.new(plan_attrs(4, 0.1))

    evidence =
      evidence([
        %{"control" => false, "variant" => true},
        %{"control" => true, "variant" => true},
        %{"control" => true, "variant" => false},
        %{"control" => false, "variant" => true}
      ])

    assert {:ok, result} = Decision.evaluate(plan, evidence)
    assert result.verdict == :inconclusive
    assert result.holdout.interval.lower < 0.1
    assert result.holdout.interval.upper > 0.1
  end

  test "safety is a hard lexicographic failure" do
    {:ok, plan} = Plan.new(plan_attrs(2, 0.0))

    evidence =
      put_in(evidence([pair(true), pair(true)]), ["safety_failures"], ["outside workspace"])

    assert {:ok, result} = Decision.evaluate(plan, evidence)
    assert result.verdict == :safety_failure
    assert result.reason == :safety_failure
  end

  test "passes a clear held-out improvement only after the minimum sample" do
    {:ok, plan} = Plan.new(plan_attrs(4, 0.2))

    assert {:ok, result} =
             Decision.evaluate(plan, evidence([pair(true), pair(true), pair(true), pair(true)]))

    assert result.verdict == :pass
    assert result.holdout.effect == 1.0
  end

  defp pair(improved), do: %{"control" => false, "variant" => improved}

  defp evidence(holdout) do
    %{
      "safety_failures" => [],
      "critical_regressions" => [],
      "development" => holdout,
      "holdout" => holdout
    }
  end

  defp plan_attrs(minimum_pairs, minimum_effect) do
    %{
      "hypothesis" => "variant improves the behavior",
      "variant" => %{"digest" => "variant", "changes" => [%{"field" => "prompt"}]},
      "control" => %{"digest" => "control"},
      "metric" => %{"kind" => "binary", "minimum_effect" => minimum_effect},
      "sample" => %{
        "development_case_ids" => ["dev"],
        "holdout_case_ids" => Enum.map(1..minimum_pairs, &"hold-#{&1}")
      },
      "stopping_rule" => %{"minimum_pairs" => minimum_pairs, "confidence" => 0.95},
      "budget" => %{"maximum_cost_usd" => 6.0}
    }
  end
end
