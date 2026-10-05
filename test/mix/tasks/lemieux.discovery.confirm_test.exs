defmodule Mix.Tasks.Lemieux.Discovery.ConfirmTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lemieux.Discovery.Confirm

  test "routes the same CONFIG and CANDIDATE_ID to the meta lane under --meta" do
    assert {:ok, invocation} = Confirm.parse(["meta.exs", "cand_002", "--meta", "--allow-live"])

    assert invocation == %{
             lane: :meta,
             path: "meta.exs",
             candidate_id: "cand_002",
             allow_live: true,
             options: []
           }

    assert {:ok, %{lane: :meta, allow_live: false}} =
             Confirm.parse(["meta.exs", "cand_002", "--meta"])
  end

  test "keeps the holdout lane and its flags unchanged without --meta" do
    assert {:ok, invocation} =
             Confirm.parse([
               "campaign.exs",
               "cand_002",
               "--model",
               "test:target",
               "--holdout",
               "hold-a1, hold-b1",
               "--legacy-rule",
               "--minimum-pairs",
               "3"
             ])

    assert invocation.lane == :holdout
    assert invocation.allow_live == false
    assert invocation.options[:model] == "test:target"
    assert invocation.options[:holdout_case_ids] == ["hold-a1", "hold-b1"]
    assert invocation.options[:stopping_rule] == %{"minimum_pairs" => 3, "confidence" => 0.9}
    refute Keyword.has_key?(invocation.options, :holdout)
    refute Keyword.has_key?(invocation.options, :legacy_rule)
    refute Keyword.has_key?(invocation.options, :allow_live)
  end

  test "refuses holdout-lane flags under --meta and malformed invocations" do
    assert {:error, message} = Confirm.parse(["meta.exs", "cand_002", "--meta", "--model", "m"])
    assert message =~ "--meta"
    assert message =~ "--model"

    assert {:error, usage} = Confirm.parse(["campaign.exs"])
    assert usage =~ "Usage:"
    assert {:error, _usage} = Confirm.parse(["campaign.exs", "cand_002", "--bogus"])
    assert {:error, _usage} = Confirm.parse(["campaign.exs", "cand_002", "extra"])
  end
end
