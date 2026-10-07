defmodule LemieuxSystemOneCompaction.EvaluationTest do
  use ExUnit.Case, async: true

  alias LemieuxSystemOneCompaction.Evaluation

  test "a threshold sweep reuses scores and counts risky elisions" do
    evaluations = [
      %{
        "candidates" => [
          %{"keep_probability" => 0.08, "estimated_saved_tokens" => 2_000, "must_keep" => false},
          %{"keep_probability" => 0.72, "estimated_saved_tokens" => 4_000, "must_keep" => true}
        ]
      }
    ]

    assert {:ok, [conservative, permissive]} =
             Evaluation.sweep(evaluations, [0.1, 0.8], min_saved_tokens: 1_024)

    assert conservative == %{
             "threshold" => 0.1,
             "selected" => 1,
             "false_elisions" => 0,
             "unknown_labels" => 0,
             "estimated_saved_tokens" => 2_000
           }

    assert permissive["selected"] == 2
    assert permissive["false_elisions"] == 1
    assert permissive["estimated_saved_tokens"] == 6_000
  end

  test "a sweep applies the minimum reduction to the whole candidate set" do
    evaluations = [
      %{"candidates" => [%{"keep_probability" => 0.01, "estimated_saved_tokens" => 100}]}
    ]

    assert {:ok, [%{"selected" => 0, "estimated_saved_tokens" => 0}]} =
             Evaluation.sweep(evaluations, [0.1], min_saved_tokens: 1_024)
  end

  test "a whole-request price cliff is priced on all tokens" do
    tiers = [
      %{"up_to" => 272_000, "input_per_million" => 0.2, "output_per_million" => 1.2},
      %{"up_to" => nil, "input_per_million" => 0.4, "output_per_million" => 1.8}
    ]

    usage = fn input -> %{"input_tokens" => input, "output_tokens" => 100} end

    assert {:ok, expensive} = Evaluation.price(usage.(273_000), tiers)
    assert {:ok, cheaper} = Evaluation.price(usage.(271_000), tiers)
    assert_in_delta expensive["cost_usd"], 0.10938, 1.0e-8
    assert_in_delta cheaper["cost_usd"], 0.05432, 1.0e-8
  end

  test "cache writes use the selected whole-request tier without double-counting input" do
    tiers = [
      %{
        "up_to" => 272_000,
        "input_per_million" => 0.2,
        "cache_write_per_million" => 0.25,
        "output_per_million" => 1.2
      },
      %{
        "up_to" => nil,
        "input_per_million" => 0.4,
        "cache_write_per_million" => 0.5,
        "output_per_million" => 1.8
      }
    ]

    assert {:ok, before} =
             Evaluation.price(
               %{
                 "input_tokens" => 261_551,
                 "cache_write_tokens" => 261_548,
                 "input_includes_cached" => true,
                 "output_tokens" => 5
               },
               tiers
             )

    assert {:ok, after_cliff} =
             Evaluation.price(
               %{
                 "input_tokens" => 283_302,
                 "cache_write_tokens" => 283_299,
                 "input_includes_cached" => true,
                 "output_tokens" => 5
               },
               tiers
             )

    assert before["full_input_tokens"] == 261_551
    assert_in_delta before["cost_usd"], 0.0653936, 1.0e-8
    assert_in_delta after_cliff["cost_usd"], 0.1416597, 1.0e-8
  end

  test "a cache-breaking projection includes SDK cost over the full horizon" do
    tiers = [
      %{
        "up_to" => nil,
        "input_per_million" => 0.25,
        "cached_input_per_million" => 0.025,
        "output_per_million" => 2.0
      }
    ]

    baseline = [
      %{
        "input_tokens" => 5_038,
        "cache_read_tokens" => 4_992,
        "input_includes_cached" => true,
        "output_tokens" => 70
      }
    ]

    projected = [%{"input_tokens" => 603, "output_tokens" => 48}]
    sdk = [%{"input_tokens" => 534, "output_tokens" => 22}]
    sdk_rates = %{"input_per_million" => 0.042, "output_per_million" => 0.0}

    assert {:ok, comparison} = Evaluation.compare(baseline, projected, sdk, tiers, sdk_rates)
    assert comparison["baseline_cost_usd"] > comparison["projected_provider_cost_usd"]
    assert comparison["sdk_cost_usd"] > 0
    assert comparison["net_savings_usd"] < comparison["baseline_cost_usd"]
  end

  test "unknown usage and ambiguous cache accounting cannot be called free" do
    tiers = [%{"up_to" => nil, "input_per_million" => 1.0, "output_per_million" => 1.0}]

    assert {:error, :incomplete_usage} = Evaluation.price(%{"input_tokens" => 100}, tiers)

    assert {:error, :ambiguous_cache_usage} =
             Evaluation.price(
               %{"input_tokens" => 100, "cache_read_tokens" => 80, "output_tokens" => 10},
               tiers
             )
  end
end
