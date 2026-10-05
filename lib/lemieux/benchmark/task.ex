defmodule Lemieux.Benchmark.Task do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  One mechanically graded benchmark task.

  Tasks are data rather than callbacks so the same manifest can be run through
  the native harness and an external command. The working directory is resolved
  when the manifest is read; runners normally copy it before each attempt so
  paired runtimes never inherit one another's edits.
  """

  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader

  @type t :: %__MODULE__{
          id: String.t(),
          prompt: String.t(),
          cwd: Path.t(),
          timeout_ms: pos_integer(),
          grader: CommandGrader.t(),
          metadata: map()
        }

  @enforce_keys [:id, :prompt, :cwd, :grader]
  defstruct [:id, :prompt, :cwd, :grader, timeout_ms: :timer.minutes(10), metadata: %{}]

  @doc false
  @spec from_map(map(), Path.t()) :: {:ok, t()} | {:error, String.t()}
  def from_map(map, base_dir) when is_map(map) and is_binary(base_dir) do
    with {:ok, id} <- nonempty(map, "id"),
         {:ok, prompt} <- nonempty(map, "prompt"),
         {:ok, cwd} <- cwd(map, base_dir),
         {:ok, timeout_ms} <- positive(map, "timeout_ms", :timer.minutes(10)),
         {:ok, grader} <- CommandGrader.from_map(Map.get(map, "grader")),
         {:ok, metadata} <- metadata(map) do
      {:ok,
       %__MODULE__{
         id: id,
         prompt: prompt,
         cwd: cwd,
         timeout_ms: timeout_ms,
         grader: grader,
         metadata: metadata
       }}
    end
  end

  def from_map(_map, _base_dir), do: {:error, "each benchmark task must be an object"}

  defp cwd(map, base_dir) do
    case Map.get(map, "cwd", ".") do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path, base_dir)}
      _invalid -> {:error, "task cwd must be a non-empty string"}
    end
  end

  defp metadata(map) do
    case Map.get(map, "metadata", %{}) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _invalid -> {:error, "task metadata must be an object"}
    end
  end

  defp nonempty(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, "task #{key} must be a non-empty string"}
    end
  end

  defp positive(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, "task #{key} must be a positive integer"}
    end
  end
end
