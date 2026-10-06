defmodule Lmx.Update.Archive do
  @moduledoc """
  Validates release archives before extracting into a fresh directory.

  Modes are judged for the installation the updater makes on Unix, where a
  file writable by others is one anybody on the machine could change. The
  Windows archive has no such installation: Windows files have no Unix
  modes, Erlang reports every writable one as 0666 and every directory as
  0777, and `Lmx.Release` leaves them so because neither `install.py` nor the
  updater installs that archive. The release gate still unpacks it to inspect
  the previous release (`Lmx.UpgradePlan.unpack!/3`), and judging it by the
  Unix rule stopped the first release with a predecessor, 0.8.1, on its
  Windows job (2026-10-06). `writable_by_others: true` admits those modes
  there, while every other rule — paths, links, duplicates, sizes, setuid and
  setgid — holds.
  """
  import Bitwise

  @doc """
  Rejects escaping paths, links, duplicate entries and oversized payloads,
  and modes that set setuid or setgid; a mode writable by others too, unless
  `writable_by_others: true` (the Windows archive; see the module
  documentation).
  """
  @spec validate(path :: Path.t(), opts :: [writable_by_others: boolean()]) ::
          :ok | {:error, term()}
  def validate(path, opts \\ []) do
    forbidden = if Keyword.get(opts, :writable_by_others, false), do: 0o6000, else: 0o6002

    with {:ok, rows} <- :erl_tar.table(to_charlist(path), [:compressed, :verbose]),
         true <- length(rows) <= 20_000,
         true <- Enum.all?(rows, &safe_entry?(&1, forbidden)),
         true <- unique_paths?(rows),
         true <- Enum.reduce(rows, 0, &(&2 + elem(&1, 2))) <= 1_000_000_000 do
      :ok
    else
      _ -> {:error, :unsafe_archive}
    end
  end

  defp safe_entry?({name, type, size, _, mode, _, _}, forbidden) do
    name = name |> to_string() |> String.trim_trailing("/")

    type in [:regular, :directory] and size in 0..200_000_000 and (mode &&& forbidden) == 0 and
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
