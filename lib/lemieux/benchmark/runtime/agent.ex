defmodule Lemieux.Benchmark.Runtime.Agent do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Evaluates an installed `Lemieux.Agent` through its normal entry point.

  Pass `agent: MyAgent` and `agent_options: [...]` to `Runtime.new/3`.
  Options may also be a zero-arity factory, evaluated once inside each attempt.
  Use a factory for process-backed providers so repetitions and later runs do
  not inherit an exhausted script or a stopped provider from an earlier run.
  The benchmark owns workspace copies, pairing and grading. The agent receives
  neither the grader nor task metadata. Whole-composition file changes include
  deterministic stages as well as model tools. This local adapter cannot
  attest that code stayed inside the workspace.
  """

  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Agent
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.WorkspaceSnapshot

  @impl true
  def run(%Task{} = task, opts) do
    with {:ok, agent} <- Keyword.fetch(opts, :agent),
         {:ok, before_snapshot} <- WorkspaceSnapshot.capture(task.cwd) do
      input = Map.take(task, [:prompt, :cwd, :timeout_ms])
      result = Agent.run(agent, input, options(Keyword.get(opts, :agent_options, [])))
      capture(result, task.cwd, before_snapshot)
    else
      :error -> {:error, {:agent, :required}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp options(factory) when is_function(factory, 0), do: factory.()
  defp options(options), do: options

  defp capture({:ok, observation}, cwd, before_snapshot) do
    case changes(observation, cwd, before_snapshot) do
      {:ok, observation} -> {:ok, observation}
      {:error, reason} -> {:error, reason, observation}
    end
  end

  defp capture({:error, reason, observation}, cwd, before_snapshot) do
    case changes(observation, cwd, before_snapshot) do
      {:ok, observation} -> {:error, reason, observation}
      {:error, snapshot_reason} -> {:error, {reason, snapshot_reason}, observation}
    end
  end

  defp capture({:error, _reason} = error, _cwd, _before_snapshot), do: error

  defp changes(observation, cwd, before_snapshot) do
    with {:ok, after_snapshot} <- WorkspaceSnapshot.capture(cwd) do
      {:ok,
       observation
       |> Map.put("changed_paths", WorkspaceSnapshot.changed(before_snapshot, after_snapshot))
       |> Map.put("safety_violations", nil)}
    end
  end
end
