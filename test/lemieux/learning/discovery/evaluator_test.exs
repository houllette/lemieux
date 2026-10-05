defmodule Lemieux.Learning.Discovery.EvaluatorTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Evaluator
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  describe "from_report/4" do
    test "maps grader verdicts, usage and safety allowlists into eligible evaluations" do
      plan = plan(%{})
      candidate = candidate(plan)

      report = %{
        "results" => [
          result("dev-1", candidate.id, passed: true, changed: ["result.txt"]),
          result("val-1", candidate.id, passed: false, changed: ["result.txt", "secret.txt"]),
          result("dev-1", "other-runtime", passed: true)
        ]
      }

      assert {:ok, %{evaluations: [dev, val], artifacts: artifacts, incomplete: []}} =
               Evaluator.from_report(plan, candidate, report,
                 allowed_changed_paths: %{"dev-1" => ["result.txt"], "val-1" => ["result.txt"]},
                 sandbox: :not_applicable,
                 unknown_cost: "allow"
               )

      assert dev.split == "development" and val.split == "validation"
      assert dev.objectives == %{"task_success" => 1.0, "requests" => 2.0}
      assert dev.safety == %{"passed" => true, "failures" => []}
      assert dev.completeness["cost"] == "not_applicable"
      assert dev.completeness["sandbox"] == "not_applicable"
      assert dev.usage["total_tokens"] == 30
      assert dev.latency == %{"milliseconds" => 1200}
      assert dev.within_budget and dev.terminal
      assert Evaluation.eligible?(dev)
      assert [%ArtifactReference{kind: "transcript", sha256: sha}] = dev.artifacts
      assert Map.has_key?(artifacts, sha)

      assert val.objectives["task_success"] == 0.0
      assert val.safety["passed"] == false
      assert val.safety["failures"] == ["changed_path_outside_allowlist:secret.txt"]
      refute Evaluation.eligible?(val)
    end

    test "allowlists honor the gate's directory prefixes" do
      plan = plan(%{})
      candidate = candidate(plan)

      report = %{
        "results" => [
          result("dev-1", candidate.id, passed: true, changed: ["Makefile", "dist/report.txt"])
        ]
      }

      assert {:ok, %{evaluations: [strict]}} =
               Evaluator.from_report(plan, candidate, report,
                 allowed_changed_paths: %{"dev-1" => ["Makefile"]}
               )

      assert strict.safety["failures"] == ["changed_path_outside_allowlist:dist/report.txt"]

      assert {:ok, %{evaluations: [prefixed]}} =
               Evaluator.from_report(plan, candidate, report,
                 allowed_changed_paths: %{"dev-1" => ["Makefile", "dist/**"]}
               )

      assert prefixed.safety == %{"passed" => true, "failures" => []}
    end

    test "a stop at the profile's own limits is a terminal failure; an evaluator timeout is not" do
      plan = plan(%{})
      candidate = candidate(plan)

      report = %{
        "results" => [
          result("dev-1", candidate.id, passed: false, finish_reason: ":max_turns"),
          result("val-1", candidate.id, passed: false, finish_reason: ":benchmark_timeout")
        ]
      }

      assert {:ok, %{evaluations: [turns, timeout]}} =
               Evaluator.from_report(plan, candidate, report,
                 allowed_changed_paths: %{},
                 sandbox: :not_applicable,
                 unknown_cost: "allow"
               )

      assert turns.objectives["task_success"] == 0.0
      assert turns.within_budget and turns.terminal
      assert Evaluation.eligible?(turns)

      assert timeout.objectives["task_success"] == 0.0
      refute timeout.within_budget
      refute Evaluation.eligible?(timeout)
    end

    test "unknown cost and unattested sandbox stay unknown unless the plan allows them" do
      plan = plan(%{})
      candidate = candidate(plan)
      report = %{"results" => [result("dev-1", candidate.id, passed: true)]}

      assert {:ok, %{evaluations: [strict]}} = Evaluator.from_report(plan, candidate, report)
      assert strict.completeness["cost"] == "unknown"
      assert strict.completeness["sandbox"] == "unknown"
      refute Evaluation.eligible?(strict)

      priced = %{"results" => [result("dev-1", candidate.id, passed: true, cost: 0.02)]}

      assert {:ok, %{evaluations: [known]}} =
               Evaluator.from_report(plan, candidate, priced, sandbox: :not_applicable)

      assert known.completeness["cost"] == "complete"
      assert known.cost == %{"usd" => 0.02}
      assert Evaluation.eligible?(known)
    end

    test "objectives the report cannot supply and cases outside the plan are errors, never zeros" do
      plan = plan(%{"objectives" => [%{"name" => "cost_usd", "direction" => "minimize"}]})
      candidate = candidate(plan)

      assert {:error, {:objective_unknown, "cost_usd", "dev-1"}} =
               Evaluator.from_report(plan, candidate, %{
                 "results" => [result("dev-1", candidate.id, passed: true)]
               })

      unknown = plan(%{"objectives" => [%{"name" => "vibes", "direction" => "maximize"}]})

      assert {:error, {:unknown_objective, "vibes"}} =
               Evaluator.from_report(unknown, candidate(unknown), %{
                 "results" => [result("dev-1", candidate.id, passed: true)]
               })

      assert {:error, {:case_not_in_plan, "stray"}} =
               Evaluator.from_report(plan(%{}), candidate, %{
                 "results" => [result("stray", candidate.id, passed: true)]
               })
    end

    test "a runtime failure without an observation is reported as incomplete, not as evidence" do
      plan = plan(%{})
      candidate = candidate(plan)

      failed = %{
        "task_id" => "dev-1",
        "runtime" => candidate.id,
        "attempt" => 1,
        "passed" => false,
        "wall_time_ms" => 5,
        "observation" => nil,
        "grader" => nil,
        "error" => "{:workspace, :enoent}"
      }

      assert {:ok, %{evaluations: [], artifacts: %{}, incomplete: [incomplete]}} =
               Evaluator.from_report(plan, candidate, %{"results" => [failed]},
                 unknown_cost: "allow"
               )

      assert incomplete == %{
               "case_id" => "dev-1",
               "attempt" => 1,
               "error" => "{:workspace, :enoent}",
               "wall_time_ms" => 5
             }
    end
  end

  describe "run/3" do
    test "runs a profile candidate through the benchmark runner and returns evaluations",
         %{tmp_dir: tmp_dir} do
      fixture = Path.join(tmp_dir, "fixture")
      File.mkdir_p!(fixture)
      File.write!(Path.join(fixture, "README.md"), "write result.txt\n")

      {:ok, manifest} =
        Manifest.from_map(
          %{
            "version" => 1,
            "tasks" => [
              %{
                "id" => "dev-1",
                "prompt" => "Create result.txt containing exactly fixed.",
                "cwd" => "fixture",
                "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
                "metadata" => %{"safety" => %{"allowed_changed_paths" => ["result.txt"]}}
              },
              %{
                "id" => "val-1",
                "prompt" => "unused",
                "cwd" => "fixture",
                "grader" => %{"command" => ["sh", "-c", "false"]},
                "metadata" => %{}
              }
            ]
          },
          tmp_dir
        )

      plan = plan(%{"budget" => Map.put(budget(), "unknown_cost", "allow")})
      candidate = candidate(plan)

      provider =
        Scripted.new([
          Scripted.tool_call("call-1", "write", %{"path" => "result.txt", "content" => "fixed"},
            usage: %{"input_tokens" => 10, "output_tokens" => 5}
          ),
          Scripted.complete("Created result.txt.",
            usage: %{"input_tokens" => 12, "output_tokens" => 4}
          )
        ])

      assert {:ok, %{evaluations: [evaluation], artifacts: artifacts, incomplete: []}} =
               Evaluator.run(plan, candidate,
                 manifest: manifest,
                 profile: profile(),
                 provider: provider,
                 case_ids: ["dev-1"],
                 sandbox: :not_applicable,
                 sessions_dir: Path.join(tmp_dir, "sessions"),
                 benchmark: [workspace_root: Path.join(tmp_dir, "work"), output: nil]
               )

      assert evaluation.case_id == "dev-1"
      assert evaluation.objectives == %{"task_success" => 1.0, "requests" => 2.0}
      assert evaluation.safety["passed"]
      assert evaluation.completeness["cost"] == "not_applicable"
      assert Evaluation.eligible?(evaluation)
      assert evaluation.usage["total_tokens"] == 31
      assert [reference] = evaluation.artifacts
      assert {:ok, entries} = JSON.decode(Map.fetch!(artifacts, reference.sha256))

      assert Enum.any?(
               entries,
               &(&1["type"] == "tool_result" and &1["payload"]["name"] == "write")
             )

      refute File.exists?(Path.join(fixture, "result.txt"))
    end

    test "a model portfolio merges per-model runs into one evaluation per case",
         %{tmp_dir: tmp_dir} do
      fixture = Path.join(tmp_dir, "fixture")
      File.mkdir_p!(fixture)

      {:ok, manifest} =
        Manifest.from_map(
          %{
            "version" => 1,
            "tasks" => [
              %{
                "id" => "dev-1",
                "prompt" => "Create result.txt containing exactly fixed.",
                "cwd" => "fixture",
                "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
                "metadata" => %{"safety" => %{"allowed_changed_paths" => ["result.txt"]}}
              },
              %{
                "id" => "val-1",
                "prompt" => "unused",
                "cwd" => "fixture",
                "grader" => %{"command" => ["sh", "-c", "false"]}
              }
            ]
          },
          tmp_dir
        )

      objectives = [
        %{"name" => "task_success", "direction" => "maximize"},
        %{"name" => "requests", "direction" => "minimize"},
        %{"name" => "task_success@test:other", "direction" => "maximize"}
      ]

      plan =
        plan(%{
          "objectives" => objectives,
          "budget" => Map.put(budget(), "unknown_cost", "allow")
        })

      candidate = candidate(plan)

      # The scripted provider passes on test:model and writes the wrong content on test:other.
      provider = fn ->
        Scripted.new([
          fn request ->
            content = if request.model == "test:other", do: "wrong", else: "fixed"

            Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => content},
              usage: %{"input_tokens" => 10, "output_tokens" => 5}
            )
          end,
          Scripted.complete("done", usage: %{"input_tokens" => 12, "output_tokens" => 4})
        ])
      end

      assert {:ok, %{evaluations: [evaluation], artifacts: artifacts}} =
               Evaluator.run(plan, candidate,
                 manifest: manifest,
                 profile: profile(),
                 provider: provider,
                 models: [
                   "test:model",
                   %{"model" => "test:other", "usage_mode" => "quota", "max_requests" => 4}
                 ],
                 case_ids: ["dev-1"],
                 sandbox: :not_applicable,
                 sessions_dir: Path.join(tmp_dir, "sessions"),
                 benchmark: [workspace_root: Path.join(tmp_dir, "work")]
               )

      assert evaluation.objectives == %{
               "task_success" => 0.5,
               "requests" => 2.0,
               "task_success@test:other" => 0.0
             }

      assert evaluation.observations["models"] == ["test:model", "test:other"]

      assert evaluation.observations["per_model"]["test:model"]["objectives"]["task_success"] ==
               1.0

      assert evaluation.usage["total_tokens"] == 62
      assert length(evaluation.artifacts) == 2
      assert map_size(artifacts) == 2
      assert Evaluation.eligible?(evaluation)

      policy = Policy.read(plan)
      refute Policy.success?(evaluation, policy)

      unknown =
        plan(%{
          "objectives" => [%{"name" => "task_success@test:absent", "direction" => "maximize"}],
          "budget" => Map.put(budget(), "unknown_cost", "allow")
        })

      assert {:error, {:objective_unknown, "task_success@test:absent", :missing_model}} =
               Evaluator.run(unknown, candidate(unknown),
                 manifest: manifest,
                 profile: profile(),
                 provider: provider,
                 models: ["test:model", "test:other"],
                 case_ids: ["dev-1"],
                 sandbox: :not_applicable,
                 sessions_dir: Path.join(tmp_dir, "sessions2"),
                 benchmark: [workspace_root: Path.join(tmp_dir, "work2")]
               )
    end

    test "attempts per case repeat a case as often as asked, with one evaluation per attempt",
         %{tmp_dir: tmp_dir} do
      fixture = Path.join(tmp_dir, "fixture")
      File.mkdir_p!(fixture)

      task = fn id ->
        %{
          "id" => id,
          "prompt" => "Create result.txt containing exactly fixed.",
          "cwd" => "fixture",
          "grader" => %{"command" => ["sh", "-c", "test \"$(cat result.txt)\" = fixed"]},
          "metadata" => %{"safety" => %{"allowed_changed_paths" => ["result.txt"]}}
        }
      end

      {:ok, manifest} =
        Manifest.from_map(%{"version" => 1, "tasks" => [task.("dev-1"), task.("dev-2")]}, tmp_dir)

      plan =
        plan(%{
          "development_case_ids" => ["dev-1", "dev-2"],
          "budget" => Map.put(budget(), "unknown_cost", "allow")
        })

      candidate = candidate(plan)

      provider = fn ->
        Scripted.new([
          Scripted.tool_call("c1", "write", %{"path" => "result.txt", "content" => "fixed"},
            usage: %{"input_tokens" => 10, "output_tokens" => 5}
          ),
          Scripted.complete("done", usage: %{"input_tokens" => 12, "output_tokens" => 4})
        ])
      end

      base = [
        manifest: manifest,
        profile: profile(),
        provider: provider,
        case_ids: ["dev-1", "dev-2"],
        sandbox: :not_applicable,
        sessions_dir: Path.join(tmp_dir, "sessions")
      ]

      assert {:ok, %{evaluations: evaluations, artifacts: artifacts, incomplete: []}} =
               Evaluator.run(
                 plan,
                 candidate,
                 base ++
                   [
                     attempts: %{"dev-1" => 2, "dev-2" => 1},
                     benchmark: [workspace_root: Path.join(tmp_dir, "work")]
                   ]
               )

      assert Enum.map(evaluations, & &1.id) == [
               "eval_cand-1_dev-1_1",
               "eval_cand-1_dev-1_2",
               "eval_cand-1_dev-2_1"
             ]

      assert Enum.map(evaluations, &{&1.case_id, &1.observations["attempt"]}) == [
               {"dev-1", 1},
               {"dev-1", 2},
               {"dev-2", 1}
             ]

      assert Enum.all?(evaluations, &(&1.objectives["task_success"] == 1.0))
      # Every attempt is its own session with its own retained transcript.
      assert map_size(artifacts) == 3

      # A portfolio keeps one merged evaluation per attempt, not per case.
      assert {:ok, %{evaluations: merged}} =
               Evaluator.run(
                 plan,
                 candidate,
                 Keyword.merge(base,
                   models: ["test:model", "test:other"],
                   case_ids: ["dev-1"],
                   attempts: %{"dev-1" => 2},
                   sessions_dir: Path.join(tmp_dir, "sessions2"),
                   benchmark: [workspace_root: Path.join(tmp_dir, "work2")]
                 )
               )

      assert Enum.map(merged, & &1.id) == ["eval_cand-1_dev-1_1", "eval_cand-1_dev-1_2"]
      assert Enum.map(merged, & &1.observations["attempt"]) == [1, 2]
      assert Enum.all?(merged, &(&1.observations["models"] == ["test:model", "test:other"]))

      # An attempt count that is not a positive integer is refused before any session runs.
      assert {:error, {:invalid_attempts, "dev-2"}} =
               Evaluator.run(plan, candidate, base ++ [attempts: %{"dev-2" => 0}])
    end

    test "refuses cases outside the plan or manifest before spending anything", %{
      tmp_dir: tmp_dir
    } do
      {:ok, manifest} =
        Manifest.from_map(
          %{
            "version" => 1,
            "tasks" => [
              %{
                "id" => "dev-1",
                "prompt" => "x",
                "cwd" => ".",
                "grader" => %{"command" => ["true"]}
              }
            ]
          },
          tmp_dir
        )

      plan = plan(%{})
      candidate = candidate(plan)
      base = [manifest: manifest, profile: profile(), provider: Scripted.new([])]

      assert {:error, {:case_not_in_plan, "nope"}} =
               Evaluator.run(plan, candidate, base ++ [case_ids: ["nope"]])

      assert {:error, {:case_not_in_manifest, "val-1"}} =
               Evaluator.run(plan, candidate, base ++ [case_ids: ["val-1"]])

      assert {:error, {:manifest, :required}} = Evaluator.run(plan, candidate, profile: profile())
    end
  end

  defp profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "You are a careful coding agent.",
          "max_turns" => 6,
          "max_tokens" => 512,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.0
        }
      },
      6
    )
  end

  defp result(case_id, runtime, opts) do
    passed = Keyword.fetch!(opts, :passed)

    %{
      "task_id" => case_id,
      "runtime" => runtime,
      "attempt" => 1,
      "passed" => passed,
      "wall_time_ms" => 1200,
      "observation" => %{
        "status" => "completed",
        "answer" => "done",
        "finish_reason" => Keyword.get(opts, :finish_reason, ":end_turn"),
        "session_id" => "session_" <> case_id,
        "usage" => %{
          "requests" => 2,
          "input_tokens" => 20,
          "output_tokens" => 10,
          "cache_read_tokens" => 0,
          "cache_write_tokens" => 0,
          "cost_usd" => Keyword.get(opts, :cost)
        },
        "tool_metrics" => %{"requests" => 2, "calls" => 1, "errors" => 0},
        "transcript" => [%{"type" => "user", "payload" => %{"content" => "x"}}],
        "changed_paths" => Keyword.get(opts, :changed, []),
        "safety_violations" => nil
      },
      "grader" => %{
        "passed" => passed,
        "exit_status" => if(passed, do: 0, else: 1),
        "timed_out" => false
      },
      "error" => nil
    }
  end

  defp budget do
    %{
      "maximum_candidates" => 5,
      "maximum_tokens" => 100_000,
      "maximum_cost_usd" => 10.0,
      "maximum_time_ms" => 600_000
    }
  end

  defp plan(overrides) do
    scope = %{"id" => "tenant-a/project-a"}

    attrs =
      Map.merge(
        %{
          "id" => "plan-evaluator",
          "scope" => scope,
          "target_interface" => %{"id" => "profile/v1"},
          "mutation_surface" => [%{"path" => "options.system"}],
          "seeds" => [%{"id" => "seed-1", "content_sha256" => String.duplicate("a", 64)}],
          "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("b", 64)},
          "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("c", 64)},
          "development_case_ids" => ["dev-1"],
          "validation_case_ids" => ["val-1"],
          "objectives" => [
            %{"name" => "task_success", "direction" => "maximize"},
            %{"name" => "requests", "direction" => "minimize"}
          ],
          "hard_constraints" => [%{"id" => "safe", "kind" => "mechanical"}],
          "interface_validator" => %{"id" => "validator", "sha256" => String.duplicate("d", 64)},
          "budget" => budget()
        },
        overrides
      )

    {:ok, plan} = Plan.new(attrs)
    plan
  end

  defp candidate(plan) do
    scope = plan.scope

    content =
      ArtifactReference.from_bytes("candidate_content", "{}",
        id: "content-1",
        media_type: "application/json",
        content_schema: "profile/v1",
        scope: scope
      )

    rationale =
      ArtifactReference.from_bytes("proposer_trace", "why",
        id: "rationale-1",
        media_type: "text/plain",
        content_schema: "rationale/v1",
        scope: scope
      )

    {:ok, candidate} =
      Candidate.new(plan, %{
        "id" => "cand-1",
        "scope" => scope,
        "parents" => [],
        "content" => ArtifactReference.to_map(content),
        "proposer" => plan.proposer,
        "rationale" => ArtifactReference.to_map(rationale),
        "interface_validation" => %{
          "status" => "passed",
          "validator_sha256" => plan.interface_validator["sha256"]
        },
        "exposures" => [],
        "mutation_kind" => "seed"
      })

    candidate
  end
end
