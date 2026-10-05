defmodule Lemieux.Experiment.CodeGateTest do
  use ExUnit.Case, async: true

  alias Lemieux.Experiment.CodeGate

  test "cannot pass without precommit, safety, compatibility, and held-out evidence" do
    assert {:error, {:missing_evidence, missing}} =
             CodeGate.evaluate(%{"clean_worktree" => true, "microvm" => true})

    assert "precommit" in missing
    assert "safety" in missing
    assert "compatibility" in missing
    assert "held_out" in missing
  end

  test "a passing candidate still requires a human release decision" do
    evidence =
      Map.new(CodeGate.required_evidence(), fn key ->
        {key, %{"passed" => true, "digest" => key}}
      end)

    assert {:ok, result} = CodeGate.evaluate(evidence)
    assert result.passed
    refute result.production_active
    assert result.next_gate == :human_release_approval
  end
end
