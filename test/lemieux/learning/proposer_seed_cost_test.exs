defmodule Lemieux.Learning.ProposerSeedCostTest do
  # The seed candidate is the parent document evaluated unchanged: no session
  # runs and no request is made. It used to report `"cost_usd" => nil`, and a
  # metered plan — one whose budget has no `"unknown_cost" => "allow"` — reads
  # a missing cost as one nobody can bound: recording the seed marked the
  # budget unknown and the search stopped before its first real proposal.
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Proposer

  test "the seed costs a known zero, so a metered search keeps running after it" do
    seed_bytes = Contract.encode!(seed_profile())
    plan = metered_plan(seed_bytes)
    refute Map.has_key?(plan.budget, "unknown_cost")
    {:ok, state} = plan |> State.new() |> State.start()

    context = %{
      parent: {:seed, hd(plan.seeds)},
      operator: "seed",
      candidates: [],
      evaluations: [],
      artifacts: %{Contract.sha256(seed_bytes) => seed_bytes},
      ordinal: 1
    }

    assert {:ok, candidate, accounting} = Proposer.propose(plan, state, context)
    assert %{"tokens" => 0, "cost_usd" => +0.0, "requests" => 0} = accounting
    assert %{"cost_usd" => +0.0, "requests" => 0} = candidate.extensions["proposer_usage"]

    assert {:ok, recorded} = State.record_candidate(state, plan, candidate, accounting)
    assert recorded.status == :running
    assert %{"state" => "complete", "candidates" => 1, "cost_usd" => +0.0} = recorded.budget
    refute Map.has_key?(recorded.budget, "cost_state")
  end

  defp metered_plan(seed_bytes) do
    scope = %{"id" => "tenant-a/project-a"}

    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-seed-cost",
        "scope" => scope,
        "target_interface" => %{"id" => "lemieux.session-profile/v1"},
        "mutation_surface" => [%{"path" => "options.system"}],
        "seeds" => [
          %{"id" => "seed-1", "content_sha256" => Contract.sha256(seed_bytes), "scope" => scope}
        ],
        "proposer" => Proposer.identity(Proposer.profile("test:model")),
        "base_model" => %{"id" => "test:model", "sha256" => Contract.sha256("test:model")},
        "development_case_ids" => ["dev-1"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
        "interface_validator" => Surface.validator(),
        "budget" => %{
          "maximum_candidates" => 10,
          "maximum_tokens" => 1_000_000,
          "maximum_cost_usd" => 10.0,
          "maximum_time_ms" => 600_000
        }
      })

    plan
  end

  defp seed_profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "You are a careful coding agent.",
          "max_turns" => 8,
          "max_tokens" => 1024,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0,
          "tool_descriptions" => %{}
        }
      },
      8
    )
  end
end
