defmodule Lemieux.Benchmark.Runtime.NativeTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Native
  alias Lemieux.Benchmark.Task
  alias Lemieux.Providers.Scripted
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Delegate

  @moduletag :tmp_dir

  test "a benchmark deadline retains partial evidence and consumes the unknown-cost reservation",
       context do
    owner = self()

    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{"path" => "created.txt", "content" => "partial"},
          usage: %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => 0.01}
        ),
        fn _request ->
          send(owner, {:provider_task, self()})
          Scripted.delayed(30_000, Scripted.complete("too late"))
        end
      ])

    cwd = Path.join(context.tmp_dir, "workspace")
    File.mkdir!(cwd)

    task = %Task{
      id: "deadline",
      prompt: "work",
      cwd: cwd,
      grader: %CommandGrader{command: ["sh", "-c", "touch should-not-grade; true"]}
    }

    supervisor = :"benchmark_deadline_test_#{System.unique_integer([:positive])}"

    runtime =
      Runtime.new("native", Native,
        provider: provider,
        model: "test:model",
        supervisor: supervisor,
        sessions_dir: Path.join(context.tmp_dir, "sessions"),
        # Parallel suites can spend a second scheduling the first tool call;
        # leave room for the second request to start before the deadline.
        timeout_ms: 5_000
      )

    assert {:ok, report} =
             Lemieux.Benchmark.run(%Lemieux.Benchmark.Manifest{tasks: [task]}, [runtime],
               workspace: :in_place,
               cost_cap_usd: 0.02,
               max_cost_per_attempt_usd: 0.02
             )

    assert [result] = report["results"]
    refute result["passed"]
    assert result["error"] == ":timeout"
    assert result["grader"] == nil
    refute File.exists?(Path.join(cwd, "should-not-grade"))
    observation = result["observation"]
    assert observation["status"] == "failed"
    assert observation["finish_reason"] == ":benchmark_timeout"
    assert observation["changed_paths"] == ["created.txt"]
    assert observation["usage"]["requests"] == 1
    assert observation["usage"]["input_tokens"] == 10
    assert observation["usage"]["observed_cost_usd"] == 0.01
    assert observation["usage"]["cost_usd"] == nil
    assert observation["usage"]["direct"]["cost_usd"] == nil
    assert observation["tool_metrics"]["requests"] == 2
    evidence = Enum.find(observation["transcript"], &(&1["type"] == "run_evidence"))
    assert evidence["payload"]["completeness"]["usage"] == "partial"
    assert report["execution"]["unknown_cost_runs"] == 1
    assert report["execution"]["actual_cost_usd"] == 0.02
    assert_received {:provider_task, worker}
    refute Process.alive?(worker)
  end

  test "an unanswered request leaves total cost unknown while retaining reported usage",
       context do
    provider =
      Scripted.new([
        Scripted.tool_call("read", "read", %{"path" => "."},
          usage: %{"input_tokens" => 10, "output_tokens" => 2, "cost_usd" => 0.01}
        ),
        [{:error, :connection_lost}]
      ])

    task = %Task{
      id: "partial-cost",
      prompt: "work",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["true"]}
    }

    supervisor = :"benchmark_partial_cost_test_#{System.unique_integer([:positive])}"

    assert {:ok, observation} =
             Native.run(task,
               provider: provider,
               model: "test:model",
               supervisor: supervisor,
               sessions_dir: Path.join(context.tmp_dir, "sessions")
             )

    assert observation["status"] == "failed"
    assert observation["usage"]["requests"] == 1
    assert observation["tool_metrics"]["requests"] == 2
    assert observation["usage"]["input_tokens"] == 10
    assert observation["usage"]["cost_usd"] == nil
    assert observation["usage"]["observed_cost_usd"] == 0.01
  end

  test "runs through the public session API and returns transcript and usage", context do
    provider =
      Scripted.new([
        [
          {:text_delta, "done"},
          {:usage, %{input_tokens: 10, output_tokens: 2, total_cost: 0.01}},
          {:done, :stop}
        ]
      ])

    task = %Task{
      id: "native",
      prompt: "finish",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtime = :"benchmark_native_test_#{System.unique_integer([:positive])}"

    assert {:ok, observation} =
             Native.run(task,
               provider: provider,
               model: "test:model",
               supervisor: runtime,
               sessions_dir: Path.join(context.tmp_dir, "sessions")
             )

    assert observation["status"] == "completed"
    assert observation["answer"] == "done"
    assert observation["usage"]["requests"] == 1
    assert observation["usage"]["input_tokens"] == 10
    assert observation["usage"]["cost_usd"] == 0.01
    assert observation["tool_metrics"]["requests"] == 1
    assert observation["tool_metrics"]["catalog_bytes"] > 0
    assert observation["tool_metrics"]["calls"] == 0
    assert observation["tool_metrics"]["profile_ids"] == ["legacy"]

    assert Enum.map(observation["transcript"], & &1["type"]) == [
             "session",
             "user",
             "harness_snapshot",
             "request",
             "assistant",
             "run_evidence"
           ]
  end

  test "reports direct and delegated usage plus an inclusive total", context do
    child =
      Scripted.new(
        [
          [
            {:text_delta,
             JSON.encode!(%{
               "answer" => "child evidence",
               "findings" => [],
               "artifacts" => [],
               "uncertainties" => [],
               "coverage" => %{"searched" => ["lib"], "skipped" => []}
             })},
            {:usage, %{"input_tokens" => 8, "output_tokens" => 3, "cost_usd" => 0.01}},
            {:done, :stop}
          ]
        ],
        estimated_cost_usd: 0.01
      )

    parent =
      Scripted.new([
        [
          {:tool_call,
           %{
             id: "delegate-1",
             name: "delegate",
             arguments: %{
               "tasks" => [%{"definition_id" => "scout", "objective" => "inspect code"}]
             }
           }},
          {:usage, %{"input_tokens" => 5, "output_tokens" => 1, "cost_usd" => 0.02}},
          {:done, :tool_calls}
        ],
        [
          {:text_delta, "done"},
          {:usage, %{"input_tokens" => 7, "output_tokens" => 2, "cost_usd" => 0.03}},
          {:done, :stop}
        ]
      ])

    definition =
      Definition.new(
        id: "scout",
        description: "Reads one subsystem",
        system_prompt: "Return evidence",
        model: "test:child",
        tools: [],
        max_cost_usd: 0.1
      )

    task = %Task{
      id: "delegated-native",
      prompt: "investigate",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtime = :"benchmark_delegated_native_test_#{System.unique_integer([:positive])}"

    assert {:ok, observation} =
             Native.run(task,
               provider: parent,
               model: "test:parent",
               supervisor: runtime,
               sessions_dir: Path.join(context.tmp_dir, "sessions"),
               session_options: [
                 tools: [
                   Delegate.new([definition],
                     snapshot: %{"revision" => "fixture"},
                     max_cost_usd: 0.1,
                     providers: %{"scout" => child}
                   )
                 ]
               ]
             )

    assert observation["usage"] == %{
             "requests" => 3,
             "input_tokens" => 20,
             "output_tokens" => 6,
             "cache_read_tokens" => 0,
             "cache_write_tokens" => 0,
             "cost_usd" => 0.06,
             "direct" => %{
               "requests" => 2,
               "input_tokens" => 12,
               "output_tokens" => 3,
               "cache_read_tokens" => 0,
               "cache_write_tokens" => 0,
               "cost_usd" => 0.05
             },
             "delegated" => %{
               "requests" => 1,
               "input_tokens" => 8,
               "output_tokens" => 3,
               "cache_read_tokens" => 0,
               "cache_write_tokens" => 0,
               "cost_usd" => 0.01
             }
           }
  end

  test "records workspace changes for deterministic safety scoring", context do
    provider =
      Scripted.new([
        Scripted.tool_call("write-1", "write", %{"path" => "created.txt", "content" => "safe\n"}),
        Scripted.complete("done")
      ])

    task = %Task{
      id: "native-changes",
      prompt: "write one file",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "test -f created.txt"]}
    }

    runtime = :"benchmark_native_changes_test_#{System.unique_integer([:positive])}"

    sessions_dir =
      Path.join(System.tmp_dir!(), "lemieux-native-changes-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(sessions_dir) end)

    assert {:ok, observation} =
             Native.run(task,
               provider: provider,
               model: "test:model",
               supervisor: runtime,
               sessions_dir: sessions_dir
             )

    assert observation["changed_paths"] == ["created.txt"]
    assert observation["safety_violations"] == nil
  end
end
