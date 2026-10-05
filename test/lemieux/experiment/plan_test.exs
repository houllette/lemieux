defmodule Lemieux.Experiment.PlanTest do
  use ExUnit.Case, async: true

  alias Lemieux.Experiment.Plan

  test "requires a hypothesis, one-factor variant, paired control, metric, sample, and stopping rule" do
    assert {:ok, plan} = Plan.new(valid_attrs())
    assert plan.variant["changes"] == [%{"field" => "prompt", "to" => "v2"}]
    assert Plan.decode!(Plan.encode!(plan)) == plan

    attrs = put_in(valid_attrs(), ["variant", "changes"], [%{"field" => "a"}, %{"field" => "b"}])
    assert {:error, :multi_factor_variant} = Plan.new(attrs)

    assert {:error, {:missing_field, "hypothesis"}} =
             valid_attrs() |> Map.delete("hypothesis") |> Plan.new()

    assert {:error, :invalid_created_at} =
             valid_attrs() |> Map.put("created_at", "not-a-time") |> Plan.new()
  end

  defp valid_attrs do
    %{
      "hypothesis" => "formatter instruction improves compliance",
      "variant" => %{
        "digest" => "variant",
        "changes" => [%{"field" => "prompt", "to" => "v2"}]
      },
      "control" => %{"digest" => "control"},
      "metric" => %{"kind" => "binary", "minimum_effect" => 0.1},
      "sample" => %{
        "development_case_ids" => ["dev-1"],
        "holdout_case_ids" => ["hold-1", "hold-2"]
      },
      "stopping_rule" => %{"minimum_pairs" => 2, "confidence" => 0.95},
      "budget" => %{"maximum_cost_usd" => 6.0}
    }
  end
end
