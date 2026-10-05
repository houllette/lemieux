defmodule Lemieux.Benchmark.Runtime.Fixture do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Replays provider-neutral benchmark observations without making a model call.

  A version-one fixture set is a JSON object with an `observations` object keyed
  by task id. An observation may contain a `writes` object; those files are
  written through `Lemieux.Environment.Local`, so absolute paths, `..`, and
  escaping symlinks are rejected exactly as they are for the bundled tools.

  Fixtures are the stable Test Mode input. Recording them is an explicit live
  operation performed by a host; ordinary tests only replay committed data.
  """

  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Benchmark.Task
  alias Lemieux.Environment

  @impl Lemieux.Benchmark.Runtime
  def run(%Task{} = task, opts) do
    with {:ok, fixture_set} <- fixture_set(opts),
         {:ok, observation} <- observation(fixture_set, task.id),
         {:ok, changed_paths} <- apply_writes(task, Map.get(observation, "writes", %{})) do
      recorded_paths = Map.get(observation, "changed_paths", [])

      {:ok,
       observation
       |> Map.delete("writes")
       |> Map.put_new("answer", "")
       |> Map.put_new("status", "completed")
       |> Map.put("changed_paths", Enum.sort(Enum.uniq(recorded_paths ++ changed_paths)))
       |> Map.put_new("safety_violations", [])}
    end
  end

  defp fixture_set(opts) do
    case {Keyword.get(opts, :observations), Keyword.get(opts, :path)} do
      {%{} = fixture_set, nil} -> validate(fixture_set)
      {nil, path} when is_binary(path) -> read(path)
      {nil, nil} -> {:error, :fixture_set_required}
      {_observations, _path} -> {:error, :ambiguous_fixture_set}
    end
  end

  defp read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- decode(body) do
      validate(decoded)
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_fixture_json, Lemieux.JSON.describe_error(reason)}}
    end
  end

  defp validate(%{"version" => 1, "observations" => observations} = fixture_set)
       when is_map(observations),
       do: {:ok, fixture_set}

  defp validate(%{"version" => version}), do: {:error, {:unsupported_fixture_version, version}}
  defp validate(_fixture_set), do: {:error, :invalid_fixture_set}

  defp observation(%{"observations" => observations}, task_id) do
    case Map.fetch(observations, task_id) do
      {:ok, observation} when is_map(observation) -> {:ok, observation}
      {:ok, _invalid} -> {:error, {:invalid_fixture_observation, task_id}}
      :error -> {:error, {:fixture_observation_not_found, task_id}}
    end
  end

  defp apply_writes(_task, writes) when map_size(writes) == 0, do: {:ok, []}

  defp apply_writes(%Task{} = task, writes) when is_map(writes) do
    writes
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn
      {path, contents}, {:ok, changed} when is_binary(path) and is_binary(contents) ->
        case Environment.write_file(Environment.local(), task.cwd, path, contents) do
          {:ok, _status} -> {:cont, {:ok, [path | changed]}}
          {:error, reason} -> {:halt, {:error, {:fixture_write, path, reason}}}
        end

      {path, _contents}, _acc ->
        {:halt, {:error, {:invalid_fixture_write, path}}}
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp apply_writes(_task, _writes), do: {:error, :invalid_fixture_writes}
end
