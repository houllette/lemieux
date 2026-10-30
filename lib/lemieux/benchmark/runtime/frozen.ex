defmodule Lemieux.Benchmark.Runtime.Frozen do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  A fresh compiled consumer for each attempt of a pinned extension build.
  """
  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Learning.Extension.Build

  @impl true
  def run(task, opts) do
    Build.run(Keyword.fetch!(opts, :build), Map.take(task, [:prompt, :cwd, :timeout_ms]), opts)
  end
end
