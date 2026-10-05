defmodule Lemieux.Learning.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Lemieux.Asset.Registry
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Frontier
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Shadow
  alias Lemieux.Learning.Discovery.State

  test "plans freeze disjoint proposer-visible corpora, immutable configurations, and total budgets" do
    assert {:ok, plan} = Plan.new(plan_attrs())
    refute Plan.encode!(plan) =~ "holdout"
    assert {:ok, ^plan} = plan |> Plan.encode!() |> Plan.decode()

    assert {:error, :overlapping_development_validation_cases} =
             plan_attrs()
             |> Map.put("validation_case_ids", ["dev-1"])
             |> Plan.new()

    assert {:error, {:missing_budget_fields, ["maximum_cost_usd"]}} =
             plan_attrs()
             |> update_in(["budget"], &Map.delete(&1, "maximum_cost_usd"))
             |> Plan.new()

    assert {:error, {:mutable_or_missing_configuration, "proposer"}} =
             plan_attrs() |> put_in(["proposer"], %{"id" => "latest"}) |> Plan.new()

    assert {:error, {:mutable_or_missing_configuration, "interface_validator"}} =
             plan_attrs() |> put_in(["interface_validator"], %{}) |> Plan.new()

    assert {:error, :invalid_plan_seeds} =
             plan_attrs() |> put_in(["seeds", Access.at(0)], %{"id" => "mutable"}) |> Plan.new()

    assert {:error, :holdout_not_proposer_visible} =
             plan_attrs() |> Map.put("holdout_case_ids", ["secret"]) |> Plan.new()
  end

  test "candidate lineage resolves immutable parent content and rejects cycles and mismatches" do
    plan = plan()
    first = candidate(plan, "first", "first bytes", parents: [seed_parent(plan)])
    second = candidate(plan, "second", "second bytes", parents: [parent(first)])

    assert Candidate.verify_lineage([second, first], plan.seeds) == :ok
    assert {:ok, ^second} = second |> Candidate.encode!() |> then(&Candidate.decode(plan, &1))

    mismatched = %{
      second
      | parents: [%{"id" => first.id, "content_sha256" => String.duplicate("f", 64)}]
    }

    assert {:error, {:parent_digest_mismatch, "first"}} =
             Candidate.verify_lineage([first, mismatched], plan.seeds)

    a_bytes = "cycle a"
    b_bytes = "cycle b"
    a_digest = sha(a_bytes)
    b_digest = sha(b_bytes)
    a = candidate(plan, "a", a_bytes, parents: [%{"id" => "b", "content_sha256" => b_digest}])
    b = candidate(plan, "b", b_bytes, parents: [%{"id" => "a", "content_sha256" => a_digest}])

    assert {:error, {:candidate_lineage_cycle, _id}} = Candidate.verify_lineage([a, b], [])

    assert {:error, :candidate_proposer_mismatch} =
             Candidate.new(plan, %{
               second
               | proposer: %{"id" => "other", "sha256" => String.duplicate("e", 64)}
             })
  end

  test "frontier is deterministic and hard-invalid candidates never trade safety for score" do
    plan = plan()
    quality = candidate(plan, "quality", "quality", parents: [seed_parent(plan)])
    cheap = candidate(plan, "cheap", "cheap", parents: [seed_parent(plan)])
    dominated = candidate(plan, "dominated", "dominated", parents: [seed_parent(plan)])

    invalid =
      candidate(plan, "invalid", "invalid", interface: "failed", parents: [seed_parent(plan)])

    unsafe = candidate(plan, "unsafe", "unsafe", parents: [seed_parent(plan)])
    incomplete = candidate(plan, "incomplete", "incomplete", parents: [seed_parent(plan)])
    over_budget = candidate(plan, "over-budget", "over", parents: [seed_parent(plan)])
    candidates = [quality, cheap, dominated, invalid, unsafe, incomplete, over_budget]

    evaluations = [
      evaluation(plan, quality, "quality-eval", 1.0, 7.0),
      evaluation(plan, cheap, "cheap-eval", 0.8, 3.0),
      evaluation(plan, dominated, "dominated-eval", 0.5, 8.0),
      evaluation(plan, invalid, "invalid-eval", 100.0, 0.0),
      evaluation(plan, unsafe, "unsafe-eval", 100.0, 0.0, safety: false),
      evaluation(plan, incomplete, "incomplete-eval", 100.0, 0.0, complete: false),
      evaluation(plan, over_budget, "over-eval", 100.0, 0.0, within_budget: false)
    ]

    assert {:ok, frontier} = Frontier.compute(plan, candidates, evaluations)

    assert {:ok, reversed} =
             Frontier.compute(plan, Enum.reverse(candidates), Enum.reverse(evaluations))

    assert Frontier.to_map(frontier) == Frontier.to_map(reversed)
    assert Enum.map(frontier.members, & &1["candidate_id"]) == ["cheap", "quality"]

    excluded = Map.new(frontier.excluded, &{&1["candidate_id"], &1["reason"]})
    assert excluded["invalid"] == "interface_invalid"
    assert excluded["unsafe"] == "safety_failed"
    assert excluded["incomplete"] == "evidence_incomplete"
    assert excluded["over-budget"] == "evidence_incomplete"
    assert excluded["dominated"] == nil
    assert {:ok, ^frontier} = frontier |> Frontier.encode!() |> then(&Frontier.decode(plan, &1))
  end

  test "encoded state resumes without accepting a repeated evaluation" do
    plan = plan()
    candidate = candidate(plan, "candidate", "candidate", parents: [seed_parent(plan)])
    evaluation = evaluation(plan, candidate, "evaluation", 1.0, 1.0)

    assert {:ok, state} = plan |> State.new() |> State.start()

    assert {:error, :digest_mismatch} =
             State.record_candidate(state, plan, %{candidate | mutation_kind: "tampered"}, %{})

    assert {:ok, state} =
             State.record_candidate(state, plan, candidate, %{
               "tokens" => 10,
               "cost_usd" => 0.1,
               "time_ms" => 5
             })

    assert {:ok, state} = State.record_evaluation(state, plan, evaluation)

    assert {:error, :digest_mismatch} =
             Frontier.compute(plan, [candidate], [%{evaluation | within_budget: false}])

    assert {:ok, restored} = state |> State.encode!() |> then(&State.decode(plan, &1))

    assert {:error, {:duplicate_or_invalid_evaluation, "evaluation", _key}} =
             State.record_evaluation(restored, plan, evaluation)

    assert {:ok, frontier} = Frontier.compute(plan, [candidate], [evaluation])
    assert {:ok, complete} = State.complete(restored, plan, frontier)
    assert complete.status == :completed
    assert State.verify(complete) == :ok
  end

  test "state records one evaluation per attempt and still refuses an untagged repeat" do
    plan = plan()
    candidate = candidate(plan, "candidate", "candidate", parents: [seed_parent(plan)])
    first = evaluation(plan, candidate, "first", 1.0, 1.0, observations: %{"attempt" => 1})
    second = evaluation(plan, candidate, "second", 0.0, 1.0, observations: %{"attempt" => 2})
    untagged = evaluation(plan, candidate, "untagged", 1.0, 1.0)

    assert {:ok, state} = plan |> State.new() |> State.start()

    assert {:ok, state} =
             State.record_candidate(state, plan, candidate, %{
               "tokens" => 10,
               "cost_usd" => 0.1,
               "time_ms" => 5
             })

    assert {:ok, state} = State.record_evaluation(state, plan, first)
    assert {:ok, state} = State.record_evaluation(state, plan, second)
    assert "candidate|development|dev-1|2" in state.evaluation_keys

    # The first attempt keeps the historical key, so an untagged evaluation
    # of the same case is the same paid work under a new id.
    assert {:error, {:duplicate_or_invalid_evaluation, "untagged", "candidate|development|dev-1"}} =
             State.record_evaluation(state, plan, untagged)
  end

  test "discovery objects are explicitly rejected by asset activation" do
    plan = plan()
    candidate = candidate(plan, "candidate", "candidate", parents: [seed_parent(plan)])

    assert Registry.activate(Registry.new(), candidate) ==
             {:error, :approved_asset_proposal_required}
  end

  test "foreground shadow discovery produces several candidates only with external boundaries" do
    plan = plan()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    proposer = fn plan, _state, _context ->
      ordinal = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if ordinal <= 2 do
        proposed =
          candidate(plan, "shadow-#{ordinal}", "shadow #{ordinal}", parents: [seed_parent(plan)])

        {:ok, proposed, %{"tokens" => 10, "cost_usd" => 0.1, "time_ms" => 5}}
      else
        :done
      end
    end

    evaluator = fn plan, proposed, _context ->
      {:ok,
       [
         evaluation(
           plan,
           proposed,
           "#{proposed.id}-eval",
           if(proposed.id == "shadow-1", do: 0.5, else: 1.0),
           1.0
         )
       ]}
    end

    immutable = %{"id" => "external", "sha256" => String.duplicate("d", 64)}

    assert {:ok, result} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: immutable,
               exposed_corpus: immutable
             )

    assert length(result.candidates) == 2
    assert result.state.status == :completed
    assert Enum.map(result.frontier.members, & &1["candidate_id"]) == ["shadow-2"]

    assert {:error, :external_sandbox_required, _state} =
             Shadow.run(plan, proposer, evaluator, exposed_corpus: immutable)

    options = Shadow.fresh_session_options(plan, 1)
    assert options[:entries] == []
    assert options[:id] == options[:root_session_id]
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
      "development_case_ids" => ["dev-1"],
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
      "mutation_kind" => "asset"
    }

    assert {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp evaluation(plan, candidate, id, quality, cost, opts \\ []) do
    complete = Keyword.get(opts, :complete, true)
    safe = Keyword.get(opts, :safety, true)

    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "case_id" => "dev-1",
      "split" => "development",
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
      "observations" => Keyword.get(opts, :observations, %{})
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
