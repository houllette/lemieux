defmodule Lemieux.Checkpoint.Store do
  @moduledoc """
  The on-disk layout behind `Lemieux.Checkpoint`.

      <dir>/<session id>/
        current                           the turn captures belong to now
        left_alone.json                   what the last undo or redo left alone
        blobs/<sha256>                    file contents, stored once each
        turns/<n>/captures/<id>.json      one saved pre-image
        turns/<n>/after/<key>.json        what the tool left the file as
        turns/<n>/commands/<key>.json     git trees before and after one command
        turns/<n>/unrecorded/<id>.json    something the turn did that nothing recorded
        turns/<n>/snapshot.json           git trees around all the turn's commands
                                          (written before per-command windows; still read)
        turns/<n>/undone.json             the report of undoing it, and what it replaced
        turns/<n>/redone/<id>.json        an undo since put back with redo
        git/<random>/                     a private git directory while a snapshot or
                                          an undo runs, removed when it ends
                                          (`Lemieux.Checkpoint.Git`)

  One file per capture, per command and per note rather than a manifest per
  turn, because they are written from tool tasks and a manifest would be
  read, changed and written back by each of them: the obvious design for a
  record, and a lost update the moment two calls or two sessions share a
  directory or a write is interrupted. `left_alone.json` is the one file
  that is rewritten, and only by undo, redo and the start of a turn, which a
  host runs one at a time. Every file here is written to a temporary name
  and renamed into place, so a crash leaves the old version or the new one,
  never half of either.

  The directory is private (`0700`, files `0600`): pre-images are the user's
  own file contents, `.env` files included. Nothing here is deleted on its
  own — `Lemieux.Checkpoint.forget/2` removes a session's — so the old
  contents of every file the agent changed, what each undo replaced and what
  a forced redo overwrote stay on disk until somebody deletes them, as
  transcripts do.

  ## File names in records

  A file name is bytes, not text: Linux allows any byte but `/` and NUL, and
  `git ls-files` prints a name exactly as it is stored. JSON holds only
  UTF-8, and `JSON.encode!/1` raises on anything else — inside the wrapper
  every `bash` call runs, where one Latin-1 name from an unpacked archive
  failed every command in that repository. So `put_json/2` writes a string
  that is not valid UTF-8 as a NUL, `b64:` and its Base64 (a NUL cannot
  begin a real name), and `json/1` turns it back into the same bytes.
  """

  @id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @raw "\0b64:"

  @doc "The session's directory, or an error for an id that is not a safe name."
  @spec session_dir(dir :: Path.t(), session_id :: String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def session_dir(dir, session_id) when is_binary(dir) and is_binary(session_id) do
    if Regex.match?(@id, session_id),
      do: {:ok, Path.join(Path.expand(dir), session_id)},
      else: {:error, {:invalid_session_id, session_id}}
  end

  def session_dir(_dir, session_id), do: {:error, {:invalid_session_id, session_id}}

  @doc """
  Where git runs for this session make their private git directories: in
  the store, out of a sandboxed command's reach, rather than in a temporary
  directory it may write (see `Lemieux.Checkpoint.Git`).
  """
  @spec scratch(session_dir :: Path.t()) :: Path.t()
  def scratch(session_dir), do: Path.join(session_dir, "git")

  @doc "The turn directory for `turn`."
  @spec turn_dir(session_dir :: Path.t(), turn :: pos_integer()) :: Path.t()
  def turn_dir(session_dir, turn), do: Path.join([session_dir, "turns", Integer.to_string(turn)])

  @doc "Turn numbers that have a directory, ascending."
  @spec turns(session_dir :: Path.t()) :: [pos_integer()]
  def turns(session_dir) do
    case File.ls(Path.join(session_dir, "turns")) do
      {:ok, names} -> names |> Enum.flat_map(&turn_number/1) |> Enum.sort()
      {:error, _reason} -> []
    end
  end

  defp turn_number(name) do
    case Integer.parse(name) do
      {turn, ""} when turn > 0 -> [turn]
      _other -> []
    end
  end

  @doc "Reads the current turn, `0` when none has begun."
  @spec current(session_dir :: Path.t()) :: non_neg_integer()
  def current(session_dir) do
    with {:ok, text} <- File.read(Path.join(session_dir, "current")),
         {turn, _rest} when turn >= 0 <- Integer.parse(String.trim(text)) do
      turn
    else
      _missing_or_garbled -> 0
    end
  end

  @doc "Records `turn` as current."
  @spec put_current(session_dir :: Path.t(), turn :: pos_integer()) :: :ok | {:error, term()}
  def put_current(session_dir, turn), do: write(Path.join(session_dir, "current"), "#{turn}\n")

  @doc "Stores `contents` under its digest, once, returning the digest."
  @spec put_blob(session_dir :: Path.t(), contents :: binary()) ::
          {:ok, String.t()} | {:error, term()}
  def put_blob(session_dir, contents) do
    digest = digest(contents)
    path = blob_path(session_dir, digest)

    if File.regular?(path) do
      {:ok, digest}
    else
      with :ok <- write(path, contents), do: {:ok, digest}
    end
  end

  @doc "Reads a stored blob."
  @spec blob(session_dir :: Path.t(), digest :: String.t()) :: {:ok, binary()} | {:error, term()}
  def blob(session_dir, digest), do: File.read(blob_path(session_dir, digest))

  @doc "The hex SHA-256 of `contents`, which names its blob."
  @spec digest(contents :: binary()) :: String.t()
  def digest(contents), do: :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)

  @doc """
  Writes `term` as JSON to `path`, atomically, creating private directories.
  A string that is not UTF-8 is kept as its bytes (see "File names in
  records" in the moduledoc).
  """
  @spec put_json(path :: Path.t(), term :: term()) :: :ok | {:error, term()}
  def put_json(path, term), do: write(path, JSON.encode!(escape(term)))

  @doc "Reads a JSON file written by `put_json/2`, with every string as it was given."
  @spec json(path :: Path.t()) :: {:ok, term()} | {:error, term()}
  def json(path) do
    with {:ok, text} <- File.read(path),
         {:ok, term} <- JSON.decode(text),
         do: {:ok, unescape(term)}
  end

  # A string that starts with the marker is escaped too, so reading it back
  # can never mistake it for one that was escaped.
  defp escape(string) when is_binary(string) do
    if String.valid?(string) and not String.starts_with?(string, "\0"),
      do: string,
      else: @raw <> Base.encode64(string)
  end

  defp escape(list) when is_list(list), do: Enum.map(list, &escape/1)

  defp escape(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {escape(key), escape(value)} end)

  defp escape(other), do: other

  defp unescape(@raw <> encoded = string) do
    case Base.decode64(encoded) do
      {:ok, bytes} -> bytes
      :error -> string
    end
  end

  defp unescape(list) when is_list(list), do: Enum.map(list, &unescape/1)

  defp unescape(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {unescape(key), unescape(value)} end)

  defp unescape(other), do: other

  @doc "Whether `directory` holds any JSON file, without reading one."
  @spec any_json?(directory :: Path.t()) :: boolean()
  def any_json?(directory) do
    case File.ls(directory) do
      {:ok, names} -> Enum.any?(names, &String.ends_with?(&1, ".json"))
      {:error, _reason} -> false
    end
  end

  @doc """
  A fresh record name that sorts in the order records were made: `seq/0`,
  then a counter, so two names never collide.
  """
  @spec id() :: String.t()
  def id do
    unique =
      [:positive, :monotonic]
      |> System.unique_integer()
      |> Integer.to_string()
      |> String.pad_leading(12, "0")

    (seq() |> Integer.to_string() |> String.pad_leading(20, "0")) <> "-" <> unique
  end

  @doc """
  A number that orders records: larger is later — within one VM whatever the
  wall clock does, and across restarts as long as the clock does not go back
  between them.

  The wall clock in microseconds, raised when needed to one past the last
  number this VM gave out. A counter alone starts again with every VM, and a
  turn can hold records from two: a `/retry` after a restart adds to the turn
  the stopped process began, where the new VM's small numbers sorted first
  and made the wrong record a path's pre-image. The wall clock alone can step
  back while a VM runs, which would put a later record first.
  """
  @spec seq() :: pos_integer()
  def seq, do: advance(counter(), System.os_time(:microsecond))

  defp advance(counter, now) do
    last = :atomics.get(counter, 1)
    next = max(now, last + 1)

    case :atomics.compare_exchange(counter, 1, last, next) do
      :ok -> next
      _another_process_took_it -> advance(counter, System.os_time(:microsecond))
    end
  end

  defp counter, do: once(:seq, fn -> :atomics.new(1, signed: true) end)

  @doc """
  This VM's name in records: its OS process id and a random part, made once
  per VM. Undo waits only for this VM's watchers, and an after-snapshot
  closes only this VM's windows. The process id alone repeats — in a
  container a program is often process 1 on every run — and a window a
  crashed run left open then looked like this VM's own: undo waited for a
  watcher that no longer existed, and a new command could close the dead
  run's window.
  """
  @spec vm() :: String.t()
  def vm do
    once(:vm, fn ->
      System.pid() <> "-" <> (6 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
    end)
  end

  # Made on first use, once per VM even when two tool calls ask at the same
  # moment — the first wave of a session can run two commands at once, and
  # two counters or two names would each be half right. A lock around the
  # making; `:persistent_term` for every read after it.
  defp once(name, make) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil -> :global.trans({key, self()}, fn -> made(key, make) end, [node()])
      value -> value
    end
  end

  defp made(key, make) do
    case :persistent_term.get(key, nil) do
      nil ->
        value = make.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  @doc """
  The name a per-call record is kept under: one for each call, working
  directory and path, short enough for any file system.
  """
  @spec key(call_id :: String.t() | nil, cwd :: Path.t(), path :: String.t()) :: String.t()
  def key(call_id, cwd, path),
    do: "#{call_id}\0#{cwd}\0#{path}" |> digest() |> binary_part(0, 32)

  @doc """
  Whether records can be written at `path`: it, or the nearest directory
  above it that exists, accepts writes from this user.
  """
  @spec writable?(path :: Path.t()) :: boolean()
  def writable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{access: access}} ->
        access in [:read_write, :write]

      {:error, :enoent} ->
        parent = Path.dirname(path)
        parent != path and writable?(parent)

      {:error, _reason} ->
        false
    end
  end

  @doc "Every JSON file in `directory`, decoded, in file-name order; unreadable ones skipped."
  @spec all_json(directory :: Path.t()) :: [map()]
  def all_json(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.flat_map(&record(Path.join(directory, &1)))

      {:error, _reason} ->
        []
    end
  end

  defp record(path) do
    case json(path) do
      {:ok, %{} = record} -> [record]
      _unreadable -> []
    end
  end

  defp blob_path(session_dir, digest), do: Path.join([session_dir, "blobs", digest])

  defp write(path, contents) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- private_dirs(directory),
         :ok <- File.write(temporary, contents, [:exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, _reason} = error ->
        File.rm(temporary)
        error
    end
  end

  defp private_dirs(directory) do
    with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)
  end
end
