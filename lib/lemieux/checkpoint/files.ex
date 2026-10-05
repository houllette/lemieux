defmodule Lemieux.Checkpoint.Files do
  @moduledoc false

  # What a file is, as the checkpoint records and compares it: read through
  # the session's environment, as the tools that changed it read it.
  #
  # Read as a stream. Reading the whole file first and checking its size after
  # held a multi-gigabyte file in memory twice for every undo that touched it,
  # only to learn it was too large to keep; and a file over the size limit was
  # recorded without a digest that could be compared, so an agent's 20 MB
  # write could never be told apart from somebody else's change to it.

  alias Lemieux.Checkpoint.Store
  alias Lemieux.Environment

  @default_max_file_bytes 10_000_000

  @typedoc "A file's recorded state: its digest and size, that it was absent, or why it could not be saved."
  @type state :: %{required(String.t()) => term()}

  @doc """
  The state of `path` (relative to `cwd`) now. With `keep?`, the contents are
  stored as a blob so they can be put back later, and a file over
  `:max_file_bytes` (default 10 MB) is recorded as unavailable without being
  read to the end. Without `keep?`, only the digest is taken, at any size.
  """
  @spec observe(
          session :: Path.t(),
          environment :: Environment.t(),
          cwd :: Path.t(),
          path :: String.t(),
          opts :: keyword(),
          keep? :: boolean()
        ) :: state()
  def observe(session, environment, cwd, path, opts, keep?) do
    max = Keyword.get(opts, :max_file_bytes, @default_max_file_bytes)

    case Environment.stream_file(environment, cwd, path) do
      {:ok, chunks} -> read(chunks, session, if(keep?, do: max), keep?)
      {:error, :enoent} -> %{"state" => "absent"}
      {:error, reason} -> unreadable(reason)
    end
  end

  # A stream that fails part-way — the file was truncated, a disk error —
  # raises; recording must answer rather than take the tool call down with it.
  defp read(chunks, session, max, keep?) do
    chunks
    |> Enum.reduce_while({:crypto.hash_init(:sha256), 0, []}, &take(&1, &2, max, keep?))
    |> stored(session, max, keep?)
  rescue
    error in [File.Error, ErlangError] -> unreadable(Exception.message(error))
  end

  defp take(chunk, {hash, size, kept}, max, keep?) do
    size = size + byte_size(chunk)

    cond do
      is_integer(max) and size > max -> {:halt, :too_large}
      keep? -> {:cont, {:crypto.hash_update(hash, chunk), size, [chunk | kept]}}
      true -> {:cont, {:crypto.hash_update(hash, chunk), size, kept}}
    end
  end

  defp stored(:too_large, _session, max, _keep?),
    do: %{
      "state" => "unavailable",
      "reason" => "larger than #{max} bytes, so its contents were not saved"
    }

  defp stored({_hash, size, kept}, session, _max, true) do
    contents = kept |> Enum.reverse() |> IO.iodata_to_binary()

    case Store.put_blob(session, contents) do
      {:ok, digest} -> %{"state" => "file", "sha256" => digest, "bytes" => size}
      {:error, reason} -> %{"state" => "unavailable", "reason" => "not saved: #{inspect(reason)}"}
    end
  end

  defp stored({hash, size, _kept}, _session, _max, false) do
    digest = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    %{"state" => "file", "sha256" => digest, "bytes" => size}
  end

  defp unreadable(reason) when is_binary(reason),
    do: %{"state" => "unavailable", "reason" => "could not be read: #{reason}"}

  defp unreadable(reason), do: unreadable(inspect(reason))

  @doc "Whether two recorded states describe the same file, or both its absence."
  @spec same?(current :: state() | nil, other :: state() | nil) :: boolean()
  def same?(%{"state" => "absent"}, %{"state" => "absent"}), do: true

  def same?(%{"state" => "file", "sha256" => digest}, %{"state" => "file", "sha256" => digest}),
    do: true

  def same?(_current, _other), do: false

  @doc """
  What an unsaved file looks like from outside — size, modification time and
  inode, `nil` when it is not there — which is all a snapshot keeps of one.
  """
  @spec fingerprint(path :: Path.t()) :: [integer()] | nil
  def fingerprint(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: type} = stat} when type in [:regular, :symlink] ->
        [stat.size, stat.mtime, stat.inode]

      _absent ->
        nil
    end
  end
end
