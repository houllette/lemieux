defmodule Lemieux.Compaction.PriceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Compaction.Price

  @prices %{
    "google:gemini-3.1-pro-preview" => [
      %{up_to: 200_000, input_per_million: 2.0, output_per_million: 12.0},
      %{up_to: nil, input_per_million: 4.0, output_per_million: 18.0}
    ]
  }

  test "one request can repay the summary when a whole-request tariff drops" do
    assert {:compact, decision} =
             Price.evaluate(201_000, 40_000, 50_000, 4096, @prices,
               model: "google:gemini-3.1-pro-preview"
             )

    assert_in_delta decision.projected_savings_usd, 0.574848, 0.000001
  end

  test "unknown prices and moves within one band do not trigger" do
    assert :continue == Price.evaluate(201_000, 40_000, 50_000, 4096, @prices, model: "alias")

    assert :continue ==
             Price.evaluate(190_000, 40_000, 50_000, 4096, @prices,
               model: "google:gemini-3.1-pro-preview"
             )
  end

  test "the summary must repay itself" do
    assert :continue ==
             Price.evaluate(201_000, 190_000, 200_000, 4096, @prices,
               model: "google:gemini-3.1-pro-preview",
               minimum_savings_usd: 0.01
             )
  end
end
