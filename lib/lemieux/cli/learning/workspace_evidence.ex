defmodule Lemieux.CLI.Learning.WorkspaceEvidence do
  @moduledoc """
  Bounded changed-workspace bytes retained before an isolated lease disappears.

  A transcript does not reconstruct shell-generated files. Keep actual changed
  regular-file bytes, deletions and link targets alongside the source snapshot.
  Oversized, unreadable or excessive changes remain explicit omissions and
  refuse complete qualification; truncation cannot look like complete file evidence.
  Artifacts stay in the private host store, outside model workspaces.
  """
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.Contract

  @spec capture(source :: Path.t(), workspace :: Path.t()) :: map()
  def capture(source, workspace) do
    with {:ok, before} <- WorkspaceSnapshot.capture(source),
         {:ok, current} <- WorkspaceSnapshot.capture(workspace) do
      paths = WorkspaceSnapshot.changed(before, current)

      {entries, _size} =
        Enum.map_reduce(Enum.take(paths, 256), 0, &entry(workspace, &1, current, &2))

      seal(%{
        "schema_version" => 1,
        "kind" => "changed_workspace_bytes",
        "changed_paths" => paths,
        "entries" => entries,
        "complete" => length(paths) <= 256 and Enum.all?(entries, &(&1["retained"] == true))
      })
    else
      _unavailable ->
        seal(%{
          "schema_version" => 1,
          "kind" => "changed_workspace_bytes",
          "complete" => false,
          "reason" => "snapshot_unavailable"
        })
    end
  end

  defp entry(workspace, path, current, size) do
    base = %{
      "path" => path,
      "snapshot_sha256" => if(current[path], do: Base.encode16(current[path], case: :lower))
    }

    case File.lstat(Path.join(workspace, path)) do
      {:error, :enoent} ->
        {Map.merge(base, %{"type" => "deleted", "retained" => true}), size}

      {:ok, %{type: :symlink}} ->
        {:ok, target} = File.read_link(Path.join(workspace, path))
        {Map.merge(base, %{"type" => "symlink", "target" => target, "retained" => true}), size}

      {:ok, %{type: :regular, size: bytes}}
      when bytes <= 1_048_576 and size + bytes <= 4_194_304 ->
        case File.read(Path.join(workspace, path)) do
          {:ok, data} ->
            {Map.merge(base, %{
               "type" => "file",
               "retained" => true,
               "sha256" => Contract.sha256(data),
               "base64" => Base.encode64(data)
             }), size + bytes}

          _error ->
            {Map.merge(base, %{"retained" => false, "reason" => "unreadable"}), size}
        end

      _bounded ->
        {Map.merge(base, %{"retained" => false, "reason" => "size_or_type_limit"}), size}
    end
  end

  defp seal(value), do: Map.put(value, "sha256", Contract.digest(value))
end
