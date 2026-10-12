defmodule Lemieux.Jobs.Journal.Files do
  @moduledoc """
  Private filesystem job records with CAS, atomic replacement and file sync.

  Each effect is its own record. Pages bound values loaded into memory; the
  directory listing itself is local-filesystem work. Large installations
  should choose an indexed `Lemieux.Jobs.Journal` adapter. This store uses
  the transcript store's proven local-owner locks, including stale takeover
  and token-checked release. It refuses foreign hosts and symlink records.
  Atomic replacement covers process/VM interruption. Power-loss guarantees
  depend on the filesystem preserving synced files and directory entries.
  """
  @behaviour Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal
  alias Lemieux.Store.JSONL
  @max_bytes 8_388_608

  @doc "Selects a private directory; creates no process."
  @spec new(directory :: Path.t()) :: Journal.t()
  def new(directory), do: {__MODULE__, %{dir: Path.expand(directory)}}

  @impl true
  def read(state, key) do
    with {:ok, path} <- path(state, key),
         {:ok, %{type: :regular, size: size}} when size <= @max_bytes <- File.lstat(path),
         {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "revision" => revision, "value" => value}}
         when is_integer(revision) and revision > 0 and is_map(value) <- JSON.decode(contents) do
      {:ok, %{key: key, revision: revision, value: value}}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :unreadable_record}
    end
  end

  @impl true
  def write(state, key, revision, value) do
    with :ok <- directory(state),
         {:ok, path} <- path(state, key),
         {:ok, lock} <- lock(state, "write-" <> key) do
      try do
        current =
          case read(state, key) do
            {:ok, record} -> {:ok, record.revision}
            {:error, :not_found} -> {:ok, 0}
            error -> error
          end

        with {:ok, ^revision} <- current,
             bytes = JSON.encode!(%{"version" => 1, "revision" => revision + 1, "value" => value}),
             true <- byte_size(bytes) <= @max_bytes,
             :ok <- replace(path, bytes) do
          {:ok, %{key: key, revision: revision + 1, value: value}}
        else
          {:ok, _revision} -> {:error, :conflict}
          false -> {:error, :record_too_large}
          error -> error
        end
      after
        unlock(state, "write-" <> key, lock)
      end
    end
  end

  @impl true
  def scan(state, prefix, cursor, limit) when is_integer(limit) and limit in 1..1000 do
    with :ok <- directory(state), {:ok, names} <- File.ls(state.dir) do
      names
      |> Enum.filter(&(String.starts_with?(&1, prefix) and String.ends_with?(&1, ".json")))
      |> Enum.map(&String.trim_trailing(&1, ".json"))
      |> Enum.filter(&(is_nil(cursor) or &1 > cursor))
      |> Enum.sort()
      |> Enum.take(limit)
      |> Enum.reduce_while({:ok, []}, &scan_record(state, &1, &2))
      |> case do
        {:ok, records} -> {:ok, Enum.reverse(records)}
        error -> error
      end
    end
  end

  defp scan_record(state, key, {:ok, records}) do
    case read(state, key) do
      {:ok, record} -> {:cont, {:ok, [record | records]}}
      error -> {:halt, error}
    end
  end

  @impl true
  def lock(state, key) do
    with :ok <- directory(state), {:ok, _path} <- path(state, key), do: JSONL.lock(state, key)
  end

  @impl true
  def unlock(state, key, lock), do: JSONL.unlock(state, key, lock)

  defp directory(%{dir: dir}) do
    with :ok <- File.mkdir_p(dir),
         {:ok, %{type: :directory}} <- File.lstat(dir) do
      File.chmod(dir, 0o700)
    else
      {:ok, _not_a_directory} -> {:error, :invalid_directory}
      error -> error
    end
  end

  defp path(%{dir: dir}, key) do
    if is_binary(key) and key =~ ~r/\A[a-zA-Z0-9_-]{1,200}\z/,
      do: {:ok, Path.join(dir, key <> ".json")},
      else: {:error, :invalid_key}
  end

  defp replace(path, bytes) do
    temporary = path <> "." <> Lemieux.ID.generate() <> ".tmp"

    with {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(temporary, 0o600),
             :ok <- IO.binwrite(file, bytes),
             :ok <- :file.sync(file),
             do: File.rename(temporary, path)
      after
        File.close(file)
        File.rm(temporary)
      end
    end
  end
end
