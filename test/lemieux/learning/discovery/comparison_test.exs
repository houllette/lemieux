defmodule Lemieux.Learning.Discovery.ComparisonTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Comparison
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  describe "outcomes/3" do
    test "aggregates development evaluations per candidate and case, ignoring validation" do
      plan = plan()
      policy = Policy.read(plan)
      a = candidate(plan, "a", "a bytes", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b bytes", parents: [seed_parent(plan)])

      evaluations = [
        evaluation(plan, a, "a-dev-1-first", "dev-1", 1.0, 1.0),
        evaluation(plan, a, "a-dev-1-second", "dev-1", 0.0, 1.0),
        evaluation(plan, a, "a-dev-2-first", "dev-2", 1.0, 1.0),
        evaluation(plan, a, "a-dev-2-second", "dev-2", 1.0, 1.0),
        evaluation(plan, a, "a-val-1", "val-1", 0.0, 1.0, split: "validation"),
        evaluation(plan, b, "b-val-1", "val-1", 1.0, 1.0, split: "validation")
      ]

      assert Comparison.outcomes(plan, evaluations, policy) == %{
               "a" => %{
                 "dev-1" => %{"success" => false, "evaluation_id" => "a-dev-1-second"},
                 "dev-2" => %{"success" => true, "evaluation_id" => "a-dev-2-second"}
               }
             }
    end

    test "success is the policy's judgement, not a hard-coded threshold" do
      plan = plan()
      a = candidate(plan, "a", "a bytes", parents: [seed_parent(plan)])
      evaluations = [evaluation(plan, a, "a-dev-1", "dev-1", 0.5, 1.0)]

      strict = Comparison.outcomes(plan, evaluations, Policy.read(plan))
      assert strict["a"]["dev-1"]["success"] == false

      lenient =
        Comparison.outcomes(plan, evaluations, Policy.read(plan, %{"success_threshold" => 0.5}))

      assert lenient["a"]["dev-1"]["success"] == true
    end
  end

  describe "reaction_norm/4" do
    test "needs at least two development failures and lists them sorted by case id" do
      plan = plan()
      policy = Policy.read(plan)
      a = candidate(plan, "a", "a bytes", parents: [seed_parent(plan)])

      one = [failed(plan, a, "dev-2")]
      assert Comparison.reaction_norm(plan, "a", one, policy) == :ineligible

      two = [failed(plan, a, "dev-3"), passed(plan, a, "dev-2"), failed(plan, a, "dev-1")]

      assert Comparison.reaction_norm(plan, "a", two, policy) ==
               {:ok,
                %{
                  "operator" => "reaction_norm",
                  "candidate_id" => "a",
                  "failed_case_ids" => ["dev-1", "dev-3"],
                  "evaluation_ids" => ["a/dev-1", "a/dev-3"]
                }}

      assert Comparison.reaction_norm(plan, "unknown", two, policy) == :ineligible
    end
  end

  describe "cross_lineage/5" do
    test "prefers a succeeding reference, tie-breaks by lowest id, and flags a failing fallback" do
      plan = plan()
      policy = Policy.read(plan)
      target = candidate(plan, "target", "target bytes", parents: [seed_parent(plan)])
      a = candidate(plan, "a", "a bytes", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b bytes", parents: [seed_parent(plan)])
      c = candidate(plan, "c", "c bytes", parents: [seed_parent(plan)])
      candidates = [target, a, b, c]

      evaluations = [
        failed(plan, target, "dev-1"),
        failed(plan, target, "dev-2"),
        failed(plan, target, "dev-3"),
        # dev-1: a fails while b and c succeed, so b wins over the lower id a.
        failed(plan, a, "dev-1"),
        passed(plan, c, "dev-1"),
        passed(plan, b, "dev-1"),
        # dev-2: nobody succeeds, so the lowest failing id is used and flagged.
        failed(plan, c, "dev-2"),
        failed(plan, b, "dev-2")
        # dev-3: nobody else was evaluated, so there is no pair.
      ]

      assert {:ok, evidence} =
               Comparison.cross_lineage(plan, "target", candidates, evaluations, policy)

      assert evidence["operator"] == "cross_lineage"
      assert evidence["candidate_id"] == "target"

      assert evidence["pairs"] == [
               %{
                 "case_id" => "dev-1",
                 "target_evaluation_id" => "target/dev-1",
                 "reference_candidate_id" => "b",
                 "reference_evaluation_id" => "b/dev-1",
                 "reference_success" => true
               },
               %{
                 "case_id" => "dev-2",
                 "target_evaluation_id" => "target/dev-2",
                 "reference_candidate_id" => "b",
                 "reference_evaluation_id" => "b/dev-2",
                 "reference_success" => false
               }
             ]
    end

    test "is ineligible without a failure that another listed candidate has seen" do
      plan = plan()
      policy = Policy.read(plan)
      target = candidate(plan, "target", "target bytes", parents: [seed_parent(plan)])
      other = candidate(plan, "other", "other bytes", parents: [seed_parent(plan)])

      unseen = [failed(plan, target, "dev-1"), passed(plan, other, "dev-2")]

      assert Comparison.cross_lineage(plan, "target", [target, other], unseen, policy) ==
               :ineligible

      solved = [passed(plan, target, "dev-1"), passed(plan, other, "dev-1")]

      assert Comparison.cross_lineage(plan, "target", [target, other], solved, policy) ==
               :ineligible

      seen = [failed(plan, target, "dev-1"), passed(plan, other, "dev-1")]
      assert Comparison.cross_lineage(plan, "target", [target], seen, policy) == :ineligible

      assert {:ok, _evidence} =
               Comparison.cross_lineage(plan, "target", [target, other], seen, policy)
    end
  end

  describe "eligible_operators/5" do
    test "offers clonal on one failure, comparative operators on their evidence, consolidate by policy" do
      plan = plan()
      policy = Policy.read(plan)
      target = candidate(plan, "target", "target bytes", parents: [seed_parent(plan)])
      other = candidate(plan, "other", "other bytes", parents: [seed_parent(plan)])
      candidates = [target, other]

      solved = [passed(plan, target, "dev-1")]
      assert Comparison.eligible_operators(plan, "target", candidates, solved, policy) == []

      one_failure = [failed(plan, target, "dev-1")]

      assert Comparison.eligible_operators(plan, "target", candidates, one_failure, policy) == [
               {"clonal",
                %{
                  "operator" => "clonal",
                  "candidate_id" => "target",
                  "failed_case_ids" => ["dev-1"],
                  "evaluation_ids" => ["target/dev-1"]
                }}
             ]

      full = [
        failed(plan, target, "dev-2"),
        failed(plan, target, "dev-1"),
        passed(plan, other, "dev-1")
      ]

      eligible = Comparison.eligible_operators(plan, "target", candidates, full, policy)
      assert Enum.map(eligible, &elem(&1, 0)) == ["clonal", "reaction_norm", "cross_lineage"]

      assert Enum.all?(eligible, fn {operator, evidence} ->
               evidence["operator"] == operator and evidence["candidate_id"] == "target"
             end)

      consolidating = Policy.read(plan, %{"consolidate_enabled" => true})

      assert Comparison.eligible_operators(plan, "target", candidates, solved, consolidating) == [
               {"consolidate", %{"operator" => "consolidate", "candidate_id" => "target"}}
             ]

      assert plan
             |> Comparison.eligible_operators("target", candidates, full, consolidating)
             |> Enum.map(&elem(&1, 0)) ==
               ["clonal", "reaction_norm", "cross_lineage", "consolidate"]
    end
  end

  describe "select_operator/3" do
    test "is deterministic for a seeded state and never picks a zero-weight operator" do
      plan = plan()
      eligible = eligible_fixture()

      policy =
        Policy.read(plan, %{"operator_weights" => %{"clonal" => 1.0, "reaction_norm" => 1.0}})

      rng = :rand.seed_s(:exsss, {1, 2, 3})

      assert {{_operator, _evidence} = first, advanced} =
               Comparison.select_operator(eligible, policy, rng)

      refute advanced == rng

      assert {^first, ^advanced} =
               Comparison.select_operator(eligible, policy, :rand.seed_s(:exsss, {1, 2, 3}))

      {picks, _rng} =
        Enum.map_reduce(1..64, rng, fn _draw, rng ->
          {{operator, _evidence}, rng} = Comparison.select_operator(eligible, policy, rng)
          {operator, rng}
        end)

      assert picks |> Enum.uniq() |> Enum.sort() == ["clonal", "reaction_norm"]
    end

    test "returns :none with the untouched state when nothing carries weight" do
      plan = plan()
      rng = :rand.seed_s(:exsss, {4, 5, 6})

      assert Comparison.select_operator([], Policy.read(plan), rng) == {:none, rng}

      zeroed = Policy.read(plan, %{"operator_weights" => %{"clonal" => 0, "cross_lineage" => -1}})
      assert Comparison.select_operator(eligible_fixture(), zeroed, rng) == {:none, rng}

      unweighted = Policy.read(plan, %{"operator_weights" => %{}})
      assert Comparison.select_operator(eligible_fixture(), unweighted, rng) == {:none, rng}
    end

    test "weight decides the draw, so a dominant weight wins a seeded draw" do
      plan = plan()
      eligible = eligible_fixture()
      rng = :rand.seed_s(:exsss, {7, 8, 9})

      clonal_only = Policy.read(plan, %{"operator_weights" => %{"clonal" => 1.0}})

      assert {{"clonal", _evidence}, _rng} =
               Comparison.select_operator(eligible, clonal_only, rng)

      norm_only = Policy.read(plan, %{"operator_weights" => %{"reaction_norm" => 1.0}})

      assert {{"reaction_norm", _evidence}, _rng} =
               Comparison.select_operator(eligible, norm_only, rng)
    end
  end

  describe "acceptance_by_operator/2" do
    test "counts proposals and frontier members per mutation kind" do
      plan = plan()
      opts = [parents: [seed_parent(plan)]]
      clonal_a = candidate(plan, "clonal-a", "clonal a", opts ++ [mutation_kind: "clonal"])
      clonal_b = candidate(plan, "clonal-b", "clonal b", opts ++ [mutation_kind: "clonal"])
      norm_a = candidate(plan, "norm-a", "norm a", opts ++ [mutation_kind: "reaction_norm"])
      cross_a = candidate(plan, "cross-a", "cross a", opts ++ [mutation_kind: "cross_lineage"])
      candidates = [clonal_a, clonal_b, norm_a, cross_a]

      evaluations = [
        evaluation(plan, clonal_a, "clonal-a-eval", "dev-1", 1.0, 5.0),
        evaluation(plan, clonal_b, "clonal-b-eval", "dev-1", 0.5, 6.0),
        evaluation(plan, norm_a, "norm-a-eval", "dev-1", 0.8, 1.0)
      ]

      assert {:ok, frontier} = Frontier.compute(plan, candidates, evaluations)
      assert Enum.map(frontier.members, & &1["candidate_id"]) == ["clonal-a", "norm-a"]

      assert Comparison.acceptance_by_operator(candidates, frontier) == %{
               "clonal" => %{"proposed" => 2, "frontier_members" => 1},
               "reaction_norm" => %{"proposed" => 1, "frontier_members" => 1},
               "cross_lineage" => %{"proposed" => 1, "frontier_members" => 0}
             }
    end
  end

  defp eligible_fixture do
    [
      {"clonal", %{"operator" => "clonal", "candidate_id" => "target"}},
      {"reaction_norm", %{"operator" => "reaction_norm", "candidate_id" => "target"}},
      {"cross_lineage", %{"operator" => "cross_lineage", "candidate_id" => "target"}}
    ]
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
