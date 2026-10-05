defmodule Lemieux.Learning.GoldenContractsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.TestSupport.HarnessLearningFixtures

  @fixture Path.expand("../../fixtures/harness_learning/contracts.json", __DIR__)

  test "the shared JSON fixture is byte-stable and every object verifies" do
    expected = HarnessLearningFixtures.contracts()
    assert {:ok, body} = File.read(@fixture)
    assert {:ok, actual} = JSON.decode(body)
    assert actual == expected

    assert Snapshot.verify(actual["harness_snapshot"]) == :ok
    assert Run.verify(actual["run_evidence"]) == :ok
    assert Bundle.verify(actual["experience_bundle"]) == :ok
    assert Plan.verify(actual["discovery_plan"]) == :ok
    assert Candidate.verify(actual["candidate"]) == :ok
    assert Evaluation.verify(actual["evaluation"]) == :ok
    assert Exposure.verify(actual["exposure"]) == :ok
  end

  test "all fixture contracts reject payload tampering under an unchanged digest" do
    fixtures = HarnessLearningFixtures.contracts()

    assert {:error, _reason} =
             fixtures["harness_snapshot"]
             |> Map.put("model", "tampered:model")
             |> Snapshot.verify()

    for {name, verifier} <- [
          {"run_evidence", &Run.verify/1},
          {"experience_bundle", &Bundle.verify/1},
          {"discovery_plan", &Plan.verify/1},
          {"candidate", &Candidate.verify/1},
          {"evaluation", &Evaluation.verify/1},
          {"exposure", &Exposure.verify/1}
        ] do
      assert {:error, :digest_mismatch} =
               fixtures[name] |> Map.put("id", "tampered") |> verifier.()
    end
  end
end
