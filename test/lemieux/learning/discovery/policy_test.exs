defmodule Lemieux.Learning.Discovery.PolicyTest do
  use ExUnit.Case, async: true

  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  test "defaults resolve the first maximized objective and one full tier" do
    plan = plan(%{})
    policy = Policy.read(plan)

    assert policy["success_objective"] == "quality"
    assert policy["success_threshold"] == 1.0
    assert policy["fidelity_tiers"] == [3]
    assert policy["clade"] == true
  end

  test "plan extensions and caller overrides layer over the defaults" do
    plan =
      plan(%{
        "extensions" => %{
          "search" => %{
            "success_objective" => "cost",
            "fidelity_tiers" => [1, 9, 2, 0, -4],
            "seed" => 7
          }
        }
      })

    policy = Policy.read(plan, %{"seed" => 11})

    assert policy["success_objective"] == "cost"
    assert policy["fidelity_tiers"] == [1, 2, 3]
    assert policy["seed"] == 11
    assert policy["widening_alpha"] == 0.5
  end

  test "success is a threshold on the declared objective, never a blend" do
    plan = plan(%{})
    policy = Policy.read(plan)

    assert Policy.success?(evaluation(plan, %{"quality" => 1.0, "cost" => 9.0}), policy)
    refute Policy.success?(evaluation(plan, %{"quality" => 0.5, "cost" => 0.0}), policy)

    lower = Policy.read(plan, %{"success_threshold" => 0.5})
    assert Policy.success?(evaluation(plan, %{"quality" => 0.5, "cost" => 0.0}), lower)
  end

  test "a passing objective is not a success when the hard evidence is invalid" do
    plan = plan(%{})
    policy = Policy.read(plan)
    passing = evaluation(plan, %{"quality" => 1.0, "cost" => 0.0})

    unsafe = %{
      passing
      | safety: %{"passed" => false, "failures" => ["changed_path_outside_allowlist:x"]}
    }

    refute Policy.success?(unsafe, policy)
    refute Policy.success?(%{passing | terminal: false}, policy)
    refute Policy.success?(%{passing | within_budget: false}, policy)
    assert Policy.success?(passing, policy)
  end

  test "attempts default to one and always cases inherit that default" do
    policy = Policy.read(plan(%{}))

    assert policy["attempts"] == 1
    assert policy["always_attempts"] == nil
    assert Policy.attempts(policy, "dev-1") == 1
  end

  test "always cases run their own attempt count and every other case the plan's" do
    plan =
      plan(%{
        "extensions" => %{
          "search" => %{"always_case_ids" => ["dev-2"], "always_attempts" => 3, "attempts" => 2}
        }
      })

    policy = Policy.read(plan)
    assert Policy.attempts(policy, "dev-2") == 3
    assert Policy.attempts(policy, "dev-1") == 2

    only_always = Policy.read(plan, %{"attempts" => 1, "always_attempts" => 2})
    assert Policy.attempts(only_always, "dev-2") == 2
    assert Policy.attempts(only_always, "dev-1") == 1
  end

  test "attempt counts below one or not integers are rejected in favour of the default" do
    plan = plan(%{"extensions" => %{"search" => %{"always_case_ids" => ["dev-2"]}}})

    for invalid <- [0, -1, 1.5, "2", nil] do
      policy = Policy.read(plan, %{"attempts" => invalid, "always_attempts" => invalid})

      assert policy["attempts"] == 1
      assert policy["always_attempts"] == nil
      assert Policy.attempts(policy, "dev-2") == 1
      assert Policy.attempts(policy, "dev-1") == 1
    end
  end

  defp plan(overrides) do
    scope = %{"id" => "tenant-a/project-a"}

    attrs =
      Map.merge(
        %{
          "id" => "plan-policy",
          "scope" => scope,
          "target_interface" => %{"id" => "profile/v1"},
          "mutation_surface" => [%{"path" => "options.system"}],
          "seeds" => [%{"id" => "seed-1", "content_sha256" => String.duplicate("a", 64)}],
          "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("b", 64)},
          "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("c", 64)},
          "development_case_ids" => ["dev-1", "dev-2", "dev-3"],
          "validation_case_ids" => ["val-1"],
          "objectives" => [
            %{"name" => "cost", "direction" => "minimize"},
            %{"name" => "quality", "direction" => "maximize"}
          ],
          "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
          "interface_validator" => %{"id" => "validator", "sha256" => String.duplicate("d", 64)},
          "budget" => %{
            "maximum_candidates" => 5,
            "maximum_tokens" => 1000,
            "maximum_cost_usd" => 1.0,
            "maximum_time_ms" => 1000
          }
        },
        overrides
      )

    {:ok, plan} = Plan.new(attrs)
    plan
  end

  defp evaluation(plan, objectives) do
    %Evaluation{
      id: "eval",
      sha256: "",
      created_at: DateTime.utc_now(),
      plan_id: plan.id,
      plan_sha256: plan.sha256,
      candidate_id: "cand",
      candidate_content_sha256: String.duplicate("e", 64),
      scope: plan.scope,
      case_id: "dev-1",
      split: "development",
      objectives: objectives,
      safety: %{"passed" => true, "failures" => []},
      completeness: %{"usage" => "complete"},
      usage: %{},
      cost: %{},
      latency: %{},
      artifacts: [],
      within_budget: true,
      terminal: true,
      observations: %{},
      extensions: %{}
    }
  end
end
