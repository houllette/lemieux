defmodule Lemieux.TestSupport.HarnessLearningFixtures do
  @moduledoc false

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Request

  @doc false
  @spec contracts() :: map()
  def contracts do
    scope = %{"id" => "tenant-fixture/project-fixture"}
    created_at = "2026-09-01T00:00:00Z"
    snapshot = snapshot()
    artifact = artifact(scope)
    plan = plan(scope, created_at)
    candidate = candidate(plan, artifact, scope, created_at)
    evaluation = evaluation(plan, candidate, artifact, scope, created_at)
    exposure = exposure(created_at)
    run = run(snapshot, run_artifact(scope), artifact, created_at)
    bundle = bundle(plan, candidate, evaluation, exposure, artifact, scope)

    %{
      "harness_snapshot" => Snapshot.to_map(snapshot),
      "run_evidence" => Run.to_map(run),
      "experience_bundle" => Bundle.to_map(bundle),
      "discovery_plan" => Plan.to_map(plan),
      "candidate" => Candidate.to_map(candidate),
      "evaluation" => Evaluation.to_map(evaluation),
      "exposure" => Exposure.to_map(exposure)
    }
  end

  defp snapshot do
    Snapshot.build(Request.new("test:model", system: "fixture system", tools: []),
      id: "harness-fixture",
      resolved_assets: [
        %{"id" => "asset-fixture", "sha256" => String.duplicate("a", 64)}
      ],
      context_limits: %{"context_window" => 10_000, "max_turns" => 5},
      hooks: %{"id" => "hooks-fixture"},
      workflow: %{"id" => "workflow-fixture"},
      compaction: %{"id" => "compaction-fixture"},
      environment_context: %{"id" => "environment-fixture"},
      sandbox_profile: %{"id" => "sandbox-fixture"},
      correlations: %{
        "tenant_id" => "tenant-fixture",
        "project_id" => "project-fixture",
        "run_id" => "run-fixture"
      }
    )
  end

  defp artifact(scope) do
    ArtifactReference.from_bytes("transcript", "fixture bytes",
      id: "artifact-fixture",
      media_type: "application/octet-stream",
      content_schema: "fixture/v1",
      scope: scope,
      locator: "artifact://fixture"
    )
  end

  defp run_artifact(scope) do
    ArtifactReference.from_bytes("transcript", "",
      id: "run-transcript-fixture",
      media_type: "application/x-ndjson",
      content_schema: "lemieux-transcript/v2",
      scope: scope,
      locator: "artifact://run-transcript-fixture"
    )
  end

  defp plan(scope, created_at) do
    {:ok, plan} =
      Plan.new(%{
        "id" => "discovery-fixture",
        "created_at" => created_at,
        "scope" => scope,
        "target_interface" => %{"id" => "asset/v1"},
        "mutation_surface" => [%{"asset_type" => "project_instruction"}],
        "seeds" => [
          %{"id" => "seed-fixture", "content_sha256" => String.duplicate("b", 64)}
        ],
        "proposer" => %{"id" => "proposer-fixture", "sha256" => String.duplicate("c", 64)},
        "base_model" => %{"id" => "model-fixture", "sha256" => String.duplicate("d", 64)},
        "development_case_ids" => ["case-development"],
        "validation_case_ids" => ["case-validation"],
        "objectives" => [%{"name" => "quality", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe"}],
        "interface_validator" => %{
          "id" => "validator-fixture",
          "sha256" => String.duplicate("e", 64)
        },
        "budget" => %{
          "maximum_candidates" => 3,
          "maximum_tokens" => 1_000,
          "maximum_cost_usd" => 5.0,
          "maximum_time_ms" => 30_000
        }
      })

    plan
  end

  defp candidate(plan, artifact, scope, created_at) do
    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => "candidate-fixture",
        "created_at" => created_at,
        "scope" => scope,
        "parents" => [
          %{"id" => "seed-fixture", "content_sha256" => String.duplicate("b", 64)}
        ],
        "content" => ArtifactReference.to_map(artifact),
        "proposer" => plan.proposer,
        "rationale" => ArtifactReference.to_map(artifact),
        "interface_validation" => %{
          "status" => "passed",
          "validator_sha256" => plan.interface_validator["sha256"]
        },
        "exposures" => [%{"source_case_ids" => ["case-development"]}],
        "mutation_kind" => "project_instruction"
      })

    candidate
  end

  defp evaluation(plan, candidate, artifact, scope, created_at) do
    {:ok, evaluation} =
      Evaluation.new(plan, candidate, %{
        "id" => "evaluation-fixture",
        "created_at" => created_at,
        "scope" => scope,
        "case_id" => "case-development",
        "split" => "development",
        "objectives" => %{"quality" => 1.0},
        "safety" => %{"passed" => true, "failures" => []},
        "completeness" => %{
          "usage" => "complete",
          "cost" => "complete",
          "sandbox" => "complete",
          "artifacts" => "complete"
        },
        "usage" => %{"total_tokens" => 20},
        "cost" => %{"usd" => 0.1},
        "latency" => %{"milliseconds" => 100},
        "artifacts" => [ArtifactReference.to_map(artifact)],
        "within_budget" => true,
        "terminal" => true,
        "observations" => %{"passed" => true}
      })

    evaluation
  end

  defp exposure(created_at) do
    {:ok, exposure} =
      Exposure.new(%{
        "id" => "exposure-fixture",
        "at" => created_at,
        "consumer_role" => "discovery_proposer",
        "consumer_id" => "discovery-fixture",
        "lineage_id" => "lineage-fixture",
        "direct_case_ids" => [],
        "derived_artifact_ids" => ["finding-fixture"],
        "source_case_ids" => ["case-development"]
      })

    exposure
  end

  defp run(snapshot, transcript_artifact, evidence_artifact, created_at) do
    {:ok, run} =
      Run.new(%{
        "id" => "run-fixture",
        "created_at" => created_at,
        "correlations" => %{
          "session_id" => "session-fixture",
          "root_session_id" => "session-fixture",
          "run_id" => "run-fixture",
          "tenant_id" => "tenant-fixture",
          "project_id" => "project-fixture"
        },
        "provider" => "test",
        "model" => "test:model",
        "outcome" => "succeeded",
        "stop_reason" => "stop",
        "timing" => %{"state" => "complete", "latency_ms" => 100},
        "usage" => %{
          "state" => "complete",
          "value" => %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => 0.1}
        },
        "cost" => %{"state" => "complete", "usd" => 0.1, "reason" => nil},
        "cache" => %{"state" => "complete", "read_tokens" => 0, "write_tokens" => 0},
        "retries" => %{"state" => "complete", "count" => 0},
        "observations" => %{
          "tool_outcomes" => [],
          "approvals" => [],
          "compactions" => 0,
          "cancellations" => 0,
          "errors" => []
        },
        "artifacts" => [
          ArtifactReference.to_map(transcript_artifact),
          ArtifactReference.to_map(evidence_artifact)
        ],
        "transcript" => %{
          "artifact_id" => transcript_artifact.id,
          "entry_count" => 0,
          "entry_ids" => [],
          "first_entry_id" => nil,
          "last_entry_id" => nil,
          "first_seq" => nil,
          "last_seq" => nil,
          "sequences" => [],
          "encoding" => "jsonl-no-trailing-newline"
        },
        "completeness" => %{
          "usage" => "complete",
          "cost" => "complete",
          "sandbox" => "complete",
          "artifacts" => "complete"
        },
        "harness_snapshot" => %{
          "id" => snapshot.id,
          "semantic_sha256" => snapshot.semantic_sha256,
          "manifest_sha256" => snapshot.manifest_sha256
        },
        "requests" => [
          %{
            "id" => "request-fixture",
            "sha256" => String.duplicate("f", 64),
            "harness_snapshot_id" => snapshot.id,
            "harness_snapshot_sha256" => snapshot.semantic_sha256
          }
        ]
      })

    run
  end

  defp bundle(plan, candidate, evaluation, exposure, artifact, scope) do
    {:ok, bundle} =
      Bundle.new(%{
        "id" => "bundle-fixture",
        "scope" => scope,
        "plan" => %{"id" => plan.id, "sha256" => plan.sha256, "scope" => scope},
        "seeds" => [
          %{
            "id" => "seed-fixture",
            "content_sha256" => String.duplicate("b", 64),
            "scope" => scope
          }
        ],
        "candidates" => [Candidate.to_map(candidate)],
        "evaluations" => [Evaluation.to_map(evaluation)],
        "raw" => [
          %{
            "id" => "raw-fixture",
            "scope" => scope,
            "reference" => ArtifactReference.to_map(artifact)
          }
        ],
        "derived" => [
          %{
            "id" => "finding-fixture",
            "source" => "ixway",
            "scope" => scope,
            "source_references" => [artifact.id],
            "sha256" => String.duplicate("1", 64)
          }
        ],
        "exposures" => [Exposure.to_map(exposure)],
        "artifacts" => [
          %{
            "id" => "artifact-file-fixture",
            "path" => "candidates/candidate-fixture/raw/transcript.bin",
            "scope" => scope,
            "reference" => ArtifactReference.to_map(artifact)
          }
        ],
        "frontier" => %{"candidate_ids" => [candidate.id]}
      })

    bundle
  end
end
