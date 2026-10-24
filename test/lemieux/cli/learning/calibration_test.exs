defmodule Lemieux.CLI.Learning.CalibrationTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Calibration

  test "unknown usage and zero-dispatch refusals cannot become a measured zero score" do
    rows = [row("a", "disabled", false, nil, 5), row("a", "reference", false, nil, 0)]
    report = Calibration.report(plan(), rows)
    assert report["baseline_success"] == nil
    assert report["has_headroom"] == nil
    refute report["execution_complete"]
    assert report["status"] == "incomplete"
    assert report["unknown_token_rows"] == 2
  end

  test "a missing matched observation cannot be used for difficulty selection" do
    report = Calibration.report(plan(), [row("a", "disabled", true, 20, 2)])
    assert report["baseline_success"] == nil
    assert report["has_headroom"] == nil
  end

  test "complete known failures retain the actual zero score" do
    report =
      Calibration.report(plan(), [
        row("a", "disabled", false, 20, 2),
        row("a", "reference", false, 30, 3)
      ])

    assert report["baseline_success"] == 0.0
    refute report["has_headroom"]
    assert report["execution_complete"]
  end

  test "duplicated pairs cannot replace a missing observation" do
    duplicate = row("a", "disabled", true, 20, 2)
    report = Calibration.report(plan(), [duplicate, duplicate])
    refute report["execution_complete"]
    assert report["baseline_success"] == nil
  end

  test "known zero-dispatch observations still cannot establish difficulty" do
    report =
      Calibration.report(plan(), [
        row("a", "disabled", false, 0, 0),
        row("a", "reference", false, 0, 0)
      ])

    refute report["execution_complete"]
    assert report["unknown_token_rows"] == 0
    assert report["baseline_success"] == nil
  end

  test "a fully observed matched sample keeps its measured headroom" do
    plan = Map.put(plan(), "tasks", Enum.map(~w(a b c), &%{"id" => &1}))

    rows =
      for task <- ~w(a b c), arm <- ~w(disabled reference), do: row(task, arm, task != "c", 20, 2)

    report = Calibration.report(plan, rows)
    assert report["execution_complete"]
    assert report["baseline_success"] == 2 / 3
    assert report["has_headroom"]
  end

  defp plan do
    %{
      "sha256" => String.duplicate("a", 64),
      "tasks" => [%{"id" => "a"}],
      "arms" => ["disabled", "reference"],
      "repetitions" => 1
    }
  end

  defp row(task, arm, passed, tokens, requests) do
    %{
      "task_id" => task,
      "arm" => arm,
      "repetition" => 1,
      "passed" => passed,
      "tokens" => tokens,
      "requests" => requests,
      "qualification_complete" => true
    }
  end
end
