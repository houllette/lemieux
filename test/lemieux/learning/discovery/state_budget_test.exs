defmodule Lemieux.Learning.Discovery.StateBudgetTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State

  @unpriced %{"tokens" => 40, "cost_usd" => nil, "time_ms" => 5}

  test "a metered plan treats an unpriced fact as an unknown budget and stops" do
    plan = plan(%{})
    {:ok, state} = plan |> State.new() |> State.start()

    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), @unpriced)

    assert state.status == :budget_exhausted
    assert state.budget["state"] == "unknown"
    assert state.budget["tokens"] == 0
    refute Map.has_key?(state.budget, "cost_state")
  end

  test "only the exact allow value opts a plan in" do
    plan = plan(%{"unknown_cost" => "reject"})
    {:ok, state} = plan |> State.new() |> State.start()

    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), @unpriced)

    assert state.status == :budget_exhausted
    refute Map.has_key?(state.budget, "cost_state")
  end

  test "a quota plan keeps counting tokens and time when only the cost is unknown" do
    plan = plan(%{"unknown_cost" => "allow", "maximum_tokens" => 100})
    {:ok, state} = plan |> State.new() |> State.start()
    refute Map.has_key?(state.budget, "cost_state")

    first = candidate(plan, "first")
    assert {:ok, state} = State.record_candidate(state, plan, first, @unpriced)

    assert state.status == :running
    assert state.budget["state"] == "complete"
    assert state.budget["cost_state"] == "unknown"
    assert state.budget["tokens"] == 40
    assert state.budget["time_ms"] == 5
    assert state.budget["cost_usd"] == 0.0
    assert state.budget["candidates"] == 1

    assert {:ok, state} =
             State.record_evaluation(state, plan, evaluation(plan, first, "eval-1", nil))

    assert state.status == :running
    assert state.budget["tokens"] == 50
    assert state.budget["cost_state"] == "unknown"

    priced = %{"tokens" => 10, "cost_usd" => 0.25, "time_ms" => 1}
    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "second"), priced)

    assert state.status == :running
    assert state.budget["cost_usd"] == 0.25
    assert state.budget["tokens"] == 60
    assert state.budget["cost_state"] == "unknown"

    overrun = %{"tokens" => 60, "cost_usd" => nil, "time_ms" => 1}
    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "third"), overrun)

    assert state.status == :budget_exhausted
    assert state.budget["tokens"] == 120
    assert state.budget["state"] == "complete"
    assert List.last(state.events)["type"] == "budget_exhausted"
  end

  test "a quota plan with every cost known leaves the budget bytes unchanged" do
    plan = plan(%{"unknown_cost" => "allow"})
    {:ok, state} = plan |> State.new() |> State.start()
    priced = %{"tokens" => 10, "cost_usd" => 0.25, "time_ms" => 1}

    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), priced)

    assert Map.keys(state.budget) == ~w(candidates cost_usd state time_ms tokens)
    assert state.budget["cost_usd"] == 0.25
  end

  test "a quota plan still treats unknown tokens or time as an unknown budget" do
    plan = plan(%{"unknown_cost" => "allow"})

    for facts <- [
          %{"tokens" => nil, "cost_usd" => nil, "time_ms" => 5},
          %{"tokens" => 5, "cost_usd" => nil, "time_ms" => nil}
        ] do
      {:ok, state} = plan |> State.new() |> State.start()
      assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), facts)

      assert state.status == :budget_exhausted
      assert state.budget["state"] == "unknown"
      assert state.budget["tokens"] == 0
    end
  end

  test "a quota plan still exhausts on cost, time and candidate limits" do
    plan = plan(%{"unknown_cost" => "allow", "maximum_cost_usd" => 1.0, "maximum_time_ms" => 10})
    {:ok, state} = plan |> State.new() |> State.start()

    expensive = %{"tokens" => 1, "cost_usd" => 1.5, "time_ms" => 1}
    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), expensive)
    assert state.status == :budget_exhausted

    {:ok, state} = plan |> State.new() |> State.start()
    slow = %{"tokens" => 1, "cost_usd" => nil, "time_ms" => 11}
    assert {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), slow)
    assert state.status == :budget_exhausted
    assert state.budget["cost_state"] == "unknown"

    small = plan(%{"unknown_cost" => "allow", "maximum_candidates" => 1})
    {:ok, state} = small |> State.new() |> State.start()

    assert {:ok, state} =
             State.record_candidate(state, small, candidate(small, "first"), @unpriced)

    assert {:error, :candidate_budget_exhausted} =
             State.record_candidate(state, small, candidate(small, "second"), @unpriced)
  end

  test "the cost state survives an encode and decode round trip" do
    plan = plan(%{"unknown_cost" => "allow"})
    {:ok, state} = plan |> State.new() |> State.start()
    {:ok, state} = State.record_candidate(state, plan, candidate(plan, "first"), @unpriced)

    encoded = State.encode!(state)
    assert encoded =~ ~s("cost_state":"unknown")
    assert {:ok, restored} = State.decode(plan, encoded)
    assert restored == state
    assert restored.budget["cost_state"] == "unknown"
    assert :ok = State.verify(restored)
  end

  defp plan(budget) do
    attrs = plan_attrs()
    assert {:ok, plan} = Plan.new(update_in(attrs, ["budget"], &Map.merge(&1, budget)))
    plan
  end

  defp plan_attrs do
    scope = %{"id" => "tenant-a/project-a"}

    %{
      "id" => "plan-quota",
      "scope" => scope,
      "target_interface" => %{"id" => "environment-context/v1"},
      "mutation_surface" => [%{"asset_type" => "project_instruction", "path" => "context.json"}],
      "seeds" => [
        %{"id" => "seed-1", "content_sha256" => Contract.sha256("seed"), "scope" => scope}
      ],
      "proposer" => %{"id" => "proposer-v1", "sha256" => String.duplicate("a", 64)},
      "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("b", 64)},
      "development_case_ids" => ["dev-1"],
      "validation_case_ids" => ["val-1"],
      "objectives" => [%{"name" => "quality", "direction" => "maximize"}],
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

  defp candidate(plan, id) do
    scope = plan.scope
    seed = hd(plan.seeds)

    attrs = %{
      "id" => id,
      "scope" => scope,
      "parents" => [%{"id" => seed["id"], "content_sha256" => seed["content_sha256"]}],
      "content" => reference("candidate_content", id <> "-content", "bytes of " <> id, scope),
      "proposer" => plan.proposer,
      "rationale" => reference("proposer_trace", id <> "-rationale", "why " <> id, scope),
      "interface_validation" => %{
        "status" => "passed",
        "validator_sha256" => plan.interface_validator["sha256"]
      },
      "exposures" => [%{"source_case_ids" => ["dev-1"]}],
      "mutation_kind" => "asset"
    }

    assert {:ok, candidate} = Candidate.new(plan, attrs)
    candidate
  end

  defp evaluation(plan, candidate, id, cost_usd) do
    attrs = %{
      "id" => id,
      "scope" => plan.scope,
      "case_id" => "dev-1",
      "split" => "development",
      "objectives" => %{"quality" => 1.0},
      "safety" => %{"passed" => true, "failures" => []},
      "completeness" => %{
        "usage" => "complete",
        "cost" => if(is_nil(cost_usd), do: "unknown", else: "complete"),
        "sandbox" => "complete",
        "artifacts" => "complete"
      },
      "usage" => %{"total_tokens" => 10},
      "cost" => %{"usd" => cost_usd},
      "latency" => %{"milliseconds" => 5},
      "artifacts" => [],
      "within_budget" => true,
      "terminal" => true,
      "observations" => %{}
    }

    assert {:ok, evaluation} = Evaluation.new(plan, candidate, attrs)
    evaluation
  end

  defp reference(kind, id, bytes, scope) do
    ArtifactReference.to_map(
      ArtifactReference.from_bytes(kind, bytes,
        id: id,
        media_type: "application/json",
        content_schema: "fixture/v1",
        scope: scope
      )
    )
  end
end
