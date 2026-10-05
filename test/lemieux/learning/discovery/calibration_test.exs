defmodule Lemieux.Learning.Discovery.CalibrationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Calibration
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Comparison
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  describe "prediction/1" do
    test "reads the prediction extension, defaults missing keys, and is nil when absent" do
      plan = plan()

      predicted =
        candidate(plan, "predicted", "predicted bytes",
          parents: [seed_parent(plan)],
          extensions: %{"prediction" => %{"fixes" => ["dev-2", "dev-1"]}}
        )

      assert Calibration.prediction(predicted) == %{
               "fixes" => ["dev-1", "dev-2"],
               "at_risk" => []
             }

      explicit =
        candidate(plan, "explicit", "explicit bytes",
          parents: [seed_parent(plan)],
          extensions: %{"prediction" => %{}}
        )

      assert Calibration.prediction(explicit) == %{"fixes" => [], "at_risk" => []}

      bare = candidate(plan, "bare", "bare bytes", parents: [seed_parent(plan)])
      assert Calibration.prediction(bare) == nil
    end
  end

  describe "realized/5" do
    test "compares the candidate with its first parent on the cases both were evaluated on" do
      plan = plan()
      policy = Policy.read(plan)
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])

      evaluations = [
        failed(plan, parent, "dev-1"),
        passed(plan, parent, "dev-2"),
        passed(plan, parent, "dev-3"),
        passed(plan, child, "dev-1"),
        failed(plan, child, "dev-2")
      ]

      assert Calibration.realized(plan, child, [parent, child], evaluations, policy) ==
               {:ok,
                %{
                  "parent_id" => "parent",
                  "compared_case_ids" => ["dev-1", "dev-2"],
                  "fixed" => ["dev-1"],
                  "regressed" => ["dev-2"],
                  "unchanged" => []
                }}
    end

    test "a seed parent, an unlisted parent, or an unevaluated parent is no evidence" do
      plan = plan()
      policy = Policy.read(plan)
      rooted = candidate(plan, "rooted", "rooted bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(rooted)])

      assert Calibration.realized(plan, rooted, [rooted], [passed(plan, rooted, "dev-1")], policy) ==
               {:error, :no_parent_evidence}

      unevaluated = [passed(plan, child, "dev-1")]

      assert Calibration.realized(plan, child, [rooted, child], unevaluated, policy) ==
               {:error, :no_parent_evidence}

      validation_only = [
        evaluation(plan, rooted, "rooted-val", "val-1", 1.0, 1.0, split: "validation"),
        passed(plan, child, "dev-1")
      ]

      assert Calibration.realized(plan, child, [rooted, child], validation_only, policy) ==
               {:error, :no_parent_evidence}

      unlisted = [passed(plan, rooted, "dev-1"), passed(plan, child, "dev-1")]

      assert Calibration.realized(plan, child, [child], unlisted, policy) ==
               {:error, :no_parent_evidence}
    end
  end

  describe "score/4" do
    test "a perfect prediction scores full precision and recall with zero Brier error" do
      plan = plan()
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])

      child =
        candidate(plan, "child", "child bytes",
          parents: [parent(parent)],
          extensions: %{"prediction" => %{"fixes" => ["dev-1", "dev-2"], "at_risk" => ["dev-3"]}}
        )

      evaluations = [
        failed(plan, parent, "dev-1"),
        failed(plan, parent, "dev-2"),
        passed(plan, parent, "dev-3"),
        passed(plan, child, "dev-1"),
        passed(plan, child, "dev-2"),
        failed(plan, child, "dev-3")
      ]

      assert score(plan, child, [parent, child], evaluations) == %{
               "predicted" => true,
               "fix_precision" => 1.0,
               "fix_recall" => 1.0,
               "risk_precision" => 1.0,
               "risk_recall" => 1.0,
               "brier" => 0.0,
               "compared" => 3
             }
    end

    test "naming an unaffected case as a fix halves precision without touching recall" do
      plan = plan()
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])

      child =
        candidate(plan, "child", "child bytes",
          parents: [parent(parent)],
          extensions: %{"prediction" => %{"fixes" => ["dev-1", "dev-2"]}}
        )

      evaluations = [
        failed(plan, parent, "dev-1"),
        passed(plan, parent, "dev-2"),
        passed(plan, parent, "dev-3"),
        passed(plan, child, "dev-1"),
        passed(plan, child, "dev-2"),
        passed(plan, child, "dev-3")
      ]

      assert score(plan, child, [parent, child], evaluations) == %{
               "predicted" => true,
               "fix_precision" => 0.5,
               "fix_recall" => 1.0,
               "risk_precision" => nil,
               "risk_recall" => nil,
               "brier" => 0.0,
               "compared" => 3
             }
    end

    test "predicting no change on a candidate that regressed a solved case is penalized by Brier" do
      plan = plan()
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])

      explicit =
        candidate(plan, "explicit", "explicit bytes",
          parents: [parent(parent)],
          extensions: %{"prediction" => %{}}
        )

      unpredicted = candidate(plan, "unpredicted", "unpredicted bytes", parents: [parent(parent)])

      evaluations = [
        passed(plan, parent, "dev-1"),
        passed(plan, parent, "dev-2"),
        passed(plan, explicit, "dev-1"),
        failed(plan, explicit, "dev-2"),
        passed(plan, unpredicted, "dev-1"),
        failed(plan, unpredicted, "dev-2")
      ]

      candidates = [parent, explicit, unpredicted]

      assert score(plan, explicit, candidates, evaluations) == %{
               "predicted" => true,
               "fix_precision" => nil,
               "fix_recall" => nil,
               "risk_precision" => nil,
               "risk_recall" => 0.0,
               "brier" => 0.5,
               "compared" => 2
             }

      assert score(plan, unpredicted, candidates, evaluations) == %{
               "predicted" => false,
               "fix_precision" => nil,
               "fix_recall" => nil,
               "risk_precision" => nil,
               "risk_recall" => nil,
               "brier" => 0.5,
               "compared" => 2
             }
    end

    test "a confident wrong prediction costs the full Brier error and cases outside the comparison are ignored" do
      plan = plan()
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])

      child =
        candidate(plan, "child", "child bytes",
          parents: [parent(parent)],
          extensions: %{"prediction" => %{"fixes" => ["dev-1", "dev-9"], "at_risk" => ["val-1"]}}
        )

      evaluations = [
        failed(plan, parent, "dev-1"),
        failed(plan, child, "dev-1")
      ]

      assert score(plan, child, [parent, child], evaluations) == %{
               "predicted" => true,
               "fix_precision" => 0.0,
               "fix_recall" => nil,
               "risk_precision" => nil,
               "risk_recall" => nil,
               "brier" => 1.0,
               "compared" => 1
             }
    end
  end

  describe "summarize/4" do
    test "is uncalibrated when no candidate predicts and reports seed-parent candidates as errors" do
      plan = plan()
      policy = Policy.read(plan)
      root = candidate(plan, "root", "root bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(root)])
      evaluations = [passed(plan, root, "dev-1"), passed(plan, child, "dev-1")]

      summary = Calibration.summarize(plan, [root, child], evaluations, policy)

      assert summary["status"] == "uncalibrated"
      assert summary["candidates"]["root"] == %{"error" => "no_parent_evidence"}
      assert summary["candidates"]["child"]["predicted"] == false
      assert summary["candidates"]["child"]["brier"] == 0.0

      assert summary["aggregate"] == %{
               "predicted_candidates" => 0,
               "unpredicted_candidates" => 2,
               "mean_brier" => 0.0,
               "mean_fix_precision" => nil,
               "mean_fix_recall" => nil,
               "mean_risk_precision" => nil,
               "mean_risk_recall" => nil
             }
    end

    test "means ignore nils and the status is calibrated once any candidate predicts" do
      plan = plan()
      policy = Policy.read(plan)
      root = candidate(plan, "root", "root bytes", parents: [seed_parent(plan)])

      predicted =
        candidate(plan, "predicted", "predicted bytes",
          parents: [parent(root)],
          extensions: %{"prediction" => %{"fixes" => ["dev-1"]}}
        )

      unpredicted = candidate(plan, "unpredicted", "unpredicted bytes", parents: [parent(root)])

      evaluations = [
        failed(plan, root, "dev-1"),
        passed(plan, root, "dev-2"),
        passed(plan, predicted, "dev-1"),
        passed(plan, predicted, "dev-2"),
        failed(plan, unpredicted, "dev-1"),
        failed(plan, unpredicted, "dev-2")
      ]

      summary = Calibration.summarize(plan, [root, predicted, unpredicted], evaluations, policy)

      assert summary["status"] == "calibrated"
      assert summary["candidates"]["root"] == %{"error" => "no_parent_evidence"}
      assert summary["candidates"]["predicted"]["brier"] == 0.0
      assert summary["candidates"]["unpredicted"]["brier"] == 0.5

      assert summary["aggregate"] == %{
               "predicted_candidates" => 1,
               "unpredicted_candidates" => 2,
               "mean_brier" => 0.25,
               "mean_fix_precision" => 1.0,
               "mean_fix_recall" => 1.0,
               "mean_risk_precision" => nil,
               "mean_risk_recall" => nil
             }
    end
  end

  defp score(plan, candidate, candidates, evaluations) do
    policy = Policy.read(plan)
    outcomes = Comparison.outcomes(plan, evaluations, policy)

    assert {:ok, realized} =
             Calibration.realized(plan, candidate, candidates, evaluations, policy)

    Calibration.score(
      candidate,
      realized,
      Map.fetch!(outcomes, realized["parent_id"]),
      Map.fetch!(outcomes, candidate.id)
    )
  end

  defp plan do
    assert {:ok, plan} = Plan.new(plan_attrs())
    plan
  end

  defp plan_attrs do
    scope = %{"id" => "tenant-a/project-a"}
    seed_digest = sha("seed")

    %{
      "id" => "plan-1",
      "scope" => scope,
      "target_interface" => %{"id" => "environment-context/v1"},
      "mutation_surface" => [%{"asset_type" => "project_instruction", "path" => "context.json"}],
      "seeds" => [%{"id" => "seed-1", "content_sha256" => seed_digest, "scope" => scope}],
      "proposer" => %{"id" => "proposer-v1", "sha256" => String.duplicate("a", 64)},
      "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("b", 64)},
      "development_case_ids" => ["dev-1", "dev-2", "dev-3"],
      "validation_case_ids" => ["val-1"],
      "objectives" => [
        %{"name" => "quality", "direction" => "maximize"},
        %{"name" => "cost", "direction" => "minimize"}
      ],
      "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
      "interface_validator" => %{"id" => "validator-v1", "sha256" => String.duplicate("c", 64)},
      "budget" => %{
        "maximum_candidates" => 20,
        "maximum_tokens" => 10_000,
        "maximum_cost_usd" => 100.0,
        "maximum_time_ms" => 60_000
      }
    }
  end

  defp candidate(plan, id, bytes, opts) do
    scope = plan.scope
    content = reference("candidate_content", id <> "-content", bytes, scope)
    rationale = reference("proposer_trace", id <> "-rationale", "why #{id}", scope)

    attrs = %{
      "id" => id,
      "scope" => scope,
      "parents" => Keyword.get(opts, :parents, []),
      "content" => ArtifactReference.to_map(content),
      "proposer" => plan.proposer,
      "rationale" => ArtifactReference.to_map(rationale),
      "interface_validation" => %{
        "status" => Keyword.get(opts, :interface, "passed"),
        "validator_sha256" => plan.interface_validator["sha256"]
      },
      "exposures" => [%{"source_case_ids" => ["dev-1"]}],
      "mutation_kind" => Keyword.get(opts, :mutation_kind, "asset"),
      "extensions" => Keyword.get(opts, :extensions, %{})
    }

    assert {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp passed(plan, candidate, case_id),
    do: evaluation(plan, candidate, "#{candidate.id}/#{case_id}", case_id, 1.0, 1.0)

  defp failed(plan, candidate, case_id),
    do: evaluation(plan, candidate, "#{candidate.id}/#{case_id}", case_id, 0.0, 1.0)

  defp evaluation(plan, candidate, id, case_id, quality, cost, opts \\ []) do
    complete = Keyword.get(opts, :complete, true)
    safe = Keyword.get(opts, :safety, true)

    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "case_id" => case_id,
      "split" => Keyword.get(opts, :split, "development"),
      "objectives" => %{"quality" => quality, "cost" => cost},
      "safety" => %{"passed" => safe, "failures" => if(safe, do: [], else: ["unsafe"])},
      "completeness" => %{
        "usage" => if(complete, do: "complete", else: "unknown"),
        "cost" => "complete",
        "sandbox" => "complete",
        "artifacts" => "complete"
      },
      "usage" => %{"total_tokens" => 10},
      "cost" => %{"usd" => cost},
      "latency" => %{"milliseconds" => 5},
      "artifacts" => [],
      "within_budget" => Keyword.get(opts, :within_budget, true),
      "terminal" => true,
      "observations" => %{}
    }

    assert {:ok, evaluation} = Evaluation.new(plan, candidate, attrs)
    evaluation
  end

  defp seed_parent(plan) do
    seed = hd(plan.seeds)
    %{"id" => seed["id"], "content_sha256" => seed["content_sha256"]}
  end

  defp parent(candidate),
    do: %{"id" => candidate.id, "content_sha256" => Candidate.content_sha256(candidate)}

  defp reference(kind, id, bytes, scope) do
    ArtifactReference.from_bytes(kind, bytes,
      id: id,
      media_type: "application/json",
      content_schema: "fixture/v1",
      scope: scope
    )
  end

  defp sha(bytes), do: Contract.sha256(bytes)
end
