defmodule Lemieux.BenchmarkTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Task

  @moduletag :tmp_dir

  defmodule FakeRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(task, opts) do
      if Keyword.fetch!(opts, :solve), do: File.write!(Path.join(task.cwd, "solved.txt"), "yes")

      {:ok,
       %{
         "status" => "completed",
         "answer" => Keyword.get(opts, :answer, "done"),
         "usage" => %{"cost_usd" => Keyword.fetch!(opts, :cost_usd)}
       }}
    end
  end

  defmodule CrashingRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(_task, _opts), do: raise("boom")
  end

  defmodule ConcurrentRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(_task, opts) do
      tracker = Keyword.fetch!(opts, :tracker)

      Agent.update(tracker, fn state ->
        active = state.active + 1
        %{state | active: active, peak: max(state.peak, active)}
      end)

      send(Keyword.fetch!(opts, :owner), {:attempt_entered, self()})
      receive do: (:release -> :ok)
      Agent.update(tracker, &%{&1 | active: &1.active - 1})

      {:ok, %{"answer" => "done", "usage" => %{"cost_usd" => 0.0}}}
    end
  end

  defmodule CountingRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(_task, opts) do
      Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))
      {:ok, %{"answer" => "done", "usage" => %{"cost_usd" => 0.1}}}
    end
  end

  defmodule UnknownCostRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(_task, opts) do
      Agent.update(Keyword.fetch!(opts, :counter), &(&1 + 1))
      {:ok, %{"answer" => "done", "usage" => %{}}}
    end
  end

  # Fails the first `fail` runs, then succeeds. The counter is the whole point:
  # a retried attempt has to be visible as a second run of the same attempt.
  defmodule FlakyRuntime do
    @behaviour Lemieux.Benchmark.Runtime

    @impl Lemieux.Benchmark.Runtime
    def run(task, opts) do
      counter = Keyword.fetch!(opts, :counter)
      run = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if run <= Keyword.fetch!(opts, :fail) do
        {:ok,
         %{
           "answer" => "",
           "finish_reason" => ":error",
           "session_id" => "session-#{run}",
           "provider_error" => %{"category" => "timeout", "reason" => "Stream failed: :timeout"},
           "resources" => %{
             "tokens_complete" => true,
             "full_input_tokens" => run * 10,
             "output_tokens" => run
           },
           "usage" => %{"cost_usd" => 0.25}
         }}
      else
        File.write!(Path.join(task.cwd, "solved.txt"), "yes")

        {:ok,
         %{"answer" => "done", "session_id" => "session-#{run}", "usage" => %{"cost_usd" => 0.5}}}
      end
    end
  end

  test "retries an attempt the caller calls apparatus failure and keeps the discarded try",
       context do
    fixture = Path.join(context.tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    task = %Task{
      id: "flaky",
      prompt: "repair it",
      cwd: fixture,
      grader: %CommandGrader{command: ["sh", "-c", "test -f solved.txt"]}
    }

    stalled? = &(get_in(&1, ["observation", "provider_error", "category"]) == "timeout")

    assert {:ok, report} =
             Benchmark.run(
               %Manifest{tasks: [task]},
               [Runtime.new("under-test", FlakyRuntime, counter: counter, fail: 1)],
               retry: [max: 1, when: stalled?],
               workspace_root: Path.join(context.tmp_dir, "workspaces")
             )

    # One planned attempt, one retained result, two runs paid for.
    assert Agent.get(counter, & &1) == 2
    assert [result] = report["results"]
    assert result["attempt"] == 1
    assert result["passed"] == true
    assert get_in(result, ["observation", "session_id"]) == "session-2"

    assert [discarded] = result["retries"]
    assert discarded["discarded"] == true
    assert discarded["session_id"] == "session-1"
    assert discarded["cost_usd"] == 0.25
    assert discarded["resources"]["full_input_tokens"] == 10

    # Both connections were paid for; charging only the retained one would let
    # a cost cap authorize twice what it meant to.
    assert report["execution"]["actual_cost_usd"] == 0.75
  end

  test "stops retrying at the caller's limit and rejects a retry option it cannot honour",
       context do
    fixture = Path.join(context.tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    task = %Task{
      id: "always-stalls",
      prompt: "repair it",
      cwd: fixture,
      grader: %CommandGrader{command: ["sh", "-c", "test -f solved.txt"]}
    }

    manifest = %Manifest{tasks: [task]}
    runtimes = [Runtime.new("under-test", FlakyRuntime, counter: counter, fail: 99)]
    workspace = Path.join(context.tmp_dir, "workspaces")

    assert {:ok, report} =
             Benchmark.run(manifest, runtimes,
               retry: [max: 2, when: fn _result -> true end],
               workspace_root: workspace
             )

    assert Agent.get(counter, & &1) == 3
    assert [result] = report["results"]
    assert length(result["retries"]) == 2
    assert result["passed"] == false

    assert {:error, :invalid_retry} =
             Benchmark.run(manifest, runtimes, retry: [max: 0], workspace_root: workspace)

    assert {:error, :invalid_retry} =
             Benchmark.run(manifest, runtimes,
               retry: [max: 1, when: :not_a_function],
               workspace_root: workspace
             )
  end

  test "runs paired attempts in fresh workspaces and writes a JSON artifact", context do
    fixture = Path.join(context.tmp_dir, "fixture")
    File.mkdir_p!(fixture)
    File.write!(Path.join(fixture, "baseline.txt"), "unchanged")

    task = %Task{
      id: "repair",
      prompt: "repair it",
      cwd: fixture,
      grader: %CommandGrader{command: ["sh", "-c", "test -f solved.txt"]}
    }

    runtimes = [
      Runtime.new("native", FakeRuntime, solve: true, cost_usd: 0.25),
      Runtime.new("baseline", FakeRuntime, solve: false, cost_usd: 0.5)
    ]

    artifact = Path.join(context.tmp_dir, "report.json")

    assert {:ok, report} =
             Benchmark.run(%Manifest{tasks: [task]}, runtimes,
               repetitions: 2,
               output: artifact,
               workspace_root: Path.join(context.tmp_dir, "workspaces")
             )

    assert length(report["results"]) == 4
    assert report["summary"]["runtimes"]["native"]["completion_rate"] == 1.0
    assert report["summary"]["runtimes"]["baseline"]["completion_rate"] == 0.0

    assert [pair] = report["summary"]["pairs"]
    assert pair["completion_rate_delta"] == -1.0
    assert pair["mean_cost_usd_delta"] == 0.25

    persisted = artifact |> File.read!() |> JSON.decode!()
    assert persisted["schema_version"] == 1
    assert persisted["summary"] == report["summary"]

    refute File.exists?(Path.join(fixture, "solved.txt"))
  end

  test "reports attempt progress without coupling observers to execution", context do
    task = %Task{
      id: "visible",
      prompt: "run",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtime = Runtime.new("observed", FakeRuntime, solve: false, cost_usd: 0.0)

    assert {:ok, %{"results" => [result]}} =
             Benchmark.run(%Manifest{tasks: [task]}, [runtime],
               workspace: :in_place,
               progress: self()
             )

    assert_receive {:benchmark_progress,
                    %{
                      event: :attempt_started,
                      id: {"visible", "observed", 1},
                      task_id: "visible",
                      runtime: "observed",
                      timeout_ms: timeout_ms
                    }}

    assert timeout_ms == task.timeout_ms

    assert_receive {:benchmark_progress,
                    %{
                      event: :attempt_finished,
                      id: {"visible", "observed", 1},
                      passed: true,
                      requests: nil,
                      wall_time_ms: elapsed
                    }}

    assert elapsed >= result["wall_time_ms"]

    assert {:ok, _report} =
             Benchmark.run(%Manifest{tasks: [task]}, [runtime],
               workspace: :in_place,
               progress: fn _event -> raise "observer failed" end
             )
  end

  test "rejects an invalid progress observer", context do
    task = %Task{
      id: "visible",
      prompt: "run",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtime = Runtime.new("observed", FakeRuntime, solve: false, cost_usd: 0.0)

    assert {:error, :invalid_progress_reporter} =
             Benchmark.run(%Manifest{tasks: [task]}, [runtime], progress: :stdout)
  end

  test "captures a runtime crash as a failed observation and continues", context do
    task = %Task{
      id: "crash",
      prompt: "try",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtime = Runtime.new("crashing", CrashingRuntime)

    assert {:ok, %{"results" => [result]}} =
             Benchmark.run(%Manifest{tasks: [task]}, [runtime])

    refute result["passed"]
    assert result["grader"] == nil
    assert result["error"] =~ "boom"
  end

  test "bounds attempt concurrency", context do
    {:ok, tracker} = Agent.start_link(fn -> %{active: 0, peak: 0} end)
    runtime = Runtime.new("parallel", ConcurrentRuntime, tracker: tracker, owner: self())

    tasks =
      Enum.map(1..4, fn index ->
        %Task{
          id: "parallel-#{index}",
          prompt: "run",
          cwd: context.tmp_dir,
          grader: %CommandGrader{command: ["sh", "-c", "true"]}
        }
      end)

    run =
      Elixir.Task.async(fn ->
        Benchmark.run(%Manifest{tasks: tasks}, [runtime],
          workspace: :in_place,
          max_concurrency: 2
        )
      end)

    for _batch <- 1..2 do
      workers =
        for _ <- 1..2 do
          assert_receive {:attempt_entered, worker}
          worker
        end

      Enum.each(workers, &send(&1, :release))
    end

    assert {:ok, report} = Elixir.Task.await(run)

    assert length(report["results"]) == 4
    assert Agent.get(tracker, & &1.peak) == 2
  end

  test "rejects an over-budget estimate and stops scheduling after actual cost crosses the cap",
       context do
    tasks =
      Enum.map(1..3, fn index ->
        %Task{
          id: "budget-#{index}",
          prompt: "run",
          cwd: context.tmp_dir,
          grader: %CommandGrader{command: ["sh", "-c", "true"]}
        }
      end)

    runtime = Runtime.new("costly", FakeRuntime, solve: false, cost_usd: 0.6)

    assert {:error, {:estimated_cost_exceeds_cap, 2.0, 1.0}} =
             Benchmark.run(%Manifest{tasks: tasks}, [runtime],
               estimated_cost_usd: 2.0,
               cost_cap_usd: 1.0
             )

    assert {:ok, report} =
             Benchmark.run(%Manifest{tasks: tasks}, [runtime],
               workspace: :in_place,
               cost_cap_usd: 1.0,
               max_concurrency: 1
             )

    assert length(report["results"]) == 2
    assert report["execution"]["aborted"]
    assert report["execution"]["reason"] == "cost_cap"
    assert report["execution"]["actual_cost_usd"] == 1.2
  end

  test "does not start a concurrent batch whose worst-case reservation exceeds the cap",
       context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    runtime = Runtime.new("counting", CountingRuntime, counter: counter)

    tasks =
      Enum.map(1..3, fn index ->
        %Task{
          id: "reserved-#{index}",
          prompt: "run",
          cwd: context.tmp_dir,
          grader: %CommandGrader{command: ["true"]}
        }
      end)

    assert {:ok, report} =
             Benchmark.run(%Manifest{tasks: tasks}, [runtime],
               workspace: :in_place,
               cost_cap_usd: 0.65,
               max_cost_per_attempt_usd: 0.6,
               max_concurrency: 2
             )

    assert Agent.get(counter, & &1) == 1
    assert report["execution"]["scheduled"] == 1
    assert report["execution"]["aborted"]
    assert report["execution"]["reason"] == "cost_reservation"
    assert report["execution"]["reserved_cost_usd"] == 0.6
    assert report["execution"]["released_cost_usd"] == 0.5
  end

  test "unknown measured cost consumes its reservation instead of becoming free", context do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    runtime = Runtime.new("unknown-cost", UnknownCostRuntime, counter: counter)

    tasks =
      Enum.map(1..2, fn index ->
        %Task{
          id: "unknown-cost-#{index}",
          prompt: "run",
          cwd: context.tmp_dir,
          grader: %CommandGrader{command: ["true"]}
        }
      end)

    assert {:ok, report} =
             Benchmark.run(%Manifest{tasks: tasks}, [runtime],
               workspace: :in_place,
               cost_cap_usd: 0.7,
               max_cost_per_attempt_usd: 0.6,
               max_concurrency: 2
             )

    assert Agent.get(counter, & &1) == 1
    assert report["execution"]["actual_cost_usd"] == 0.6
    assert report["execution"]["unknown_cost_runs"] == 1
    assert report["execution"]["released_cost_usd"] == 0.0
  end

  defmodule ControlledRuntime do
    @behaviour Lemieux.Benchmark.Runtime
    @impl true
    def run(_task, opts) do
      owner = Keyword.fetch!(opts, :owner)
      label = Keyword.fetch!(opts, :label)
      send(owner, {:entered, label, self()})

      # Far longer than the suite's five-second wait for an event, so an
      # attempt ends only when the test releases it, and the wait for fast2
      # really is "while the slow attempt is still running". At two seconds
      # the slow attempt could end on its own inside that wait.
      receive do
        :release -> {:ok, %{"answer" => "done", "usage" => %{"cost_usd" => 0.1}}}
      after
        :timer.minutes(1) -> {:error, :test_release_timeout}
      end
    end
  end

  test "uncapped runs refill a free worker before the slowest active attempt finishes", context do
    owner = self()

    task = %Task{
      id: "refill",
      prompt: "try",
      cwd: context.tmp_dir,
      grader: %CommandGrader{command: ["sh", "-c", "true"]}
    }

    runtimes =
      Enum.map(~w(slow fast1 fast2), fn name ->
        Runtime.new(name, ControlledRuntime, owner: owner, label: name)
      end)

    job =
      Elixir.Task.async(fn ->
        Benchmark.run(%Manifest{tasks: [task]}, runtimes, max_concurrency: 2)
      end)

    assert_receive {:entered, "slow", slow}
    assert_receive {:entered, "fast1", first}
    refute_receive {:entered, "fast2", _}, 30
    send(first, :release)

    try do
      assert_receive {:entered, "fast2", second}
      send(second, :release)
    after
      send(slow, :release)
    end

    assert {:ok, report} = Elixir.Task.await(job, 5_000)
    assert Enum.map(report["results"], & &1["runtime"]) == ~w(slow fast1 fast2)
    assert report["execution"]["scheduled"] == 3
    assert_in_delta report["execution"]["actual_cost_usd"], 0.3, 0.0001
    refute report["execution"]["aborted"]
  end
end
