defmodule Lemieux.Benchmark.Manifest do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The versioned, provider-neutral input to a benchmark run.

  Version one is JSON with a non-empty `tasks` array. Unknown versions are
  refused rather than guessed at: an evaluation whose grader was interpreted
  differently is not comparable to the run beside it.
  """

  alias Lemieux.Benchmark.Task

  @version 1

  @type t :: %__MODULE__{version: pos_integer(), tasks: [Task.t()], metadata: map()}

  @enforce_keys [:tasks]
  defstruct version: @version, tasks: [], metadata: %{}

  @doc "Reads and validates a benchmark manifest from `path`."
  @spec read(path :: Path.t()) :: {:ok, t()} | {:error, term()}
  def read(path) when is_binary(path) do
    with {:ok, body} <- File.read(path) do
      decode(body, Path.dirname(Path.expand(path)))
    end
  end

  @doc "Decodes a manifest, resolving task paths against `base_dir`."
  @spec decode(json :: String.t(), base_dir :: Path.t()) :: {:ok, t()} | {:error, term()}
  def decode(json, base_dir \\ File.cwd!()) when is_binary(json) and is_binary(base_dir) do
    json
    |> JSON.decode!()
    |> from_map(base_dir)
  rescue
    error in JSON.DecodeError -> {:error, {:invalid_json, Exception.message(error)}}
  end

  @doc false
  @spec from_map(map(), Path.t()) :: {:ok, t()} | {:error, term()}
  def from_map(%{"version" => @version, "tasks" => tasks} = map, base_dir)
      when is_list(tasks) and tasks != [] do
    with {:ok, tasks} <- build_tasks(tasks, base_dir),
         {:ok, metadata} <- metadata(map) do
      {:ok, %__MODULE__{tasks: tasks, metadata: metadata}}
    end
  end

  def from_map(%{"version" => @version, "tasks" => []}, _base_dir),
    do: {:error, :no_tasks}

  def from_map(%{"version" => version}, _base_dir),
    do: {:error, {:unsupported_version, version}}

  def from_map(_map, _base_dir), do: {:error, :invalid_manifest}

  defp build_tasks(tasks, base_dir) do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, built} ->
      case Task.from_map(task, base_dir) do
        {:ok, task} -> {:cont, {:ok, [task | built]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, built} -> unique_ids(Enum.reverse(built))
      error -> error
    end
  end

  defp unique_ids(tasks) do
    ids = Enum.map(tasks, & &1.id)

    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: {:ok, tasks},
      else: {:error, :duplicate_task_id}
  end

  defp metadata(map) do
    case Map.get(map, "metadata", %{}) do
      metadata when is_map(metadata) -> {:ok, metadata}
      _invalid -> {:error, :invalid_metadata}
    end
  end
end
