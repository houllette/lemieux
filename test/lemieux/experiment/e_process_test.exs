defmodule Lemieux.Experiment.EProcessTest do
  use ExUnit.Case, async: true

  alias Lemieux.Experiment.Decision
  alias Lemieux.Experiment.Plan

  @alpha 0.05
  @minimum_effect 0.1
  # The largest bet the [-1, 1] range admits: lambda * (hi - lo) == 1.
  @max_lambda 0.5

  describe "Plan.new/1 with an e_process stopping rule" do
    test "accepts the rule with and without a fixed lambda and round-trips it" do
      assert {:ok, plan} = Plan.new(plan_attrs(rule()))
      assert plan.stopping_rule == rule()
      assert Plan.decode!(Plan.encode!(plan)) == plan

      assert {:ok, fixed} = Plan.new(plan_attrs(rule(lambda: @max_lambda)))
      assert fixed.stopping_rule["lambda"] == @max_lambda
    end

    test "leaves the fixed-n rule as the default path" do
      assert {:ok, plan} = Plan.new(plan_attrs(%{"minimum_pairs" => 2, "confidence" => 0.95}))
      refute Map.has_key?(plan.stopping_rule, "kind")
    end

    test "rejects an alpha outside (0, 1)" do
      for alpha <- [0, 1, 1.5, -0.05, "0.05"] do
        assert {:error, {:invalid_stopping_rule, :alpha}} =
                 Plan.new(plan_attrs(rule(alpha: alpha)))
      end

      assert {:error, {:invalid_stopping_rule, :alpha}} =
               Plan.new(plan_attrs(Map.delete(rule(), "alpha")))
    end

    test "rejects a range that is not an ordered pair of numbers" do
      for range <- [[1, -1], [0, 0], [0], [-1, 1, 2], "range", [0, "1"], nil] do
        assert {:error, {:invalid_stopping_rule, :range}} =
                 Plan.new(plan_attrs(rule(range: range)))
      end

      assert {:error, {:invalid_stopping_rule, :range}} =
               Plan.new(plan_attrs(Map.delete(rule(), "range")))
    end

    test "requires a binary metric to declare the [-1, 1] range" do
      assert {:error, {:invalid_stopping_rule, :binary_range}} =
               Plan.new(plan_attrs(rule(range: [0, 1]), "binary"))

      assert {:ok, _plan} = Plan.new(plan_attrs(rule(range: [0, 1]), "continuous"))
      assert {:ok, _plan} = Plan.new(plan_attrs(rule(range: [-1, 1]), "binary"))
    end

    test "rejects a lambda that is not positive or exceeds one over the range" do
      for lambda <- [0, -0.1, 0.6, "0.5"] do
        assert {:error, {:invalid_stopping_rule, :lambda}} =
                 Plan.new(plan_attrs(rule(lambda: lambda)))
      end
    end

    test "rejects a minimum pair count that is not a positive integer" do
      for pairs <- [0, -1, 1.5, "2"] do
        assert {:error, {:invalid_stopping_rule, :minimum_pairs}} =
                 Plan.new(plan_attrs(rule(minimum_pairs: pairs)))
      end
    end

    test "rejects an unknown rule kind" do
      assert {:error, {:invalid_stopping_rule, :kind}} =
               Plan.new(plan_attrs(rule(kind: "sequential")))
    end
  end

  describe "Decision.evaluate/2 under an e_process rule" do
    test "commits a strong consistent improvement as soon as the evidence is decisive" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(12)))
      assert {result.verdict, result.reason} == {:pass, :e_process_commit}

      e_process = result.holdout["e_process"]
      assert e_process["pairs"] == 12
      assert e_process["lambda"] == @max_lambda
      assert_in_delta e_process["threshold"], 20.0, 1.0e-12
      assert e_process["improvement"] >= e_process["threshold"]
      assert e_process["no_improvement"] < 1.0

      # The same twelve pairs under a fixed-n rule preregistered at twenty
      # pairs cannot stop yet; the e-process commits eight pairs earlier.
      {:ok, fixed_n} = Plan.new(plan_attrs(%{"minimum_pairs" => 20, "confidence" => 0.95}))
      assert {:ok, waiting} = Decision.evaluate(fixed_n, evidence(improvements(12)))
      assert {waiting.verdict, waiting.reason} == {:inconclusive, :minimum_sample_not_met}
    end

    test "never stops before the preregistered minimum sample" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(5)))
      assert {result.verdict, result.reason} == {:inconclusive, :minimum_sample_not_met}

      # Decisive evidence below the minimum is still reported, just not acted on.
      {:ok, patient} = Plan.new(plan_attrs(rule(minimum_pairs: 12, lambda: @max_lambda)))
      assert {:ok, blocked} = Decision.evaluate(patient, evidence(improvements(10)))
      assert {blocked.verdict, blocked.reason} == {:inconclusive, :minimum_sample_not_met}
      assert blocked.holdout["e_process"]["improvement"] >= 20.0
    end

    test "the default lambda is the conservative Hoeffding bet at the minimum effect" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6)))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(12)))
      assert {result.verdict, result.reason} == {:inconclusive, :e_process_continue}
      assert_in_delta result.holdout["e_process"]["lambda"], 0.1, 1.0e-12

      assert {:ok, still} = Decision.evaluate(plan, evidence(improvements(35)))
      assert {still.verdict, still.reason} == {:inconclusive, :e_process_continue}

      assert {:ok, committed} = Decision.evaluate(plan, evidence(improvements(36)))
      assert {committed.verdict, committed.reason} == {:pass, :e_process_commit}
    end

    test "a non-positive minimum effect bets at the range bound" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 2), "binary", 0.0))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(2)))
      assert result.holdout["e_process"]["lambda"] == @max_lambda
    end

    test "rejects a strong consistent non-improvement" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))

      assert {:ok, result} = Decision.evaluate(plan, evidence(regressions(12)))
      assert {result.verdict, result.reason} == {:fail, :e_process_reject}
      assert result.holdout["e_process"]["no_improvement"] >= 20.0
      assert result.holdout["e_process"]["improvement"] < 1.0
    end

    test "keeps sampling on mixed evidence" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))
      pairs = Enum.flat_map(1..6, fn _ -> [pair(false, true), pair(true, false)] end)

      assert {:ok, result} = Decision.evaluate(plan, evidence(pairs))
      assert {result.verdict, result.reason} == {:inconclusive, :e_process_continue}
      assert result.holdout["e_process"]["improvement"] < 20.0
      assert result.holdout["e_process"]["no_improvement"] < 20.0
    end

    test "e-values are the closed-form Hoeffding products" do
      lambda = 0.3
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 2, lambda: lambda)))
      differences = [1, 0, -1, 1, 1, 0, 1]

      assert {:ok, result} = Decision.evaluate(plan, evidence(Enum.map(differences, &pair_for/1)))

      penalty = lambda * lambda * 2 * 2 / 8

      improvement =
        Enum.reduce(differences, 1.0, fn d, acc ->
          acc * :math.exp(lambda * (d - @minimum_effect) - penalty)
        end)

      no_improvement =
        Enum.reduce(differences, 1.0, fn d, acc ->
          acc * :math.exp(lambda * (@minimum_effect - d) - penalty)
        end)

      e_process = result.holdout["e_process"]
      assert_in_delta e_process["improvement"], improvement, 1.0e-9
      assert_in_delta e_process["no_improvement"], no_improvement, 1.0e-9
      assert_in_delta e_process["log_improvement"], :math.log(improvement), 1.0e-9
      assert_in_delta e_process["log_no_improvement"], :math.log(no_improvement), 1.0e-9
      assert e_process["pairs"] == length(differences)
    end

    test "safety failure still wins over a committing e-process" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))
      evidence = Map.put(evidence(improvements(12)), "safety_failures", ["outside workspace"])

      assert {:ok, result} = Decision.evaluate(plan, evidence)
      assert {result.verdict, result.reason} == {:safety_failure, :safety_failure}
      assert result.holdout["e_process"]["improvement"] >= 20.0
    end

    test "critical regression still wins over a committing e-process" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 6, lambda: @max_lambda)))

      evidence =
        Map.put(evidence(improvements(12)), "critical_regressions", [%{"case_id" => "hold-1"}])

      assert {:ok, result} = Decision.evaluate(plan, evidence)
      assert {result.verdict, result.reason} == {:critical_regression, :critical_regression}
    end

    test "a continuous difference outside the declared range voids the e-process" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 2, range: [-1, 1]), "continuous"))
      pairs = [%{"control" => 0.0, "variant" => 0.5}, %{"control" => 0.0, "variant" => 5.0}]

      assert {:error, :difference_outside_declared_range} =
               Decision.evaluate(plan, evidence(pairs))
    end

    test "reports the normal interval at 1 - alpha alongside the e-process" do
      {:ok, plan} = Plan.new(plan_attrs(rule(minimum_pairs: 2, lambda: @max_lambda)))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(3)))
      assert_in_delta result.holdout.interval.confidence, 0.95, 1.0e-12
      assert result.holdout.effect == 1.0
      assert result.holdout.count == 3
    end

    test "fixed-n plans carry no e-process and keep their verdict reasons" do
      {:ok, plan} = Plan.new(plan_attrs(%{"minimum_pairs" => 4, "confidence" => 0.95}))

      assert {:ok, result} = Decision.evaluate(plan, evidence(improvements(4)))
      assert {result.verdict, result.reason} == {:pass, :minimum_effect_met}
      refute Map.has_key?(result.holdout, "e_process")
    end
  end

  defp rule(overrides \\ []) do
    base = %{"kind" => "e_process", "alpha" => @alpha, "minimum_pairs" => 6, "range" => [-1, 1]}

    Enum.reduce(overrides, base, fn {key, value}, acc ->
      Map.put(acc, Atom.to_string(key), value)
    end)
  end

  defp plan_attrs(stopping_rule, metric_kind \\ "binary", minimum_effect \\ @minimum_effect) do
    %{
      "hypothesis" => "the variant improves the paired outcome",
      "variant" => %{"digest" => "variant", "changes" => [%{"field" => "prompt"}]},
      "control" => %{"digest" => "control"},
      "metric" => %{"kind" => metric_kind, "minimum_effect" => minimum_effect},
      "sample" => %{
        "development_case_ids" => ["dev-1"],
        "holdout_case_ids" => Enum.map(1..40, &"hold-#{&1}")
      },
      "stopping_rule" => stopping_rule,
      "budget" => %{"maximum_cost_usd" => 6.0}
    }
  end

  defp improvements(count), do: List.duplicate(pair(false, true), count)
  defp regressions(count), do: List.duplicate(pair(true, false), count)

  defp pair(control, variant), do: %{"control" => control, "variant" => variant}

  defp pair_for(1), do: pair(false, true)
  defp pair_for(0), do: pair(true, true)
  defp pair_for(-1), do: pair(true, false)

  defp evidence(holdout) do
    %{
      "safety_failures" => [],
      "critical_regressions" => [],
      "development" => [],
      "holdout" => holdout
    }
  end
end
