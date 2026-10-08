defmodule Lemieux.Benchmark.Reporter.ConsoleTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Reporter.Console

  test "formats a terminal summary with candidate metrics, deltas, cost and failures" do
    report = %{
      "evaluation" => %{
        "baseline" => "old",
        "runtimes" => %{
          "new" => %{
            "task_success" => %{"rate" => 0.9},
            "tool_selection" => %{"rate" => 1.0},
            "prompt_adherence" => %{"rate" => nil},
            "destructive_operation_safety" => %{"failed" => 1},
            "efficiency" => %{"mean_cost_usd" => 0.42, "mean_turns" => 3.0}
          }
        },
        "comparisons" => %{"new" => %{"task_success_delta" => -0.05}}
      },
      "gate" => %{
        "passed" => false,
        "failures" => [
          %{"runtime" => "new", "metric" => "destructive_operation_safety", "hard" => true}
        ]
      },
      "budget" => %{"actual_cost_usd" => 0.42, "cap_usd" => 8.0}
    }

    output = Console.format(report)

    assert output =~ "LEMIEUX EVAL: FAIL"
    assert output =~ "new"
    assert output =~ "task success: 90.0% (-5.0 points)"
    assert output =~ "safety failures: 1"
    assert output =~ "$0.42 / $8.00"
    assert output =~ "HARD destructive_operation_safety"
  end

  test "says a runtime could not attest to safety rather than listing failures" do
    report = %{
      "evaluation" => %{
        "baseline" => nil,
        "runtimes" => %{
          "live" => %{
            "task_success" => %{"rate" => 1.0},
            "destructive_operation_safety" => %{"failed" => 0, "unattested" => 10}
          }
        }
      },
      "gate" => %{
        "passed" => false,
        "failures" => [
          %{
            "runtime" => "live",
            "metric" => "destructive_operation_safety",
            "hard" => true,
            "unattested_cases" => 10
          }
        ]
      }
    }

    output = Console.format(report)

    assert output =~ "safety failures: 0"
    assert output =~ "safety unattested: 10"

    assert output =~
             "HARD destructive_operation_safety (live): 10 cases unattested; " <>
               "this runtime cannot report writes outside the workspace"
  end
end
