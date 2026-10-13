defmodule Lemieux.WritersEvaluationTest do
  use ExUnit.Case, async: true
  alias Lemieux.Writers.Evaluation
  alias Lemieux.Writers.Fixture
  @moduletag :tmp_dir

  test "matched improvement passes while fixture receipts keep wider use disabled" do
    serial = observation()
    parallel = %{serial | "wall_ms" => 50}

    assert {:ok, %{"pair_passed" => true, "wider_use_enabled" => false}} =
             Evaluation.compare(serial, parallel)

    for gate <- ~w(unauthorized_writes missing_effects lost_findings) do
      poisoned = put_in(parallel, ["violations", gate], 1)

      assert {:ok, %{"pair_passed" => false, "reasons" => reasons}} =
               Evaluation.compare(serial, poisoned)

      assert "hard_failure" in reasons
    end
  end

  test "mismatched bases, absent evidence and unknown or excessive costs cannot qualify" do
    serial = observation()

    assert {:error, :unmatched_or_invalid_policy} =
             Evaluation.compare(serial, %{serial | "base_revision" => "other"})

    assert {:error, :invalid_observation} =
             Evaluation.compare(serial, Map.delete(serial, "evidence"))

    assert {:ok, %{"pair_passed" => false, "reasons" => reasons}} =
             Evaluation.compare(serial, %{serial | "wall_ms" => 50, "spent_usd" => nil})

    assert "unknown_cost" in reasons

    assert {:ok, %{"pair_passed" => false, "reasons" => reasons}} =
             Evaluation.compare(serial, %{serial | "wall_ms" => 50, "spent_usd" => 2})

    assert "cost_regression" in reasons
  end

  test "the real offline fixture grades identical patches, costs and requests in both arms", %{
    tmp_dir: dir
  } do
    assert {:ok, receipt} = Fixture.run(Path.join(dir, "comparison"))

    for arm <- ["serial", "parallel"] do
      assert receipt[arm]["quality"] == 2
      assert receipt[arm]["requests"] == 4
      assert_in_delta receipt[arm]["spent_usd"], 0.04, 0.000001

      assert receipt[arm]["violations"] == %{
               "unauthorized_writes" => 0,
               "missing_effects" => 0,
               "lost_findings" => 0
             }

      assert receipt[arm]["evidence"]["artifacts"] != []
    end

    assert receipt["serial"]["base_revision"] == receipt["parallel"]["base_revision"]
    assert receipt["evidence_kind"] == "fixture"
    refute receipt["wider_use_enabled"]
    assert File.exists?(Path.join([dir, "comparison", "comparison.json"]))
  end

  defp observation do
    %{
      "case_id" => "case",
      "base_revision" => "revision",
      "policy_digest" => "policy",
      "grader_digest" => "grader",
      "source" => "scripted",
      "quality" => 1,
      "requests" => 4,
      "spent_usd" => 1,
      "wall_ms" => 100,
      "violations" => %{"unauthorized_writes" => 0, "missing_effects" => 0, "lost_findings" => 0},
      "evidence" => %{"transcript" => "fixture"}
    }
  end
end
