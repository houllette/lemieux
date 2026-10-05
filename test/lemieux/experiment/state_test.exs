defmodule Lemieux.Experiment.StateTest do
  use ExUnit.Case, async: true

  alias Lemieux.Experiment.State

  test "rejects promotion before approval, evaluation, and rollback readiness" do
    state = State.new("experiment-1")

    assert {:error, {:invalid_transition, :captured, :promoted}} =
             State.transition(state, :promoted, %{})

    assert {:ok, state} =
             State.transition(state, :triaged, %{
               anchor_resolved: true,
               authorized: true,
               raw_preserved: true
             })

    assert {:ok, state} =
             State.transition(state, :case_draft, %{verifiability: :mechanical})

    assert {:ok, state} =
             State.transition(state, :case_approved, %{
               case_digest: "digest",
               regression_reproduced: true
             })

    assert {:ok, state} = State.transition(state, :planned, %{plan_valid: true})

    assert {:ok, state} =
             State.transition(state, :approved, %{
               policy_approved: true,
               budget_reserved: true
             })

    assert {:ok, state} =
             State.transition(state, :running, %{
               idempotency_key: "attempt-1",
               workspaces_acquired: true
             })

    assert {:ok, state} =
             State.transition(state, :evaluating, %{
               attempts_terminal: true,
               observations_complete: true,
               attestations_valid: true
             })

    assert {:ok, state} =
             State.transition(state, :decision_pending, %{
               evaluator_signed: true,
               splits_separated: true,
               uncertainty_reported: true
             })

    assert {:error, {:gate_failed, :rollback_ready}} =
             State.transition(state, :promoted, %{
               asset_eligible: true,
               gates_passed: true,
               rollback_ready: false,
               monitoring_ready: true
             })

    assert {:ok, promoted} =
             State.transition(state, :promoted, %{
               asset_eligible: true,
               gates_passed: true,
               rollback_ready: true,
               monitoring_ready: true
             })

    assert Enum.map(promoted.history, & &1.to) |> List.last() == :promoted
  end

  test "caps clarification at three questions" do
    state = %{State.new("experiment") | status: :triaged}

    assert {:error, :too_many_questions} =
             State.transition(state, :needs_clarification, %{question_count: 4})
  end
end
