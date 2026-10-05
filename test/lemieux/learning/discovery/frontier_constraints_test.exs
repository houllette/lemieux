defmodule Lemieux.Learning.Discovery.FrontierConstraintsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan

  @mechanical %{"id" => "safe", "kind" => "mechanical"}
  @no_regression %{"id" => "seesaw", "kind" => "no_solved_regression"}
  @cases ~w(dev-1 dev-2 dev-3 dev-4)

  # Parent solves dev-1 and dev-2; the child lifts the mean from 0.5 to 0.75
  # by solving dev-3 and dev-4 while dropping dev-2.
  @parent_scores %{"dev-1" => 1.0, "dev-2" => 1.0, "dev-3" => 0.0, "dev-4" => 0.0}
  @seesaw_scores %{"dev-1" => 1.0, "dev-2" => 0.0, "dev-3" => 1.0, "dev-4" => 1.0}

  describe "no_solved_regression" do
    test "excludes a child that lifts the mean but fails a case its parent solved" do
      plan = plan(constraints: [@mechanical, @no_regression])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])
      evaluations = scored(plan, parent, @parent_scores) ++ scored(plan, child, @seesaw_scores)

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert members(frontier) == ["parent"]
      assert excluded(frontier) == %{"child" => "solved_regression"}
      assert {:ok, ^frontier} = frontier |> Frontier.encode!() |> then(&Frontier.decode(plan, &1))
    end

    test "without the constraint the regressing child dominates its parent" do
      plan = plan(constraints: [@mechanical])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])
      evaluations = scored(plan, parent, @parent_scores) ++ scored(plan, child, @seesaw_scores)

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert members(frontier) == ["child"]
      assert excluded(frontier) == %{}
    end

    test "failing a case the parent also failed is not a regression" do
      plan = plan(constraints: [@mechanical, @no_regression])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])
      child_scores = %{"dev-1" => 1.0, "dev-2" => 1.0, "dev-3" => 0.0, "dev-4" => 0.0}
      evaluations = scored(plan, parent, @parent_scores) ++ scored(plan, child, child_scores)

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert members(frontier) == ["child", "parent"]
      assert excluded(frontier) == %{}
    end

    test "seed-parented candidates are never regressions" do
      plan = plan(constraints: [@mechanical, @no_regression])
      only = candidate(plan, "only", "only bytes", parents: [seed_parent(plan)])
      scores = %{"dev-1" => 0.0, "dev-2" => 0.0, "dev-3" => 0.0, "dev-4" => 0.0}

      assert {:ok, frontier} = Frontier.compute(plan, [only], scored(plan, only, scores))
      assert members(frontier) == ["only"]
      assert excluded(frontier) == %{}
    end

    test "a case the parent never ran is not solved" do
      plan = plan(constraints: [@mechanical, @no_regression])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])

      evaluations =
        scored(plan, parent, %{"dev-1" => 1.0}) ++
          scored(plan, child, %{"dev-1" => 1.0, "dev-2" => 0.0})

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      # Dominated on the mean, so not a member, but never excluded as a regression.
      assert excluded(frontier) == %{}
      assert members(frontier) == ["parent"]
    end

    test "a case is solved only when every parent evaluation on it succeeds" do
      plan = plan(constraints: [@mechanical, @no_regression])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])

      evaluations = [
        evaluation(plan, parent, "parent-dev-1-first", 1.0, 1.0, case_id: "dev-1"),
        evaluation(plan, parent, "parent-dev-1-second", 0.0, 1.0, case_id: "dev-1"),
        evaluation(plan, child, "child-dev-1", 0.0, 1.0, case_id: "dev-1")
      ]

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert excluded(frontier) == %{}
    end

    test "the first candidate parent is the reference even when a seed is listed first" do
      plan = plan(constraints: [@mechanical, @no_regression])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])

      child =
        candidate(plan, "child", "child bytes", parents: [seed_parent(plan), parent(parent)])

      evaluations = scored(plan, parent, @parent_scores) ++ scored(plan, child, @seesaw_scores)

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert excluded(frontier) == %{"child" => "solved_regression"}
    end

    test "reads the success threshold from the search policy" do
      constraints = [@mechanical, @no_regression]
      relaxed = plan(constraints: constraints, extensions: search(0.5))
      strict = plan(constraints: constraints)

      for {plan, expected} <- [{relaxed, %{"child" => "solved_regression"}}, {strict, %{}}] do
        parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
        child = candidate(plan, "child", "child bytes", parents: [parent(parent)])

        evaluations =
          scored(plan, parent, %{"dev-1" => 0.6}) ++ scored(plan, child, %{"dev-1" => 0.4})

        assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
        assert excluded(frontier) == expected
      end
    end

    test "a constraint threshold overrides the policy for that constraint only" do
      constraint = Map.put(@no_regression, "threshold", 0.5)
      plan = plan(constraints: [@mechanical, constraint])
      parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child bytes", parents: [parent(parent)])

      evaluations =
        scored(plan, parent, %{"dev-1" => 0.6}) ++ scored(plan, child, %{"dev-1" => 0.4})

      assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
      assert excluded(frontier) == %{"child" => "solved_regression"}
    end
  end

  test "scores are means over cases, so a case run three times weighs the same as one run once" do
    plan = plan(constraints: [@mechanical])
    repeated = candidate(plan, "repeated", "repeated bytes", parents: [seed_parent(plan)])

    evaluations = [
      evaluation(plan, repeated, "dev-1-first", 1.0, 3.0, case_id: "dev-1"),
      evaluation(plan, repeated, "dev-1-second", 1.0, 3.0, case_id: "dev-1"),
      evaluation(plan, repeated, "dev-1-third", 1.0, 3.0, case_id: "dev-1"),
      evaluation(plan, repeated, "dev-2-only", 0.0, 1.0, case_id: "dev-2")
    ]

    assert {:ok, frontier} = Frontier.compute(plan, [repeated], evaluations)
    assert [%{"scores" => scores}] = frontier.members
    # A plain mean over the four evaluations would say 0.75 and 2.5.
    assert scores == %{"quality" => 0.5, "cost" => 2.0}
  end

  describe "max_content_bytes" do
    test "excludes candidates whose content exceeds the declared size" do
      size = %{"id" => "size", "kind" => "max_content_bytes", "value" => 10}
      plan = plan(constraints: [@mechanical, size])
      small = candidate(plan, "small", "0123456789", parents: [seed_parent(plan)])
      large = candidate(plan, "large", "0123456789!", parents: [seed_parent(plan)])

      evaluations =
        scored(plan, small, %{"dev-1" => 1.0}) ++ scored(plan, large, %{"dev-1" => 1.0})

      assert {:ok, frontier} = Frontier.compute(plan, [small, large], evaluations)
      assert members(frontier) == ["small"]
      assert excluded(frontier) == %{"large" => "content_too_large"}
    end

    test "a malformed value fails the computation instead of passing every candidate" do
      size = %{"id" => "size", "kind" => "max_content_bytes", "value" => "big"}
      plan = plan(constraints: [@mechanical, size])
      only = candidate(plan, "only", "only bytes", parents: [seed_parent(plan)])

      assert {:error, {:invalid_hard_constraint, "size"}} =
               Frontier.compute(plan, [only], scored(plan, only, %{"dev-1" => 1.0}))
    end
  end

  test "legacy and unknown constraint kinds are ignored" do
    plan = plan(constraints: [@mechanical, %{"id" => "review", "kind" => "human_review"}])
    parent = candidate(plan, "parent", "parent bytes", parents: [seed_parent(plan)])
    child = candidate(plan, "child", "child bytes", parents: [parent(parent)])
    evaluations = scored(plan, parent, @parent_scores) ++ scored(plan, child, @seesaw_scores)

    assert {:ok, frontier} = Frontier.compute(plan, [parent, child], evaluations)
    assert members(frontier) == ["child"]
    assert excluded(frontier) == %{}
  end

  test "constraint gates report after the interface and evidence gates" do
    size = %{"id" => "size", "kind" => "max_content_bytes", "value" => 1}
    plan = plan(constraints: [@mechanical, size, @no_regression])

    invalid =
      candidate(plan, "invalid", "too large", interface: "failed", parents: [seed_parent(plan)])

    silent = candidate(plan, "silent", "too large", parents: [seed_parent(plan)])

    assert {:ok, frontier} =
             Frontier.compute(plan, [invalid, silent], scored(plan, invalid, %{"dev-1" => 1.0}))

    assert excluded(frontier) == %{"invalid" => "interface_invalid", "silent" => "no_evaluations"}
  end

  defp members(frontier), do: Enum.map(frontier.members, & &1["candidate_id"])
  defp excluded(frontier), do: Map.new(frontier.excluded, &{&1["candidate_id"], &1["reason"]})

  defp search(threshold), do: %{"search" => %{"success_threshold" => threshold}}

  defp scored(plan, candidate, scores) do
    Enum.map(scores, fn {case_id, quality} ->
      evaluation(plan, candidate, "#{candidate.id}-#{case_id}", quality, 1.0, case_id: case_id)
    end)
  end

  defp plan(opts) do
    assert {:ok, plan} = Plan.new(plan_attrs(opts))
    plan
  end

  defp plan_attrs(opts) do
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
      "development_case_ids" => @cases,
      "validation_case_ids" => ["val-1"],
      "objectives" => [
        %{"name" => "quality", "direction" => "maximize"},
        %{"name" => "cost", "direction" => "minimize"}
      ],
      "hard_constraints" => Keyword.get(opts, :constraints, [@mechanical]),
      "interface_validator" => %{"id" => "validator-v1", "sha256" => String.duplicate("c", 64)},
      "budget" => %{
        "maximum_candidates" => 20,
        "maximum_tokens" => 10_000,
        "maximum_cost_usd" => 100.0,
        "maximum_time_ms" => 60_000
      },
      "extensions" => Keyword.get(opts, :extensions, %{})
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
      "mutation_kind" => "asset"
    }

    assert {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp evaluation(plan, candidate, id, quality, cost, opts) do
    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "case_id" => Keyword.get(opts, :case_id, "dev-1"),
      "split" => "development",
      "objectives" => %{"quality" => quality, "cost" => cost},
      "safety" => %{"passed" => true, "failures" => []},
      "completeness" => %{
        "usage" => "complete",
        "cost" => "complete",
        "sandbox" => "complete",
        "artifacts" => "complete"
      },
      "usage" => %{"total_tokens" => 10},
      "cost" => %{"usd" => cost},
      "latency" => %{"milliseconds" => 5},
      "artifacts" => [],
      "within_budget" => true,
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
