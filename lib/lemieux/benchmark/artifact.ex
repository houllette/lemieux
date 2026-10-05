defmodule Lemieux.Benchmark.Artifact do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Writes the complete JSON artifact from a benchmark run.

  The file is written only after the run is complete. Long-running hosts that
  need crash-resilient incremental results can consume the returned per-run
  maps and persist them in their own store instead.
  """

  @doc "Writes `report` to `path`, creating its parent directory."
  @spec write(path :: Path.t(), report :: map()) :: :ok | {:error, term()}
  def write(path, report) when is_binary(path) and is_map(report) do
    with :ok <- File.mkdir_p(Path.dirname(Path.expand(path))) do
      File.write(path, [JSON.encode!(report), ?\n])
    end
  end
end
