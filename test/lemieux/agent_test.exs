defmodule Lemieux.AgentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent, as: CustomAgent
  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Grader.Command
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Agent, as: AgentRuntime
  alias Lemieux.Benchmark.Task
  alias Lemieux.Clock.Manual
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  defmodule Review do
    @behaviour Lemieux.Agent

    alias Lemieux.Agent.Session

    @impl true
    def run(input, opts) do
      send(Keyword.fetch!(opts, :owner), {:agent_input, input})

      with {:ok, source} <- File.read(Path.join(input.cwd, "source.txt")),
           {:ok, observation} <-
             Session.run(
               %{input | prompt: input.prompt <> "\n" <> source},
               Keyword.fetch!(opts, :session)
             ) do
        if observation["answer"] == "verified finding" do
          {:ok, Map.put(observation, "validated", true)}
        else
          {:error, :invalid_finding, observation}
        end
      end
    end
  end

  defmodule Incomplete do
    @behaviour Lemieux.Agent

    @impl true
    def run(_input, _opts) do
      {:ok,
       %{
         "status" => "failed",
         "answer" => "correct artifact, unfinished run",
         "usage" => %{"cost_usd" => nil, "observed_cost_usd" => 0.2}
       }}
    end
  end

  defmodule RemovesWorkspace do
    @behaviour Lemieux.Agent

    @impl true
    def run(input, _opts) do
      File.rm_rf!(input.cwd)
      {:ok, %{"status" => "completed", "answer" => "done", "usage" => %{"cost_usd" => 0.2}}}
    end
  end

  test "the installed entry point and benchmark execute the same hybrid module", context do
    File.write!(Path.join(context.tmp_dir, "source.txt"), "actual source")
    owner = self()

    response = fn request ->
      send(owner, {:model_request, request})
      Scripted.complete("verified finding")
    end

    provider = Scripted.new([response, response])

    opts = [
      owner: owner,
      session: [
        provider: provider,
        model: "test:model",
        supervisor: :"hybrid_agent_#{System.unique_integer([:positive])}",
        sessions_dir: Path.join(context.tmp_dir, "sessions")
      ]
    ]

    input = %{prompt: "review", cwd: context.tmp_dir, timeout_ms: 5_000}
    assert {:ok, direct} = CustomAgent.run(Review, input, opts)
    assert direct["answer"] == "verified finding"
    assert direct["validated"]
    assert_received {:agent_input, ^input}
    assert_received {:model_request, request}

    assert Enum.any?(
             request.entries,
             &(&1.type == :user and &1.payload["text"] == "review\nactual source")
           )

    task = %Task{
      id: "review",
      prompt: input.prompt,
      cwd: input.cwd,
      timeout_ms: input.timeout_ms,
      metadata: %{"private_label" => "must not reach the agent"},
      grader: %Command{
        command: ["sh", "-c", "test \"$1\" = 'verified finding'", "grader", "{answer}"]
      }
    }

    runtime = Runtime.new("review", AgentRuntime, agent: Review, agent_options: opts)
    assert {:ok, report} = Benchmark.run(%Manifest{tasks: [task]}, [runtime])
    assert [%{"passed" => true, "observation" => observed}] = report["results"]
    assert observed["answer"] == direct["answer"]
    assert observed["validated"]
    assert_receive {:agent_input, benchmark_input}
    assert Map.keys(benchmark_input) |> Enum.sort() == [:cwd, :prompt, :timeout_ms]
    refute benchmark_input.cwd == input.cwd
  end

  test "an unfinished agent cannot pass through a permissive artifact grader", context do
    task = %Task{
      id: "incomplete",
      prompt: "work",
      cwd: context.tmp_dir,
      grader: %Command{command: ["sh", "-c", "true"]}
    }

    runtime = Runtime.new("incomplete", AgentRuntime, agent: Incomplete)
    assert {:ok, report} = Benchmark.run(%Manifest{tasks: [task]}, [runtime])

    assert [%{"passed" => false, "grader" => nil, "observation" => observation}] =
             report["results"]

    assert observation["usage"]["cost_usd"] == nil
    assert observation["usage"]["observed_cost_usd"] == 0.2
  end

  test "rejects malformed input and missing agent callbacks before dispatch", context do
    assert {:error, :invalid_agent_input} = CustomAgent.run(Review, %{cwd: context.tmp_dir})

    assert {:error, :invalid_agent_module} =
             CustomAgent.run(String, %{prompt: "x", cwd: context.tmp_dir, timeout_ms: 10})
  end

  test "post-run snapshot failure retains the agent's paid observation", context do
    cwd = Path.join(context.tmp_dir, "removed")
    File.mkdir!(cwd)
    task = %Task{id: "removed", prompt: "work", cwd: cwd, grader: %Command{command: ["true"]}}

    assert {:error, {:snapshot_list, "", :enoent}, observation} =
             AgentRuntime.run(task, agent: RemovesWorkspace)

    assert observation["usage"]["cost_usd"] == 0.2
  end

  test "the reusable session deadline is measured on the clock it is given", context do
    clock = Manual.new()
    supervisor = :"agent_session_clock_#{System.unique_integer([:positive])}"
    silent = Scripted.new([fn _request -> receive do: (:never -> :ok) end])

    run =
      Elixir.Task.async(fn ->
        CustomAgent.run(
          AgentSession,
          %{prompt: "work", cwd: context.tmp_dir, timeout_ms: 600_000},
          provider: silent,
          model: "test:model",
          supervisor: supervisor,
          sessions_dir: Path.join(context.tmp_dir, "sessions"),
          clock: clock
        )
      end)

    assert %{due_in: 600_000} =
             Manual.await_timer(clock, &match?({:agent_deadline, _}, &1.message))

    Manual.advance(clock, 599_999)
    assert Elixir.Task.yield(run, 0) == nil

    Manual.advance(clock, 1)
    assert {:error, :timeout, observation} = Elixir.Task.await(run)
    assert observation["finish_reason"] == ":agent_timeout"
    assert Lemieux.sessions(supervisor) == []
  end

  # The real-time check of the same deadline: 100 ms against a provider that
  # answers in five seconds, so only the outcome is asserted.
  test "the reusable session deadline retains evidence and terminates the temporary session",
       context do
    supervisor = :"agent_session_deadline_#{System.unique_integer([:positive])}"
    provider = Scripted.new([Scripted.delayed(5_000, Scripted.complete("too late"))])

    assert {:error, :timeout, observation} =
             CustomAgent.run(
               AgentSession,
               %{prompt: "work", cwd: context.tmp_dir, timeout_ms: 100},
               provider: provider,
               model: "test:model",
               supervisor: supervisor,
               sessions_dir: Path.join(context.tmp_dir, "sessions")
             )

    assert observation["finish_reason"] == ":agent_timeout"
    assert observation["usage"]["cost_usd"] == nil
    assert Enum.any?(observation["transcript"], &(&1["type"] == "run_evidence"))
    assert Lemieux.sessions(supervisor) == []
  end
end
