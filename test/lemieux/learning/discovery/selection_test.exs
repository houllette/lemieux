defmodule Lemieux.Learning.Discovery.SelectionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Discovery.Selection

  @dev_cases ["dev-1", "dev-2", "dev-3", "dev-4"]

  describe "posteriors/4" do
    test "counts node and clade outcomes on the development split under the prior" do
      plan = plan()
      parent = candidate(plan, "parent", "parent", parents: [seed_parent(plan)])
      child = candidate(plan, "child", "child", parents: [parent(parent)])
      grandchild = candidate(plan, "grandchild", "grandchild", parents: [parent(child)])
      unrelated = candidate(plan, "unrelated", "unrelated", parents: [seed_parent(plan)])
      candidates = [unrelated, grandchild, child, parent]

      evaluations = [
        pass(plan, parent, "dev-1"),
        pass(plan, parent, "dev-2"),
        fail(plan, parent, "dev-3"),
        fail(plan, child, "dev-1"),
        pass(plan, grandchild, "dev-1"),
        pass(plan, unrelated, "val-1", split: "validation")
      ]

      posteriors = Selection.posteriors(plan, candidates, evaluations, Policy.read(plan))

      assert Enum.sort(Map.keys(posteriors)) == ["child", "grandchild", "parent", "unrelated"]

      assert %{
               "successes" => 2,
               "failures" => 1,
               "alpha" => 3,
               "beta" => 2,
               "mean" => 0.6,
               "clade_successes" => 3,
               "clade_failures" => 2,
               "clade_alpha" => 4,
               "clade_beta" => 3
             } = posteriors["parent"]

      assert_in_delta posteriors["parent"]["clade_mean"], 4 / 7, 1.0e-9

      assert %{"successes" => 0, "failures" => 1, "clade_successes" => 1, "clade_failures" => 1} =
               posteriors["child"]

      assert %{"successes" => 1, "failures" => 0, "clade_successes" => 1, "clade_failures" => 0} =
               posteriors["grandchild"]

      assert %{"alpha" => 1, "beta" => 1, "mean" => 0.5, "clade_alpha" => 1, "clade_beta" => 1} =
               posteriors["unrelated"]
    end

    test "the prior comes from the policy" do
      plan = plan()
      solo = candidate(plan, "solo", "solo", parents: [seed_parent(plan)])
      policy = Policy.read(plan, %{"prior" => [2, 5]})

      posteriors = Selection.posteriors(plan, [solo], [pass(plan, solo, "dev-1")], policy)

      assert %{"alpha" => 3, "beta" => 5, "clade_alpha" => 3, "clade_beta" => 5} =
               posteriors["solo"]

      assert_in_delta posteriors["solo"]["mean"], 3 / 8, 1.0e-9
    end
  end

  describe "sample_beta/3" do
    test "is deterministic for one rng state and stays inside the unit interval" do
      rng = :rand.seed_s(:exsss, 42)

      assert {draw, rng_after} = Selection.sample_beta(2, 3, rng)
      assert {^draw, ^rng_after} = Selection.sample_beta(2, 3, rng)
      assert draw > 0.0 and draw < 1.0
      refute rng_after == rng
    end

    test "draws average to the Beta mean for shapes above and below one" do
      assert_in_delta average_draw(2, 1, 4000), 2 / 3, 0.03
      assert_in_delta average_draw(0.5, 0.5, 4000), 0.5, 0.03
      assert_in_delta average_draw(0.5, 2, 4000), 0.2, 0.03
    end
  end

  describe "discrimination/4" do
    test "is the population variance of the per-candidate success indicator" do
      plan = plan()
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b", parents: [seed_parent(plan)])

      evaluations = [
        pass(plan, a, "dev-1"),
        fail(plan, b, "dev-1"),
        pass(plan, a, "dev-2"),
        pass(plan, a, "dev-3"),
        pass(plan, b, "dev-3"),
        pass(plan, a, "dev-4", id: "a-dev-4-first"),
        fail(plan, a, "dev-4", id: "a-dev-4-second"),
        fail(plan, b, "dev-4")
      ]

      discrimination = Selection.discrimination(plan, [a, b], evaluations, Policy.read(plan))

      assert Enum.sort(Map.keys(discrimination)) == @dev_cases
      assert_in_delta discrimination["dev-1"], 0.25, 1.0e-9
      assert discrimination["dev-2"] == 0.0
      assert discrimination["dev-3"] == 0.0
      assert_in_delta discrimination["dev-4"], 0.0625, 1.0e-9
    end
  end

  describe "evaluated_case_ids/2" do
    test "lists the candidate's development cases sorted and without repeats" do
      plan = plan()
      solo = candidate(plan, "solo", "solo", parents: [seed_parent(plan)])
      other = candidate(plan, "other", "other", parents: [seed_parent(plan)])

      evaluations = [
        pass(plan, solo, "dev-3"),
        pass(plan, solo, "dev-1"),
        fail(plan, solo, "dev-1", id: "solo-dev-1-again"),
        pass(plan, solo, "val-1", split: "validation"),
        pass(plan, other, "dev-2")
      ]

      assert Selection.evaluated_case_ids("solo", evaluations) == ["dev-1", "dev-3"]
      assert Selection.evaluated_case_ids("missing", evaluations) == []
    end
  end

  describe "select_parent/5" do
    test "falls back to the first seed when nothing is evaluable" do
      plan = plan()
      fresh = candidate(plan, "fresh", "fresh", parents: [seed_parent(plan)])
      rng = :rand.seed_s(:exsss, 1)
      seed = hd(plan.seeds)

      assert {{:seed, ^seed}, ^rng} =
               Selection.select_parent(plan, [], [], Policy.read(plan), rng)

      assert {{:seed, ^seed}, ^rng} =
               Selection.select_parent(plan, [fresh], [], Policy.read(plan), rng)
    end

    test "clade sampling prefers the lineage whose descendants succeed" do
      plan = plan()
      strong = candidate(plan, "strong", "strong", parents: [seed_parent(plan)])
      strong_a = candidate(plan, "strong-a", "strong a", parents: [parent(strong)])
      strong_b = candidate(plan, "strong-b", "strong b", parents: [parent(strong)])
      modest = candidate(plan, "modest", "modest", parents: [seed_parent(plan)])
      modest_a = candidate(plan, "modest-a", "modest a", parents: [parent(modest)])
      modest_b = candidate(plan, "modest-b", "modest b", parents: [parent(modest)])
      candidates = [strong, strong_a, strong_b, modest, modest_a, modest_b]

      evaluations =
        Enum.map(@dev_cases, &pass(plan, strong, &1)) ++
          Enum.map(@dev_cases, &fail(plan, strong_a, &1)) ++
          Enum.map(@dev_cases, &fail(plan, strong_b, &1)) ++
          Enum.map(["dev-1", "dev-2"], &pass(plan, modest, &1)) ++
          Enum.map(["dev-3", "dev-4"], &fail(plan, modest, &1)) ++
          Enum.map(@dev_cases, &pass(plan, modest_a, &1)) ++
          Enum.map(@dev_cases, &pass(plan, modest_b, &1))

      clade = tally_parents(plan, candidates, evaluations, Policy.read(plan, %{"clade" => true}))
      node = tally_parents(plan, candidates, evaluations, Policy.read(plan, %{"clade" => false}))

      assert clade["modest"] > clade["strong"]
      assert node["strong"] > node["modest"]
    end

    test "never selects vetoed or interface-failed candidates" do
      plan = plan()

      vetoed =
        candidate(plan, "vetoed", "vetoed",
          parents: [seed_parent(plan)],
          extensions: %{"critic" => %{"verdict" => "veto"}}
        )

      broken =
        candidate(plan, "broken", "broken", parents: [seed_parent(plan)], interface: "failed")

      ok = candidate(plan, "ok", "ok", parents: [seed_parent(plan)])
      candidates = [vetoed, broken, ok]

      evaluations =
        Enum.map(@dev_cases, &pass(plan, vetoed, &1)) ++
          Enum.map(@dev_cases, &pass(plan, broken, &1)) ++
          [fail(plan, ok, "dev-1")]

      tally = tally_parents(plan, candidates, evaluations, Policy.read(plan))
      assert tally == %{"ok" => 200, "vetoed" => 0, "broken" => 0}

      seed = hd(plan.seeds)

      assert {{:seed, ^seed}, _rng} =
               Selection.select_parent(
                 plan,
                 [vetoed, broken],
                 evaluations,
                 Policy.read(plan),
                 :rand.seed_s(:exsss, 0)
               )
    end
  end

  describe "next_action/5" do
    test "is deterministic under one seed and varies across seeds" do
      plan = plan(%{"budget" => budget(2)})
      x = candidate(plan, "x", "x", parents: [seed_parent(plan)])
      y = candidate(plan, "y", "y", parents: [seed_parent(plan)])
      policy = Policy.read(plan, %{"fidelity_tiers" => [1, 4]})

      first = Selection.next_action(plan, [x, y], [], policy, :rand.seed_s(:exsss, 7))
      second = Selection.next_action(plan, [x, y], [], policy, :rand.seed_s(:exsss, 7))
      assert first == second
      assert {{:evaluate, id, [case_id]}, _rng} = first
      assert id in ["x", "y"]
      assert case_id in @dev_cases

      distinct =
        0..39
        |> Enum.map(fn seed ->
          {action, _rng} =
            Selection.next_action(plan, [x, y], [], policy, :rand.seed_s(:exsss, seed))

          action
        end)
        |> Enum.uniq()

      assert length(distinct) > 1
    end

    test "does not depend on the order candidates or evaluations arrive in" do
      plan = plan()
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b", parents: [parent(a)])
      c = candidate(plan, "c", "c", parents: [seed_parent(plan)])
      candidates = [a, b, c]

      evaluations = [
        pass(plan, a, "dev-1"),
        fail(plan, a, "dev-2"),
        pass(plan, b, "dev-1"),
        pass(plan, c, "dev-1"),
        fail(plan, c, "dev-3")
      ]

      policy = Policy.read(plan, %{"fidelity_tiers" => [2, 4], "widening_alpha" => 0.3})
      reversed_candidates = Enum.reverse(candidates)
      reversed_evaluations = Enum.reverse(evaluations)

      for seed <- 0..29 do
        rng = :rand.seed_s(:exsss, seed)

        assert Selection.next_action(plan, candidates, evaluations, policy, rng) ==
                 Selection.next_action(
                   plan,
                   reversed_candidates,
                   reversed_evaluations,
                   policy,
                   rng
                 )

        assert Selection.select_parent(plan, candidates, evaluations, policy, rng) ==
                 Selection.select_parent(
                   plan,
                   reversed_candidates,
                   reversed_evaluations,
                   policy,
                   rng
                 )
      end

      assert {{:evaluate, _id, _ids}, _rng} =
               Selection.next_action(
                 plan,
                 candidates,
                 evaluations,
                 policy,
                 :rand.seed_s(:exsss, 0)
               )
    end

    test "expands from the seed when the archive is empty" do
      plan = plan()
      seed = hd(plan.seeds)
      rng = :rand.seed_s(:exsss, 0)

      assert {{:expand, {:seed, ^seed}}, ^rng} =
               Selection.next_action(plan, [], [], Policy.read(plan), rng)
    end

    test "evaluates a pending candidate before expanding when nothing is evaluable yet" do
      plan = plan()
      fresh = candidate(plan, "fresh", "fresh", parents: [seed_parent(plan)])
      rng = :rand.seed_s(:exsss, 0)

      assert {{:evaluate, "fresh", ids}, _rng} =
               Selection.next_action(plan, [fresh], [], Policy.read(plan), rng)

      assert ids == @dev_cases
    end

    test "widening compares accumulated evaluations to the admissible archive" do
      plan = plan()
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b", parents: [seed_parent(plan)])
      policy = Policy.read(plan, %{"widening_alpha" => 0.5})
      rng = :rand.seed_s(:exsss, 3)

      four = [
        pass(plan, a, "dev-1"),
        pass(plan, a, "dev-2"),
        pass(plan, b, "dev-1"),
        fail(plan, b, "dev-2")
      ]

      assert {{:expand, {:candidate, id}}, _rng} =
               Selection.next_action(plan, [a, b], four, policy, rng)

      assert id in ["a", "b"]

      three = Enum.take(four, 3)

      assert {{:evaluate, id, ids}, _rng} =
               Selection.next_action(plan, [a, b], three, policy, rng)

      assert id in ["a", "b"]
      assert ids != []

      # An unevaluated sibling counts toward V: with four evaluations and a
      # third admissible candidate, 4^0.5 = 2 < 3, so the next step evaluates.
      c = candidate(plan, "c", "c", parents: [seed_parent(plan)])

      assert {{:evaluate, id, _ids}, _rng} =
               Selection.next_action(plan, [a, b, c], four, policy, rng)

      assert id in ["b", "c"]
    end

    test "never expands past the candidate budget and finishes when nothing is pending" do
      plan = plan(%{"budget" => budget(2)})
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      b = candidate(plan, "b", "b", parents: [seed_parent(plan)])
      policy = Policy.read(plan)
      rng = :rand.seed_s(:exsss, 5)

      complete =
        Enum.map(@dev_cases, &pass(plan, a, &1)) ++ Enum.map(@dev_cases, &pass(plan, b, &1))

      assert {:done, ^rng} = Selection.next_action(plan, [a, b], complete, policy, rng)

      almost = Enum.reject(complete, &(&1.candidate_id == "b" and &1.case_id == "dev-4"))

      assert {{:evaluate, "b", ["dev-4"]}, _rng} =
               Selection.next_action(plan, [a, b], almost, policy, rng)
    end

    test "expands once every admissible candidate is fully evaluated" do
      plan = plan()
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      policy = Policy.read(plan, %{"widening_alpha" => 0.0})
      rng = :rand.seed_s(:exsss, 5)
      complete = Enum.map(@dev_cases, &pass(plan, a, &1))

      assert {{:expand, {:candidate, "a"}}, _rng} =
               Selection.next_action(plan, [a], complete, policy, rng)
    end

    test "never evaluates vetoed or interface-failed candidates" do
      plan = plan(%{"budget" => budget(3)})

      vetoed =
        candidate(plan, "vetoed", "vetoed",
          parents: [seed_parent(plan)],
          extensions: %{"critic" => %{"verdict" => "veto"}}
        )

      broken =
        candidate(plan, "broken", "broken", parents: [seed_parent(plan)], interface: "failed")

      ok = candidate(plan, "ok", "ok", parents: [seed_parent(plan)])
      candidates = [vetoed, broken, ok]
      evaluations = [pass(plan, ok, "dev-1")]
      policy = Policy.read(plan)

      for seed <- 0..49 do
        assert {{:evaluate, "ok", ids}, _rng} =
                 Selection.next_action(
                   plan,
                   candidates,
                   evaluations,
                   policy,
                   :rand.seed_s(:exsss, seed)
                 )

        assert ids == ["dev-2", "dev-3", "dev-4"]
      end

      seed = hd(plan.seeds)

      assert {{:expand, {:seed, ^seed}}, _rng} =
               Selection.next_action(plan, [vetoed, broken], [], policy, :rand.seed_s(:exsss, 0))
    end

    test "fidelity tiers grow the evaluated case set one tier at a time" do
      plan = plan(%{"budget" => budget(1)})
      solo = candidate(plan, "solo", "solo", parents: [seed_parent(plan)])
      policy = Policy.read(plan, %{"fidelity_tiers" => [1, 3]})
      assert policy["fidelity_tiers"] == [1, 3, 4]

      assert {{:evaluate, "solo", [first]}, rng} =
               Selection.next_action(plan, [solo], [], policy, :rand.seed_s(:exsss, 11))

      evaluations = [pass(plan, solo, first)]

      assert {{:evaluate, "solo", [second, third]}, rng} =
               Selection.next_action(plan, [solo], evaluations, policy, rng)

      assert second < third
      refute first in [second, third]

      evaluations = evaluations ++ [pass(plan, solo, second), fail(plan, solo, third)]

      assert {{:evaluate, "solo", [fourth]}, rng} =
               Selection.next_action(plan, [solo], evaluations, policy, rng)

      assert Enum.sort([first, second, third, fourth]) == @dev_cases

      evaluations = evaluations ++ [pass(plan, solo, fourth)]
      assert {:done, ^rng} = Selection.next_action(plan, [solo], evaluations, policy, rng)
    end

    test "always_case_ids join the first tier even when the tier holds one case" do
      plan = plan(%{"budget" => budget(1)})
      solo = candidate(plan, "solo", "solo", parents: [seed_parent(plan)])
      rng = :rand.seed_s(:exsss, 2)

      one = Policy.read(plan, %{"fidelity_tiers" => [1, 4], "always_case_ids" => ["dev-4"]})

      assert {{:evaluate, "solo", ["dev-4"]}, _rng} =
               Selection.next_action(plan, [solo], [], one, rng)

      two =
        Policy.read(plan, %{"fidelity_tiers" => [1, 4], "always_case_ids" => ["dev-4", "dev-2"]})

      assert {{:evaluate, "solo", ["dev-2", "dev-4"]}, _rng} =
               Selection.next_action(plan, [solo], [], two, rng)

      after_always = [pass(plan, solo, "dev-4")]

      assert {{:evaluate, "solo", rest}, _rng} =
               Selection.next_action(plan, [solo], after_always, one, rng)

      assert rest == ["dev-1", "dev-2", "dev-3"]
    end

    test "cases some candidate failed are sampled more often than unfailed ones" do
      plan = plan()
      old = candidate(plan, "old", "old", parents: [seed_parent(plan)])
      other = candidate(plan, "other", "other", parents: [seed_parent(plan)])
      fresh = candidate(plan, "fresh", "fresh", parents: [seed_parent(plan)])
      candidates = [old, other, fresh]

      evaluations =
        for candidate <- [old, other], case_id <- @dev_cases do
          if case_id == "dev-1",
            do: fail(plan, candidate, case_id),
            else: pass(plan, candidate, case_id)
        end

      policy = Policy.read(plan, %{"fidelity_tiers" => [1, 4], "widening_alpha" => 0.3})
      discrimination = Selection.discrimination(plan, candidates, evaluations, policy)
      assert discrimination["dev-1"] == discrimination["dev-2"]

      tally =
        Enum.reduce(0..199, %{}, fn seed, tally ->
          assert {{:evaluate, "fresh", [case_id]}, _rng} =
                   Selection.next_action(
                     plan,
                     candidates,
                     evaluations,
                     policy,
                     :rand.seed_s(:exsss, seed)
                   )

          Map.update(tally, case_id, 1, &(&1 + 1))
        end)

      assert tally["dev-1"] > tally["dev-2"]
      assert tally["dev-1"] > tally["dev-3"]
      assert tally["dev-1"] > tally["dev-4"]
    end
  end

  describe "summary/4" do
    test "is a JSON-shaped report of the archive" do
      plan = plan()
      a = candidate(plan, "a", "a", parents: [seed_parent(plan)])
      fresh = candidate(plan, "fresh", "fresh", parents: [seed_parent(plan)])

      broken =
        candidate(plan, "broken", "broken", parents: [seed_parent(plan)], interface: "failed")

      evaluations = [
        pass(plan, a, "dev-1"),
        fail(plan, a, "dev-2"),
        pass(plan, a, "val-1", split: "validation")
      ]

      summary = Selection.summary(plan, [a, fresh, broken], evaluations, Policy.read(plan))

      assert summary["development_evaluations"] == 2
      assert summary["evaluable_candidates"] == 1
      assert summary["pending_candidates"] == 2
      assert summary["posteriors"]["a"]["successes"] == 1
      assert summary["posteriors"]["broken"]["failures"] == 0
      assert Enum.sort(Map.keys(summary["discrimination"])) == @dev_cases
      assert {:ok, ^summary} = summary |> Contract.encode!() |> Contract.decode()
    end
  end

  defp tally_parents(plan, candidates, evaluations, policy) do
    zeros = Map.new(candidates, &{&1.id, 0})

    Enum.reduce(0..199, zeros, fn seed, tally ->
      {{:candidate, id}, _rng} =
        Selection.select_parent(plan, candidates, evaluations, policy, :rand.seed_s(:exsss, seed))

      Map.update(tally, id, 1, &(&1 + 1))
    end)
  end

  defp average_draw(alpha, beta, count) do
    {sum, _rng} =
      Enum.reduce(1..count, {0.0, :rand.seed_s(:exsss, 99)}, fn _index, {sum, rng} ->
        {draw, rng} = Selection.sample_beta(alpha, beta, rng)
        assert draw > 0.0 and draw < 1.0
        {sum + draw, rng}
      end)

    sum / count
  end

  defp pass(plan, candidate, case_id, opts \\ []),
    do:
      evaluation(
        plan,
        candidate,
        eval_id(candidate, case_id, opts),
        1.0,
        1.0,
        [case: case_id] ++ opts
      )

  defp fail(plan, candidate, case_id, opts \\ []),
    do:
      evaluation(
        plan,
        candidate,
        eval_id(candidate, case_id, opts),
        0.0,
        1.0,
        [case: case_id] ++ opts
      )

  defp eval_id(candidate, case_id, opts), do: Keyword.get(opts, :id, "#{candidate.id}-#{case_id}")

  defp plan(overrides \\ %{}) do
    assert {:ok, plan} = plan_attrs() |> Map.merge(overrides) |> Plan.new()
    plan
  end

  defp budget(maximum_candidates) do
    %{
      "maximum_candidates" => maximum_candidates,
      "maximum_tokens" => 10_000,
      "maximum_cost_usd" => 100.0,
      "maximum_time_ms" => 60_000
    }
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
      "development_case_ids" => @dev_cases,
      "validation_case_ids" => ["val-1"],
      "objectives" => [
        %{"name" => "quality", "direction" => "maximize"},
        %{"name" => "cost", "direction" => "minimize"}
      ],
      "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
      "interface_validator" => %{"id" => "validator-v1", "sha256" => String.duplicate("c", 64)},
      "budget" => budget(20)
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
      "mutation_kind" => "asset",
      "extensions" => Keyword.get(opts, :extensions, %{})
    }

    assert {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp evaluation(plan, candidate, id, quality, cost, opts) do
    complete = Keyword.get(opts, :complete, true)
    safe = Keyword.get(opts, :safety, true)

    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "case_id" => Keyword.get(opts, :case, "dev-1"),
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
