defmodule Lemieux.Benchmark.Runtime.Native do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Runs a benchmark task through the reusable `Lemieux.Agent.Session` runner.

  Provider/model, workspace effects, transcripts, usage completeness and timeout
  cleanup use exactly the session path available to exported agent packages.
  The historical supervisor name and timeout reason remain compatible with
  existing benchmark hosts and evidence consumers.
  """

  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Agent.Session
  alias Lemieux.Benchmark.Task

  @impl true
  def run(%Task{} = task, opts) do
    opts =
      opts
      |> Keyword.put_new(:detach_runtime, not Keyword.has_key?(opts, :supervisor))
      |> Keyword.put_new(:supervisor, Lemieux.Benchmark.NativeSupervisor)
      |> Keyword.put(:timeout_reason, :benchmark_timeout)

    Session.run(Map.take(task, [:prompt, :cwd, :timeout_ms]), opts)
  end
end
