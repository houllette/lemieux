defmodule Lemieux.Learning.Discovery.ShadowSearchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Shadow

  @immutable %{"id" => "external", "sha256" => String.duplicate("d", 64)}
  @seed_bytes ~s({"options":{"system":"seed"}})

  test "search evaluates the seed first, expands from evidence, and records every decision" do
    plan = plan(maximum_candidates: 4, seed: 3)
    log = start_log()

    # Candidate 2 (the first real proposal) fixes dev-2; candidate 3 regresses dev-1.
    outcomes = %{
      "seed" => %{"dev-1" => 1.0, "dev-2" => 0.0, "dev-3" => 0.0},
      2 => %{"dev-1" => 1.0, "dev-2" => 1.0, "dev-3" => 0.0},
      3 => %{"dev-1" => 0.0, "dev-2" => 1.0, "dev-3" => 0.0},
      4 => %{"dev-1" => 1.0, "dev-2" => 1.0, "dev-3" => 1.0}
    }

    proposer = fn plan, _state, context ->
      record(log, {:propose, context.ordinal, context.operator, context.parent})
      assert is_map(context.digest) and is_map(context.calibration)
      assert Map.has_key?(context, :evidence)

      {content, kind} =
        if context.operator == "seed",
          do: {@seed_bytes, "seed"},
          else: {~s({"options":{"system":"edit #{context.ordinal}"}}), context.operator}

      context.retain.(Contract.sha256(content), content)
      parent = parent_ref(context.parent, context.candidates)
      prediction = if kind == "seed", do: %{}, else: %{"fixes" => ["dev-2"], "at_risk" => []}

      {:ok, candidate(plan, context.ordinal, content, kind, parent, prediction),
       %{"tokens" => 10, "cost_usd" => 0.01, "time_ms" => 1}}
    end

    evaluator = fn plan, candidate, context ->
      record(log, {:evaluate, candidate.id, context.case_ids})
      assert Map.has_key?(context.artifacts, Candidate.content_sha256(candidate))
      key = if candidate.mutation_kind == "seed", do: "seed", else: ordinal(candidate)

      {:ok,
       %{
         evaluations:
           Enum.map(context.case_ids, &evaluation(plan, candidate, &1, outcomes[key][&1])),
         artifacts: %{},
         incomplete: []
       }}
    end

    assert {:ok, result} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: @immutable,
               exposed_corpus: @immutable,
               search: true,
               artifacts: %{Contract.sha256(@seed_bytes) => @seed_bytes}
             )

    events = entries(log)
    assert [{:propose, 1, "seed", {:seed, %{"id" => "seed-1"}}} | _] = events
    assert Enum.count(events, &match?({:propose, _, _, _}, &1)) == 4

    assert Enum.all?(
             Enum.filter(events, &(match?({:propose, _, _, _}, &1) and elem(&1, 1) > 1)),
             fn
               {:propose, _n, kind, {:candidate, _id}} ->
                 kind in ["clonal", "reaction_norm", "cross_lineage"]

               _other ->
                 false
             end
           )

    assert result.state.status == :completed
    assert length(result.candidates) == 4
    assert Enum.map(result.candidates, & &1.mutation_kind) |> hd() == "seed"

    # Every candidate was evaluated on every development case by the end.
    for candidate <- result.candidates do
      evaluated =
        result.evaluations
        |> Enum.filter(&(&1.candidate_id == candidate.id))
        |> Enum.map(& &1.case_id)
        |> Enum.sort()

      assert evaluated == ["dev-1", "dev-2", "dev-3"],
             "#{candidate.id} evaluated on #{inspect(evaluated)}"
    end

    # The all-passing candidate dominates; the seed and the regressing one do not make the frontier.
    members = Enum.map(result.frontier.members, & &1["candidate_id"])
    assert members == [Enum.at(result.candidates, 3).id]

    assert result.calibration["status"] == "calibrated"
    assert result.digest["counts"]["evaluations"] == 12
    assert is_map(result.selection["posteriors"])
    assert result.acceptance["seed"]["proposed"] == 1

    types = Enum.map(result.state.events, & &1["type"])
    assert "action_selected" in types and "search_summary" in types and "completed" in types
    assert Enum.count(types, &(&1 == "candidate_recorded")) == 4
  end

  test "always cases run every attempt, and one failed attempt leaves the case unsolved" do
    plan =
      plan(
        maximum_candidates: 2,
        seed: 5,
        search: %{
          "fidelity_tiers" => [3],
          "always_case_ids" => ["dev-1"],
          "always_attempts" => 2
        },
        constraints: [
          %{"id" => "safe", "kind" => "mechanical"},
          %{"id" => "seesaw", "kind" => "no_solved_regression"}
        ]
      )

    log = start_log()

    # The seed passes every attempt; the edit passes dev-1 once and then
    # fails it, which is exactly the flake a single run would have missed.
    outcomes = %{
      "seed" => %{"dev-1" => [1.0, 1.0], "dev-2" => [1.0], "dev-3" => [1.0]},
      2 => %{"dev-1" => [1.0, 0.0], "dev-2" => [1.0], "dev-3" => [1.0]}
    }

    proposer = fn plan, _state, context ->
      {content, kind} =
        if context.operator == "seed",
          do: {@seed_bytes, "seed"},
          else: {~s({"options":{"system":"edit #{context.ordinal}"}}), context.operator}

      context.retain.(Contract.sha256(content), content)
      parent = parent_ref(context.parent, context.candidates)

      {:ok, candidate(plan, context.ordinal, content, kind, parent, %{}),
       %{"tokens" => 10, "cost_usd" => 0.01, "time_ms" => 1}}
    end

    evaluator = fn plan, candidate, context ->
      record(log, {:evaluate, candidate.id, context.case_ids, context.attempts})
      key = if candidate.mutation_kind == "seed", do: "seed", else: ordinal(candidate)

      evaluations =
        Enum.flat_map(context.case_ids, fn case_id ->
          scores = outcomes[key][case_id]
          assert length(scores) == context.attempts[case_id]

          scores
          |> Enum.with_index(1)
          |> Enum.map(fn {score, attempt} ->
            evaluation(plan, candidate, case_id, score, attempt)
          end)
        end)

      {:ok, evaluations}
    end

    assert {:ok, result} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: @immutable,
               exposed_corpus: @immutable,
               search: true,
               artifacts: %{Contract.sha256(@seed_bytes) => @seed_bytes}
             )

    [seed, edit] = result.candidates

    for {:evaluate, _id, case_ids, attempts} <- entries(log) do
      assert attempts == Map.new(case_ids, &{&1, if(&1 == "dev-1", do: 2, else: 1)})
    end

    for candidate <- result.candidates do
      counts =
        result.evaluations
        |> Enum.filter(&(&1.candidate_id == candidate.id))
        |> Enum.frequencies_by(& &1.case_id)

      assert counts == %{"dev-1" => 2, "dev-2" => 1, "dev-3" => 1}
    end

    assert [%{"candidate_id" => member, "scores" => %{"task_success" => 1.0}}] =
             result.frontier.members

    assert member == seed.id

    assert Map.new(result.frontier.excluded, &{&1["candidate_id"], &1["reason"]}) ==
             %{edit.id => "solved_regression"}

    assert Enum.any?(result.state.events, fn event ->
             event["type"] == "action_selected" and
               event["facts"]["attempts"] == %{"dev-1" => 2, "dev-2" => 1, "dev-3" => 1}
           end)
  end

  test "vetoed and interface-failed candidates are recorded but never evaluated" do
    plan = plan(maximum_candidates: 3, seed: 1)
    log = start_log()

    proposer = fn plan, _state, context ->
      content =
        if context.operator == "seed",
          do: @seed_bytes,
          else: ~s({"options":{"system":"edit #{context.ordinal}"}})

      context.retain.(Contract.sha256(content), content)
      parent = parent_ref(context.parent, context.candidates)

      candidate =
        case context.ordinal do
          1 ->
            candidate(plan, 1, content, "seed", parent, %{})

          2 ->
            candidate(plan, 2, content, "clonal", parent, %{},
              extensions: %{"critic" => %{"verdict" => "veto", "reason" => "no"}}
            )

          3 ->
            candidate(plan, 3, content, "clonal", parent, %{}, interface: "failed")
        end

      {:ok, candidate, %{"tokens" => 1, "cost_usd" => 0.0, "time_ms" => 1}}
    end

    evaluator = fn plan, candidate, context ->
      record(log, {:evaluate, candidate.id})
      {:ok, Enum.map(context.case_ids, &evaluation(plan, candidate, &1, 1.0))}
    end

    assert {:ok, result} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: @immutable,
               exposed_corpus: @immutable,
               search: true,
               artifacts: %{Contract.sha256(@seed_bytes) => @seed_bytes}
             )

    evaluated = log |> entries() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    assert evaluated == [hd(result.candidates).id]
    types = Enum.map(result.state.events, & &1["type"])
    assert "candidate_vetoed" in types and "candidate_interface_failed" in types

    assert Enum.map(result.frontier.excluded, & &1["reason"]) |> Enum.sort() == [
             "interface_invalid",
             "no_evaluations"
           ]
  end

  test "repeatedly incomplete evaluations fail the search instead of looping" do
    plan = plan(maximum_candidates: 2, seed: 1)

    proposer = fn plan, _state, context ->
      context.retain.(Contract.sha256(@seed_bytes), @seed_bytes)

      {:ok, candidate(plan, 1, @seed_bytes, "seed", parent_ref(context.parent, []), %{}),
       %{"tokens" => 1, "cost_usd" => 0.0, "time_ms" => 1}}
    end

    evaluator = fn _plan, _candidate, context ->
      {:ok,
       %{
         evaluations: [],
         artifacts: %{},
         incomplete: Enum.map(context.case_ids, &%{"case_id" => &1, "error" => "boom"})
       }}
    end

    assert {:error, {:evaluation_incomplete_repeatedly, nil}, state} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: @immutable,
               exposed_corpus: @immutable,
               search: true,
               artifacts: %{Contract.sha256(@seed_bytes) => @seed_bytes}
             )

    assert state.status == :failed
    assert Enum.count(state.events, &(&1["type"] == "evaluation_incomplete")) >= 3
  end

  test "the legacy linear loop is unchanged when search is not requested" do
    plan = plan(maximum_candidates: 2, seed: 1)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    proposer = fn plan, _state, context ->
      n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
      refute Map.has_key?(context, :digest)
      content = ~s({"n":#{n}})

      {:ok, candidate(plan, n, content, "asset", seed_parent(plan), %{}),
       %{"tokens" => 1, "cost_usd" => 0.0, "time_ms" => 1}}
    end

    evaluator = fn plan, candidate, _context ->
      {:ok, [evaluation(plan, candidate, "dev-1", 1.0)]}
    end

    assert {:ok, result} =
             Shadow.run(plan, proposer, evaluator,
               mode: :shadow,
               sandbox: @immutable,
               exposed_corpus: @immutable
             )

    assert length(result.candidates) == 2
    assert is_nil(result.calibration)
  end

  # ---------------------------------------------------------------------------

  defp start_log do
    {:ok, pid} = Agent.start_link(fn -> [] end)
    pid
  end

  defp record(log, event), do: Agent.update(log, &[event | &1])
  defp entries(log), do: log |> Agent.get(& &1) |> Enum.reverse()

  defp ordinal(candidate),
    do: candidate.id |> String.split("_") |> Enum.at(1) |> String.to_integer()

  defp parent_ref({:seed, seed}, _candidates),
    do: %{"id" => seed["id"], "content_sha256" => seed["content_sha256"]}

  defp parent_ref({:candidate, id}, candidates) do
    candidate = Enum.find(candidates, &(&1.id == id))
    %{"id" => id, "content_sha256" => Candidate.content_sha256(candidate)}
  end

  defp seed_parent(plan) do
    seed = hd(plan.seeds)
    %{"id" => seed["id"], "content_sha256" => seed["content_sha256"]}
  end

  defp plan(opts) do
    scope = %{"id" => "tenant-a/project-a"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-search",
        "scope" => scope,
        "target_interface" => %{"id" => "profile/v1"},
        "mutation_surface" => [%{"path" => "options.system"}],
        "seeds" => [
          %{"id" => "seed-1", "content_sha256" => Contract.sha256(@seed_bytes), "scope" => scope}
        ],
        "proposer" => %{"id" => "proposer-v1", "sha256" => String.duplicate("a", 64)},
        "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("b", 64)},
        "development_case_ids" => ["dev-1", "dev-2", "dev-3"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" =>
          Keyword.get(opts, :constraints, [%{"id" => "safe", "kind" => "mechanical"}]),
        "interface_validator" => %{"id" => "validator-v1", "sha256" => String.duplicate("c", 64)},
        "budget" => %{
          "maximum_candidates" => Keyword.fetch!(opts, :maximum_candidates),
          "maximum_tokens" => 1_000_000,
          "maximum_cost_usd" => 100.0,
          "maximum_time_ms" => 600_000
        },
        "extensions" => %{
          "search" =>
            Map.merge(
              %{"seed" => Keyword.fetch!(opts, :seed), "fidelity_tiers" => [2, 3]},
              Keyword.get(opts, :search, %{})
            )
        }
      })

    plan
  end

  defp candidate(plan, ordinal, content_bytes, kind, parent, prediction, opts \\ []) do
    scope = plan.scope

    content =
      ArtifactReference.from_bytes("candidate_content", content_bytes,
        media_type: "application/json",
        content_schema: "profile/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why #{ordinal}",
        media_type: "text/plain",
        scope: scope
      )

    attrs = %{
      "id" =>
        "cand_" <>
          String.pad_leading(Integer.to_string(ordinal), 3, "0") <>
          "_" <> binary_part(content.sha256, 0, 8),
      "scope" => scope,
      "parents" => [parent],
      "content" => ArtifactReference.to_map(content),
      "proposer" => plan.proposer,
      "rationale" => ArtifactReference.to_map(rationale),
      "interface_validation" => %{
        "status" => Keyword.get(opts, :interface, "passed"),
        "validator_sha256" => plan.interface_validator["sha256"]
      },
      "exposures" => [],
      "mutation_kind" => kind,
      "extensions" =>
        Map.merge(%{"prediction" => prediction}, Keyword.get(opts, :extensions, %{}))
    }

    {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp evaluation(plan, candidate, case_id, success, attempt \\ nil) do
    suffix = if attempt, do: "_#{attempt}", else: ""

    {:ok, evaluation} =
      Evaluation.new(plan, candidate, %{
        "id" => "eval_#{candidate.id}_#{case_id}" <> suffix,
        "scope" => plan.scope,
        "case_id" => case_id,
        "split" => "development",
        "objectives" => %{"task_success" => success},
        "safety" => %{"passed" => true, "failures" => []},
        "completeness" => %{
          "usage" => "complete",
          "cost" => "complete",
          "sandbox" => "not_applicable"
        },
        "usage" => %{"total_tokens" => 10},
        "cost" => %{"usd" => 0.01},
        "latency" => %{"milliseconds" => 5},
        "artifacts" => [],
        "within_budget" => true,
        "terminal" => true,
        "observations" => %{"finish_reason" => ":end_turn", "attempt" => attempt || 1}
      })

    evaluation
  end
end
