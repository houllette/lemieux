defmodule Lemieux.Learning.Experience.Materializer do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Deterministically materializes an authorized experience bundle.

  The caller supplies all bytes and the destination. Lemieux validates scope,
  exposure, paths, sizes, and digests before creating a staging directory,
  writes history read-only, leaves only `proposal/` writable, and atomically
  renames a completed staging tree into place. It never fetches an artifact or
  connects to a host service.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Experience.Bundle

  @default_artifact_limit 10 * 1024 * 1024
  @default_total_limit 100 * 1024 * 1024

  @doc "Materializes a verified bundle from an id-or-digest keyed byte map."
  @spec materialize(bundle :: Bundle.t(), artifacts :: map(), destination :: Path.t(), keyword()) ::
          {:ok, Path.t()} | {:error, term()}
  def materialize(%Bundle{} = bundle, artifacts, destination, opts \\ [])
      when is_map(artifacts) and is_binary(destination) and is_list(opts) do
    destination = Path.expand(destination)

    with :ok <- Bundle.verify(bundle),
         :ok <- destination_available(destination),
         :ok <- no_symlink_components(destination),
         {:ok, writes} <- validate_writes(bundle, artifacts, opts),
         :ok <- unique_paths(writes) do
      write_atomic(bundle, writes, destination)
    end
  end

  @doc "Returns true only for the explicit writable proposal subtree."
  @spec writable_path?(materialized_root :: Path.t(), path :: Path.t()) :: boolean()
  def writable_path?(materialized_root, path)
      when is_binary(materialized_root) and is_binary(path) do
    root = Path.expand(materialized_root)
    proposal = Path.join(root, "proposal")
    expanded = Path.expand(path)
    expanded == proposal or String.starts_with?(expanded, proposal <> "/")
  end

  defp validate_writes(bundle, artifacts, opts) do
    artifact_limit = Keyword.get(opts, :max_artifact_bytes, @default_artifact_limit)
    total_limit = Keyword.get(opts, :max_total_bytes, @default_total_limit)

    with {:ok, artifact_writes} <- artifact_writes(bundle.artifacts, artifacts, artifact_limit),
         writes = manifest_writes(bundle) ++ artifact_writes,
         true <-
           Enum.sum(Enum.map(writes, fn {_path, bytes} -> byte_size(bytes) end)) <= total_limit do
      {:ok, writes}
    else
      false -> {:error, :bundle_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp artifact_writes(descriptors, artifacts, artifact_limit) do
    Enum.reduce_while(descriptors, {:ok, []}, fn descriptor, {:ok, writes} ->
      with :ok <- safe_relative_path(descriptor["path"]),
           {:ok, reference} <- ArtifactReference.from_map(descriptor["reference"]),
           {:ok, bytes} <- artifact_bytes(artifacts, reference),
           true <- byte_size(bytes) <= artifact_limit,
           :ok <- ArtifactReference.verify_bytes(reference, bytes) do
        {:cont, {:ok, [{descriptor["path"], bytes} | writes]}}
      else
        false -> {:halt, {:error, {:artifact_too_large, descriptor["path"]}}}
        {:error, reason} -> {:halt, {:error, {:invalid_artifact, descriptor["path"], reason}}}
      end
    end)
    |> case do
      {:ok, writes} -> {:ok, Enum.reverse(writes)}
      error -> error
    end
  end

  defp artifact_bytes(artifacts, reference) do
    case Map.get(artifacts, reference.id, Map.get(artifacts, reference.sha256)) do
      bytes when is_binary(bytes) -> {:ok, bytes}
      nil -> {:error, {:missing_artifact_bytes, reference.id}}
      _invalid -> {:error, {:invalid_artifact_bytes, reference.id}}
    end
  end

  defp manifest_writes(bundle) do
    base = [
      {"bundle.json", Bundle.encode!(bundle)},
      {"plan.json", Contract.encode!(bundle.plan)}
    ]

    base ++
      item_writes("seeds", "seed", bundle.seeds) ++
      item_writes("candidates", "candidate", bundle.candidates) ++
      evaluation_writes(bundle.evaluations) ++
      flat_writes("raw", bundle.raw) ++
      derived_writes(bundle.derived) ++
      [
        {"frontier.json", Contract.encode!(bundle.frontier)},
        {"exposures.json", Contract.encode!(%{"exposures" => bundle.exposures})}
      ]
  end

  defp item_writes(directory, filename, items) do
    Enum.map(items, fn item ->
      {Path.join([directory, item["id"], filename <> ".json"]), Contract.encode!(item)}
    end)
  end

  defp evaluation_writes(evaluations) do
    Enum.map(evaluations, fn item ->
      candidate_id = item["candidate_id"] || "unassigned"

      {Path.join(["candidates", candidate_id, "evaluations", item["id"] <> ".json"]),
       Contract.encode!(item)}
    end)
  end

  defp flat_writes(directory, items) do
    Enum.map(items, fn item ->
      {Path.join([directory, item["id"] <> ".json"]), Contract.encode!(item)}
    end)
  end

  defp derived_writes(items) do
    Enum.map(items, fn item ->
      source = Map.get(item, "source", "other")
      {Path.join(["derived", source, item["id"] <> ".json"]), Contract.encode!(item)}
    end)
  end

  defp unique_paths(writes) do
    paths = Enum.map(writes, &elem(&1, 0))

    with true <- length(paths) == MapSet.size(MapSet.new(paths)),
         nil <- Enum.find(paths, &(safe_relative_path(&1) != :ok)),
         false <- Enum.any?(paths, &reserved_proposal?/1) do
      :ok
    else
      false -> {:error, :duplicate_or_reserved_path}
      path when is_binary(path) -> {:error, {:unsafe_path, path}}
      true -> {:error, :duplicate_or_reserved_path}
    end
  end

  defp reserved_proposal?(path), do: path == "proposal" or String.starts_with?(path, "proposal/")

  defp safe_relative_path(path) when is_binary(path) do
    components = Path.split(path)

    cond do
      Path.type(path) != :relative -> {:error, :absolute_path}
      components == [] -> {:error, :empty_path}
      Enum.any?(components, &(&1 in [".", "..", ""])) -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp safe_relative_path(_path), do: {:error, :invalid_path}

  defp destination_available(destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :destination_exists}
      {:error, reason} -> {:error, {:destination_unavailable, reason}}
    end
  end

  defp no_symlink_components(destination) do
    destination
    |> Path.dirname()
    |> existing_ancestors()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, {:symlink_component, path}}}
        {:ok, _stat} -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:path_unavailable, path, reason}}}
      end
    end)
  end

  defp existing_ancestors(path) do
    path
    |> Path.split()
    |> Enum.reduce({[], ""}, fn part, {paths, current} ->
      next = if current == "", do: part, else: Path.join(current, part)
      {[next | paths], next}
    end)
    |> elem(0)
  end

  defp write_atomic(bundle, writes, destination) do
    parent = Path.dirname(destination)
    staging = destination <> ".partial-" <> Lemieux.ID.generate()

    with :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(staging),
         :ok <- write_all(staging, writes),
         :ok <- File.mkdir(Path.join(staging, "proposal")),
         :ok <- File.write(Path.join(staging, ".complete"), bundle.sha256),
         :ok <- protect_history(staging),
         :ok <- File.rename(staging, destination) do
      # Darwin needs write permission on the moved directory to update its
      # parent. Seal descendants before publication and the root immediately
      # after rename, before returning it for use by a proposer.
      case File.chmod(destination, 0o555) do
        :ok -> {:ok, destination}
        {:error, reason} -> {:error, {:chmod_failed, destination, reason}}
      end
    else
      {:error, reason} ->
        File.rm_rf(staging)
        {:error, reason}
    end
  end

  defp write_all(staging, writes) do
    Enum.reduce_while(writes, :ok, fn {relative, bytes}, :ok ->
      target = Path.join(staging, relative)

      with :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.write(target, bytes) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:write_failed, relative, reason}}}
      end
    end)
  end

  defp protect_history(staging) do
    paths =
      staging
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.sort_by(&(-length(Path.split(&1))))

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      mode = mode(path, staging)

      case File.chmod(path, mode) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:chmod_failed, path, reason}}}
      end
    end)
  end

  defp mode(path, staging) do
    relative = Path.relative_to(path, staging)

    cond do
      relative == "proposal" or String.starts_with?(relative, "proposal/") -> 0o755
      File.dir?(path) -> 0o555
      true -> 0o444
    end
  end
end
