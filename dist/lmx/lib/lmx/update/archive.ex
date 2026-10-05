defmodule Lmx.Update.Archive do
  @moduledoc "Validates release archives before extracting into a fresh directory."
  import Bitwise

  @doc "Rejects escaping paths, links, duplicate entries and oversized payloads."
  @spec validate(path :: Path.t()) :: :ok | {:error, term()}
  def validate(path) do
    with {:ok, rows} <- :erl_tar.table(to_charlist(path), [:compressed, :verbose]),
         true <- length(rows) <= 20_000,
         true <- Enum.all?(rows, &safe_entry?/1),
         true <- unique_paths?(rows),
         true <- Enum.reduce(rows, 0, &(&2 + elem(&1, 2))) <= 1_000_000_000 do
      :ok
    else
      _ -> {:error, :unsafe_archive}
    end
  end

  defp safe_entry?({name, type, size, _, mode, _, _}) do
    name = name |> to_string() |> String.trim_trailing("/")

    type in [:regular, :directory] and size in 0..200_000_000 and (mode &&& 0o6002) == 0 and
      Path.type(name) == :relative and not String.contains?(name, ["\\", ":", <<0>>]) and
      Enum.all?(String.split(name, "/"), &(&1 not in ["", "..", "."]))
  end

  defp unique_paths?(rows) do
    paths =
      Map.new(rows, fn row ->
        {row |> elem(0) |> to_string() |> String.trim_trailing("/"), elem(row, 1)}
      end)

    map_size(paths) == length(rows) and
      Enum.all?(paths, fn {path, _type} -> directory_parents?(Path.dirname(path), paths) end)
  end

  defp directory_parents?(".", _paths), do: true

  defp directory_parents?(path, paths),
    do:
      Map.get(paths, path, :directory) == :directory and
        directory_parents?(Path.dirname(path), paths)
end
