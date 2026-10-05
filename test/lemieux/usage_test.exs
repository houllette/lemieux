defmodule Lemieux.UsageTest do
  use ExUnit.Case, async: true

  alias Lemieux.Usage

  test "guarantees stable token, cache, cost, and model keys" do
    usage = %{
      input_tokens: 120,
      output_tokens: 8,
      cached_tokens: 70,
      cache_creation_tokens: 10,
      total_cost: 0.0042,
      provider_detail: %{region: :west}
    }

    assert %{
             "input_tokens" => 120,
             "output_tokens" => 8,
             "cache_read_tokens" => 70,
             "cache_write_tokens" => 10,
             "cost_usd" => 0.0042,
             "model" => "test:model",
             "provider_detail" => %{"region" => "west"}
           } = Usage.normalize(usage, "test:model")
  end

  test "unknown pricing is nil rather than zero" do
    usage = Usage.normalize(%{"input_tokens" => 3}, "test:unpriced")

    assert usage["cost_usd"] == nil
    assert Usage.cost_usd(usage) == nil
  end

  test "reads cost from req_llm's nested breakdown" do
    usage = Usage.normalize(%{"cost" => %{"total" => 1.25}}, "test:model")

    assert Usage.cost_usd(usage) == 1.25
  end

  test "preserves booleans and nulls as JSON values" do
    usage =
      Usage.normalize(
        %{input_includes_cached: true, provider_detail: %{available: false, reason: nil}},
        "test:model"
      )

    assert usage["input_includes_cached"] == true
    assert usage["provider_detail"] == %{"available" => false, "reason" => nil}
  end

  test "adds request usage while preserving an unknown cost" do
    measured = %{
      "input_tokens" => 10,
      "output_tokens" => 2,
      "cache_read_tokens" => 3,
      "cache_write_tokens" => 1,
      "cost_usd" => 0.01
    }

    unknown = %{"input_tokens" => 4, "output_tokens" => 1, "cost_usd" => nil}

    assert %{
             "input_tokens" => 14,
             "output_tokens" => 3,
             "cache_read_tokens" => 3,
             "cache_write_tokens" => 1,
             "cost_usd" => nil
           } = Usage.add(measured, unknown)
  end

  test "sums a collection from the public empty usage value" do
    assert %{
             "input_tokens" => 8,
             "output_tokens" => 3,
             "cache_read_tokens" => 0,
             "cache_write_tokens" => 0,
             "cost_usd" => 0.03
           } =
             Usage.sum([
               %{"input_tokens" => 5, "output_tokens" => 2, "cost_usd" => 0.01},
               %{"input_tokens" => 3, "output_tokens" => 1, "cost_usd" => 0.02}
             ])
  end

  test "aggregate input is additive when cached tokens are a provider-reported subset" do
    assert %{
             "input_tokens" => 10,
             "cache_read_tokens" => 80,
             "cache_write_tokens" => 10,
             "output_tokens" => 5
           } =
             Usage.sum([
               %{
                 "input_tokens" => 100,
                 "cache_read_tokens" => 80,
                 "cache_write_tokens" => 10,
                 "output_tokens" => 5,
                 "input_includes_cached" => true,
                 "cost_usd" => 0.01
               }
             ])
  end
end
