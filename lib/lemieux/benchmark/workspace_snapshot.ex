defmodule Lemieux.Benchmark.WorkspaceSnapshot do
  @moduledoc false

  @ignored MapSet.new([".git", ".elixir_ls", "_build", "deps"])

  @type t :: %{optional(String.t()) => binary()}

  @spec capture(root :: Path.t()) :: {:ok, t()} | {:error, term()}
  def capture(root) when is_binary(root), do: walk(root, "", %{})

  @spec changed(before :: t(), after_snapshot :: t()) :: [String.t()]
  def changed(before, after_snapshot) when is_map(before) and is_map(after_snapshot) do
    before
    |> Map.keys()
    |> Kernel.++(Map.keys(after_snapshot))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(before, &1) != Map.get(after_snapshot, &1)))
    |> Enum.sort()
  end

  defp walk(root, relative, snapshot) do
    directory = if relative == "", do: root, else: Path.join(root, relative)

    case File.ls(directory) do
      {:ok, names} -> walk_names(names, root, relative, snapshot)
      {:error, reason} -> {:error, {:snapshot_list, relative, reason}}
    end
  end

  defp walk_names(names, root, relative, snapshot) do
    names
    |> Enum.sort()
    |> Enum.reject(&ignored?(relative, &1))
    |> Enum.reduce_while({:ok, snapshot}, fn name, {:ok, snapshot} ->
      path = if relative == "", do: name, else: Path.join(relative, name)
      step(visit(root, path, snapshot))
    end)
  end

  defp visit(root, path, snapshot) do
    full = Path.join(root, path)

    case File.lstat(full) do
      {:ok, stat} -> visit_type(stat.type, root, path, full, snapshot)
      {:error, reason} -> {:error, {:snapshot_stat, path, reason}}
    end
  end

  defp visit_type(:directory, root, path, _full, snapshot), do: walk(root, path, snapshot)

  defp visit_type(:regular, _root, path, full, snapshot) do
    case File.read(full) do
      {:ok, contents} -> {:ok, Map.put(snapshot, path, digest("file", contents))}
      {:error, reason} -> {:error, {:snapshot_read, path, reason}}
    end
  end

  defp visit_type(:symlink, _root, path, full, snapshot) do
    case File.read_link(full) do
      {:ok, target} -> {:ok, Map.put(snapshot, path, digest("link", target))}
      {:error, reason} -> {:error, {:snapshot_link, path, reason}}
    end
  end

  defp visit_type(type, _root, path, _full, snapshot),
    do: {:ok, Map.put(snapshot, path, digest("other", inspect(type)))}

  defp step({:ok, snapshot}), do: {:cont, {:ok, snapshot}}
  defp step({:error, reason}), do: {:halt, {:error, reason}}

  defp ignored?("", name), do: MapSet.member?(@ignored, name)
  defp ignored?(_relative, _name), do: false

  defp digest(type, contents),
    do: :crypto.hash(:sha256, [type, 0, contents])
end
