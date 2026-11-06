defmodule Lemieux.CLI.Learning.AssetPolicyTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetPolicy

  test "a verified passing baseline abstains before any search allocation" do
    assert AssetPolicy.admission(record(true)) == %{
             "decision" => "abstain",
             "reason" => "verified_baseline_has_no_quality_headroom"
           }

    assert AssetPolicy.admission(record(false))["decision"] == "search"

    for changed <- [
          put_in(record(false), ["selected", "usage", "input_tokens"], nil),
          put_in(record(false), ["selected", "provider_error"], "unavailable"),
          put_in(record(false), ["public_grades", "selected", "safety_failures"], ["unsafe"])
        ] do
      assert AssetPolicy.admission(changed)["decision"] == "abstain"
    end
  end

  test "task triggers are bounded literal phrases and cannot act as executable matchers" do
    assert AssetPolicy.matches?(["archive paths"], "Normalize ARCHIVE paths safely")
    refute AssetPolicy.matches?(["archive paths"], "Repair a calendar")
    refute AssetPolicy.matches?([".*"], "Repair a calendar")
    refute AssetPolicy.matches?(["the"], "Repair the calendar")
    refute AssetPolicy.matches?([], "Normalize archive paths")
  end

  test "the selective schedule budgets four probes for one candidate and eight for two" do
    assert AssetPolicy.probe_count(1) == 4
    assert AssetPolicy.probe_count(2) == 8
    assert AssetPolicy.policy()["single_candidate_composition"] == "reuse_exact_evaluations"
    assert AssetPolicy.policy()["unused_candidate"] == "reject_after_first_probe"
  end

  test "earlier experience alone cannot make a procedure match the current task" do
    record = %{"task_request" => "Repair a calendar", "prior_experience" => ["archive paths"]}
    refute AssetPolicy.matches?(["archive paths"], AssetPolicy.trigger_source(record))
    observed = Map.put(record, "selected", %{"answer" => "Observed malformed archive paths"})
    assert AssetPolicy.matches?(["archive paths"], AssetPolicy.trigger_source(observed))
    quoted = Map.put(record, "selected", %{"answer" => "repair \"archive paths\" now"})
    assert AssetPolicy.matches?(["repair \"archive paths\""], AssetPolicy.trigger_source(quoted))
  end

  test "earlier guidance in session metadata cannot supply a current-task trigger" do
    record = %{
      "task_request" => "Repair a calendar",
      "selected" => %{
        "transcript" => [
          %{"type" => "session", "payload" => %{"system" => "Earlier lesson: archive paths"}},
          %{"type" => "system", "payload" => %{"text" => "Recall archive paths"}},
          %{"type" => "extension_state", "payload" => %{"lesson" => "archive paths"}}
        ]
      }
    }

    refute AssetPolicy.matches?(["archive paths"], AssetPolicy.trigger_source(record))

    observed =
      update_in(
        record,
        ["selected", "transcript"],
        &(&1 ++
            [
              %{"type" => "tool_result", "payload" => %{"output" => "Malformed archive paths"}}
            ])
      )

    assert AssetPolicy.matches?(["archive paths"], AssetPolicy.trigger_source(observed))
  end

  defp record(passed),
    do: %{
      "selected" => %{
        "status" => "completed",
        "provider_error" => nil,
        "usage" => %{"input_tokens" => 2, "output_tokens" => 2}
      },
      "public_grades" => %{
        "selected" => %{"passed" => passed, "safety_failures" => []}
      }
    }
end
