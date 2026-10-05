defmodule VerifierExtension.TotalsTest do
  use ExUnit.Case, async: true

  alias VerifierExtension.Totals

  test "numbers add, maps recurse, lists union and booleans conjoin" do
    task = %{
      "requests" => 2,
      "cost_usd" => 0.5,
      "direct" => %{"requests" => 2, "tokenizers" => ["a"]},
      "tokens_complete" => true
    }

    retry = %{
      "requests" => 1,
      "cost_usd" => 0.25,
      "direct" => %{"requests" => 1, "tokenizers" => ["b", "a"]},
      "tokens_complete" => false
    }

    assert Totals.sum([task, retry]) == %{
             "requests" => 3,
             "cost_usd" => 0.75,
             "direct" => %{"requests" => 3, "tokenizers" => ["a", "b"]},
             "tokens_complete" => false
           }
  end

  test "an unknown counter stays unknown while an unreported key is skipped" do
    assert Totals.sum([%{"cost_usd" => 1.0, "only_here" => 4}, %{"cost_usd" => nil}]) ==
             %{"cost_usd" => nil, "only_here" => 4}
  end
end
