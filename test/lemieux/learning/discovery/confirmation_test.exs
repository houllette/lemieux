defmodule Lemieux.Learning.Discovery.ConfirmationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Experiment.CodeGate
  alias Lemieux.Experiment.Plan, as: ExperimentPlan
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Confirmation
  alias Lemieux.Learning.Discovery.Plan

  test "freezes exact candidate bytes into an ordinary preregistered experiment" do
    {candidate, bytes} = candidate("asset")
    attrs = confirmation_attrs()

    assert {:ok, experiment} = Confirmation.to_experiment(candidate, bytes, attrs)
    assert experiment.variant["digest"] == Contract.sha256(bytes)
    assert [_one_change] = experiment.variant["changes"]
    assert experiment.sample == attrs["sample"]

    provenance = experiment.provenance
    assert provenance["discovery"]["candidate_id"] == candidate.id
    assert provenance["development_validation_evaluations"] == [%{"id" => "dev-eval"}]
    assert provenance["confirmation_evidence_prepopulated"] == false
    refute Map.has_key?(provenance, "holdout_observations")
    assert ExperimentPlan.verify(experiment) == :ok
    assert {:ok, ^experiment} = experiment |> ExperimentPlan.encode!() |> ExperimentPlan.decode()
  end

  test "rejects changed bytes and prepopulated hidden outcomes" do
    {candidate, bytes} = candidate("asset")

    assert {:error, :size_mismatch} =
             Confirmation.to_experiment(candidate, bytes <> " changed", confirmation_attrs())

    assert {:error, {:prepopulated_confirmation_evidence, "hidden_outcomes"}} =
             Confirmation.to_experiment(
               candidate,
               bytes,
               Map.put(confirmation_attrs(), "hidden_outcomes", [%{"passed" => true}])
             )

    assert {:error, :digest_mismatch} =
             Confirmation.to_experiment(
               %{candidate | mutation_kind: "tampered"},
               bytes,
               confirmation_attrs()
             )
  end

  test "every confirmatory fact changes the immutable plan digest" do
    {candidate, bytes} = candidate("asset")
    attrs = confirmation_attrs()
    {:ok, base} = Confirmation.to_experiment(candidate, bytes, attrs)

    variants = [
      put_in(attrs, ["control", "digest"], "other-control"),
      put_in(attrs, ["metric", "minimum_effect"], 0.2),
      put_in(attrs, ["sample", "holdout_case_ids"], ["hidden-2"]),
      put_in(attrs, ["stopping_rule", "minimum_pairs"], 3)
    ]

    assert Enum.all?(variants, fn changed ->
             {:ok, experiment} = Confirmation.to_experiment(candidate, bytes, changed)
             experiment.sha256 != base.sha256
           end)
  end

  test "harness-code candidates require complete code gate evidence and stay human-release-only" do
    {candidate, bytes} = candidate("harness_code")

    assert {:error, {:code_gate_required, {:missing_evidence, _missing}}} =
             Confirmation.to_experiment(candidate, bytes, confirmation_attrs())

    gate =
      Map.new(CodeGate.required_evidence(), fn name ->
        {name, %{"passed" => true, "digest" => Contract.sha256(name)}}
      end)

    assert {:ok, experiment} =
             Confirmation.to_experiment(
               candidate,
               bytes,
               Map.put(confirmation_attrs(), "code_gate", gate)
             )

    policy = experiment.provenance["release_policy"]
    assert policy["human_release_only"] == true
    assert policy["code_gate"]["production_active"] == false
    assert policy["code_gate"]["next_gate"] == "human_release_approval"
  end

  defp candidate(mutation_kind) do
    scope = %{"id" => "tenant-a/project-a"}
    bytes = "candidate bytes"

    {:ok, plan} =
      Plan.new(%{
        "id" => "discovery-plan",
        "scope" => scope,
        "target_interface" => %{"id" => "asset/v1"},
        "mutation_surface" => [%{"asset_type" => mutation_kind}],
        "seeds" => [%{"id" => "seed", "content_sha256" => Contract.sha256("seed")}],
        "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("a", 64)},
        "base_model" => %{"id" => "model", "sha256" => String.duplicate("b", 64)},
        "development_case_ids" => ["dev-1"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "quality", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe"}],
        "interface_validator" => %{"id" => "validator", "sha256" => String.duplicate("c", 64)},
        "budget" => %{
          "maximum_candidates" => 2,
          "maximum_tokens" => 100,
          "maximum_cost_usd" => 1.0,
          "maximum_time_ms" => 1_000
        }
      })

    content =
      ArtifactReference.from_bytes("candidate_content", bytes,
        id: "content",
        media_type: "application/octet-stream",
        content_schema: "candidate/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why",
        id: "rationale",
        media_type: "text/plain",
        content_schema: "proposer-trace/v1",
        scope: scope
      )

    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => "candidate",
        "scope" => scope,
        "parents" => [%{"id" => "seed", "content_sha256" => Contract.sha256("seed")}],
        "content" => ArtifactReference.to_map(content),
        "proposer" => plan.proposer,
        "rationale" => ArtifactReference.to_map(rationale),
        "interface_validation" => %{
          "status" => "passed",
          "validator_sha256" => plan.interface_validator["sha256"]
        },
        "exposures" => [%{"source_case_ids" => ["dev-1"]}],
        "mutation_kind" => mutation_kind
      })

    {candidate, bytes}
  end

  defp confirmation_attrs do
    %{
      "hypothesis" => "the frozen candidate improves quality",
      "control" => %{"digest" => "control"},
      "metric" => %{"kind" => "binary", "minimum_effect" => 0.1},
      "sample" => %{
        "development_case_ids" => ["confirm-dev"],
        "holdout_case_ids" => ["hidden-1"]
      },
      "stopping_rule" => %{"minimum_pairs" => 2, "confidence" => 0.95},
      "budget" => %{"maximum_cost_usd" => 5.0},
      "development_validation_evaluations" => [%{"id" => "dev-eval"}]
    }
  end
end
