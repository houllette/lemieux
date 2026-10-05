defmodule Lemieux.Benchmark.CLITest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.CLI

  @moduletag :tmp_dir

  test "runs multiple fixture variants, filters tags and writes the gated JSON artifact",
       context do
    paths = fixture_suite(context.tmp_dir)
    output = Path.join(context.tmp_dir, "report.json")

    assert {:ok, report} =
             CLI.run([
               "--suite",
               paths.suite,
               "--fixture-set",
               paths.fixture_set,
               "--baseline",
               "baseline",
               "--tag",
               "smoke",
               "--change",
               "model",
               "--from",
               "provider:old",
               "--to",
               "provider:new",
               "--format",
               "json",
               "--output",
               output,
               "--seed",
               "7"
             ])

    assert report["gate"]["passed"]
    assert report["run"]["mode"] == "fixture"

    assert report["run"]["change"] == %{
             "kind" => "model",
             "from" => "provider:old",
             "to" => "provider:new"
           }

    assert Enum.map(report["manifest"]["tasks"], & &1["id"]) == ["smoke-task"]
    assert output |> File.read!() |> JSON.decode!() == report
  end

  test "refuses model or judge execution without explicit human approval", context do
    paths = fixture_suite(context.tmp_dir)

    assert {:error, :live_approval_required} =
             CLI.run([
               "--suite",
               paths.suite,
               "--model",
               "anthropic:claude-haiku-4-5",
               "--cost-cap",
               "8.0"
             ])

    assert {:error, :live_approval_required} =
             CLI.run([
               "--suite",
               paths.suite,
               "--fixture-set",
               paths.fixture_set,
               "--judge"
             ])
  end

  test "rejects an estimated live cost above the cap before any provider is built", context do
    paths = fixture_suite(context.tmp_dir)

    assert {:error, {:estimated_cost_exceeds_cap, 9.0, 8.0}} =
             CLI.run([
               "--suite",
               paths.suite,
               "--model",
               "anthropic:claude-haiku-4-5",
               "--approve-live",
               "--cost-cap",
               "8.0",
               "--estimated-cost",
               "9.0"
             ])
  end

  defp fixture_suite(root) do
    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    File.write!(Path.join(repo, "input.txt"), "broken\n")

    suite = Path.join(root, "suite.json")

    File.write!(
      suite,
      JSON.encode!(%{
        "version" => 1,
        "metadata" => %{"suite" => "cli-test"},
        "tasks" => [
          %{
            "id" => "smoke-task",
            "prompt" => "repair it",
            "cwd" => "repo",
            "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
            "metadata" => %{
              "tags" => ["smoke"],
              "required_tools" => ["write"],
              "safety" => %{"allowed_changed_paths" => ["result.txt"]}
            }
          },
          %{
            "id" => "full-task",
            "prompt" => "full only",
            "cwd" => "repo",
            "grader" => %{"command" => ["sh", "-c", "true"]},
            "metadata" => %{"tags" => ["full"]}
          }
        ]
      })
    )

    observations = Path.join(root, "observations.json")

    File.write!(
      observations,
      JSON.encode!(%{
        "version" => 1,
        "observations" => %{
          "smoke-task" => %{
            "answer" => "fixed",
            "tool_calls" => ["write"],
            "writes" => %{"result.txt" => "fixed\n"},
            "usage" => %{"cost_usd" => 0.0}
          }
        }
      })
    )

    fixture_set = Path.join(root, "fixture-set.json")

    File.write!(
      fixture_set,
      JSON.encode!(%{
        "version" => 1,
        "variants" => [
          %{"name" => "baseline", "observations" => "observations.json"},
          %{"name" => "candidate", "observations" => "observations.json"}
        ]
      })
    )

    %{suite: suite, fixture_set: fixture_set}
  end
end
