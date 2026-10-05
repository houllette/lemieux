defmodule Lemieux.Benchmark do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Comparative, mechanically graded evaluation for coding-agent runtimes.

  A benchmark combines a versioned `Lemieux.Benchmark.Manifest` with two or
  more named `Lemieux.Benchmark.Runtime` implementations. Each runtime receives
  the same task in a fresh workspace, the task's command grader decides whether
  the result works, and the report compares completion rate, wall time and cost.

  This module deliberately contains no host's private corpus and no vendor CLI
  flags. Those belong to the host that owns the repositories, credentials and
  billing regime. See `docs/benchmarking.md` for the methodology and a complete example.
  """

  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Runner
  alias Lemieux.Benchmark.Runtime

  @doc """
  Runs a decoded manifest through the supplied runtimes.

  Pass `progress: pid` to receive `{:benchmark_progress, event}` messages, or
  `progress: callback` for an arity-one observer. Attempt start/finish events
  are best-effort observability: callback failures never abort paid work.
  """
  @spec run(Manifest.t(), [Runtime.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(%Manifest{} = manifest, runtimes, opts \\ []),
    do: Runner.run(manifest, runtimes, opts)

  @doc "Reads a manifest and runs it through the supplied runtimes."
  @spec run_file(Path.t(), [Runtime.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run_file(path, runtimes, opts \\ []) when is_binary(path) do
    with {:ok, manifest} <- Manifest.read(path), do: run(manifest, runtimes, opts)
  end
end
