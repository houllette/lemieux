defmodule Lemieux.Learning.Qualification.PairedTest do
  use ExUnit.Case, async: true
  alias Lemieux.Learning.Qualification.Paired

  test "a ten-point effect can be detected without pretending its conditional interval is an effect interval" do
    pairs = List.duplicate({false, true}, 10) ++ List.duplicate({true, true}, 90)
    result = Paired.compare(pairs, 0.025)
    assert_in_delta result["effect"], 0.1, 1.0e-12
    assert_in_delta result["p_value"], 1 / 1024, 1.0e-12
    assert result["regressions"] == 0
    assert hd(result["discordant_win_probability_interval"]) > 0.5
    refute Map.has_key?(result, "interval")
  end

  test "ties supply no directional evidence and regressions count against improvement" do
    assert Paired.compare(List.duplicate({true, true}, 100), 0.025)["p_value"] == 1.0
    result = Paired.compare(List.duplicate({false, true}, 10) ++ [{true, false}], 0.025)
    assert_in_delta result["p_value"], 12 / 2048, 1.0e-12
    assert result["regressions"] == 1
    assert result["effect"] > 0
    assert result["regression_rate"] > 0
  end

  test "power uses the actual effect, regression and multiplicity acceptance conditions" do
    assumptions = %{
      "win_probability" => 0.25,
      "loss_probability" => 0.05,
      "minimum_effect" => 0.1,
      "maximum_regression_rate" => 0.1
    }

    assert_in_delta Paired.power(40, assumptions, 0.025)["per_comparison"], 0.566496, 0.00001
    power = Paired.power(80, assumptions, 0.025)
    assert_in_delta power["per_comparison"], 0.903901, 0.00001
    assert power["both_primary_lower_bound"] > 0.8
    assert Paired.power(2, assumptions, 0.025)["per_comparison"] == 0.0
  end
end
