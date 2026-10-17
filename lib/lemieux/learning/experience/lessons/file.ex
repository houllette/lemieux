defmodule Lemieux.Learning.Experience.Lessons.File do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A process-free local lesson adapter, bound to an exact host scope.

  Records contain their evidence, so a single synced temporary file and atomic
  hard-link publication publish all bytes or none, without replacing another
  writer's record. Duplicate delivery verifies existing bytes. Temporary
  `.partial-*` files are never visible as lessons; the host may remove these
  after stopping all writers. Files are private (0600), new directories 0700.

  Pruning publishes a digested tombstone before removing the record. A crash
  in between cannot release the remaining content; repeating prune finishes
  cleanup. Tombstones retain scope, identity, supersession and source-case
  ancestry, but no lesson text or artifact bytes. They are never pruned here.

  The host owns this directory and its retention/backup policy. Symlinked
  ancestors and records are refused; filesystem access is not an isolation
  boundary against another process that can replace the host's directories.
  Reads are bounded to two MiB per record and `max_entries` history entries
  (default 1000). Reaching the history limit requires host archival or a
  larger explicit limit; it never discards audit history automatically.
  """

  @behaviour Lemieux.Learning.Experience.Lessons

  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Lesson

  @limit 2 * 1024 * 1024
  @id ~r/\Alesson_[a-f0-9]{64}\z/

  @doc "Builds a local adapter without reading, writing or starting anything."
  @spec new(dir :: Path.t(), scope :: map(), opts :: keyword()) ::
          Lemieux.Learning.Experience.Lessons.t()
  def new(dir, %{"id" => id} = scope, opts \\ [])
      when is_binary(dir) and is_binary(id) and id != "" do
    {__MODULE__,
     %{dir: Path.expand(dir), scope: scope, max_entries: Keyword.get(opts, :max_entries, 1000)}}
  end

  @impl true
  def append(state, %Lesson{} = lesson) do
    with :ok <- scoped(state, lesson.scope),
         :ok <- Lesson.verify(lesson),
         {:ok, path} <- path(state, lesson.id, ".json"),
         :ok <- not_pruned(state, lesson.id),
         :ok <- supersedes(state, lesson),
         :ok <- publish(state, path, Lesson.encode!(lesson)) do
      not_pruned(state, lesson.id)
    end
  end

  @impl true
  def read(state, id) do
    with {:ok, path} <- path(state, id, ".json"),
         :ok <- not_pruned(state, id),
         {:ok, bytes} <- read_bytes(path, @limit),
         {:ok, lesson} <- Lesson.decode(bytes),
         true <- lesson.id == id,
         :ok <- scoped(state, lesson.scope) do
      {:ok, lesson}
    else
      false -> {:error, :lesson_identity_mismatch}
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  end

  @impl true
  def history(state) do
    with :ok <- ancestors(state.dir),
         {:ok, files} <- list_files(state.dir),
         ids =
           files
           |> Enum.filter(&String.ends_with?(&1, ".json"))
           |> Enum.map(&record_id/1)
           |> Enum.uniq()
           |> Enum.sort(),
         true <- length(ids) <= state.max_entries do
      Enum.reduce_while(ids, {:ok, []}, &collect_summary(state, &1, &2))
    else
      false -> {:error, :lesson_history_limit}
      error -> error
    end
  end

  defp collect_summary(state, id, {:ok, summaries}) do
    case summary(state, id) do
      {:ok, summary} -> {:cont, {:ok, summaries ++ [summary]}}
      error -> {:halt, error}
    end
  end

  @impl true
  def prune(state, id, reason, %DateTime{} = at) do
    with true <-
           is_binary(reason) and String.valid?(reason) and String.trim(reason) != "" and
             byte_size(reason) <= 256,
         true <- at.utc_offset + at.std_offset == 0,
         {:ok, path} <- path(state, id, ".pruned.json"),
         {:ok, summary} <- summary(state, id),
         {:ok, tombstone} <- tombstone(summary, reason, at),
         :ok <- publish(state, path, Contract.encode!(tombstone)),
         {:ok, record} <- path(state, id, ".json"),
         :ok <- remove_record(record) do
      :ok
    else
      false -> {:error, :invalid_retention_reason}
      error -> error
    end
  end

  defp supersedes(state, lesson) do
    Enum.reduce_while(lesson.supersedes, :ok, fn id, :ok ->
      validate_supersession(summary(state, id), lesson, id)
    end)
  end

  defp validate_supersession({:ok, %{"key" => key, "created_at" => at}}, lesson, _id)
       when key == lesson.key do
    if DateTime.compare(parse_time!(at), parse_time!(lesson.created_at)) != :gt,
      do: {:cont, :ok},
      else: {:halt, {:error, :supersession_precedes_source}}
  end

  defp validate_supersession({:ok, _summary}, _lesson, _id),
    do: {:halt, {:error, :supersession_key_mismatch}}

  defp validate_supersession({:error, :not_found}, _lesson, id),
    do: {:halt, {:error, {:missing_superseded_lesson, id}}}

  defp validate_supersession(error, _lesson, _id), do: {:halt, error}

  defp summary(state, id) do
    case read_tombstone(state, id) do
      {:ok, tombstone} ->
        {:ok, Map.delete(tombstone, "sha256")}

      {:error, :enoent} ->
        with {:ok, lesson} <- read(state, id) do
          {:ok,
           %{
             "id" => lesson.id,
             "scope" => lesson.scope,
             "key" => lesson.key,
             "created_at" => lesson.created_at,
             "supersedes" => lesson.supersedes,
             "source_case_ids" => lesson.source_case_ids,
             "status" => "retained"
           }}
        end

      error ->
        error
    end
  end

  defp tombstone(%{"status" => "pruned"} = summary, reason, at) do
    if summary["reason"] == reason and summary["pruned_at"] == DateTime.to_iso8601(at),
      do: {:ok, Map.put(summary, "sha256", Contract.digest(summary))},
      else: {:error, :retention_conflict}
  end

  defp tombstone(summary, reason, at) do
    base =
      Map.merge(summary, %{
        "schema_version" => 1,
        "status" => "pruned",
        "reason" => reason,
        "pruned_at" => DateTime.to_iso8601(at)
      })

    if DateTime.compare(at, parse_time!(summary["created_at"])) != :lt,
      do: {:ok, Map.put(base, "sha256", Contract.digest(base))},
      else: {:error, :invalid_retention_time}
  end

  defp read_tombstone(state, id) do
    with {:ok, path} <- path(state, id, ".pruned.json"),
         {:ok, bytes} <- read_bytes(path, @limit),
         {:ok, map} <- Contract.decode(bytes),
         :ok <- Contract.verify_version(map, "schema_version", 1),
         :ok <- Contract.verify_digest(map, "sha256"),
         true <- map["id"] == id and map["status"] == "pruned",
         :ok <- scoped(state, map["scope"]),
         true <- is_list(map["supersedes"]) and Enum.all?(map["supersedes"], &valid_id?/1),
         true <- is_binary(map["key"]) and is_list(map["source_case_ids"]),
         {:ok, _, 0} <- parse_time(map["created_at"]),
         {:ok, _, 0} <- parse_time(map["pruned_at"]) do
      {:ok, map}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_lesson_tombstone}
    end
  end

  defp not_pruned(state, id) do
    case read_tombstone(state, id) do
      {:ok, _map} -> {:error, :pruned}
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp path(state, id, suffix) do
    with true <- valid_id?(id), :ok <- ancestors(state.dir) do
      {:ok, Path.join(state.dir, id <> suffix)}
    else
      false -> {:error, :invalid_lesson_id}
      error -> error
    end
  end

  defp read_bytes(path, limit) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path),
         true <- size <= limit do
      File.open(path, [:read, :binary], fn io -> IO.binread(io, limit + 1) end)
      |> case do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) <= limit -> {:ok, bytes}
        {:ok, :eof} -> {:ok, ""}
        {:ok, bytes} when is_binary(bytes) -> {:error, :lesson_too_large}
        {:ok, {:error, reason}} -> {:error, reason}
        error -> error
      end
    else
      {:ok, _stat} -> {:error, :unsafe_lesson_file}
      false -> {:error, :lesson_too_large}
      error -> error
    end
  end

  defp publish(state, path, bytes) do
    with :ok <- mkdir_private(state.dir) do
      temporary = Path.join(state.dir, ".partial-" <> Lemieux.ID.generate())

      try do
        with :ok <- write_synced(temporary, bytes) do
          link_or_compare(temporary, path, bytes)
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp write_synced(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive], &sync_bytes(&1, path, bytes)) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp sync_bytes(io, path, bytes) do
    with :ok <- File.chmod(path, 0o600), :ok <- IO.binwrite(io, bytes), do: :file.sync(io)
  end

  defp link_or_compare(temporary, path, bytes) do
    case File.ln(temporary, path) do
      :ok ->
        :ok

      {:error, :eexist} ->
        compare_bytes(read_bytes(path, @limit), bytes)

      error ->
        error
    end
  end

  defp compare_bytes({:ok, bytes}, bytes), do: :ok
  defp compare_bytes({:ok, _other}, _bytes), do: {:error, :lesson_content_conflict}
  defp compare_bytes(error, _bytes), do: error

  defp mkdir_private(dir) do
    case File.mkdir(dir) do
      :ok -> File.chmod(dir, 0o700)
      {:error, :eexist} -> directory(dir)
      {:error, :enoent} -> with :ok <- mkdir_private(Path.dirname(dir)), do: mkdir_private(dir)
      error -> error
    end
  end

  defp directory(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _stat} -> {:error, :unsafe_lesson_directory}
      error -> error
    end
  end

  defp ancestors(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> parent(path)
      {:ok, _stat} -> {:error, :unsafe_lesson_directory}
      {:error, :enoent} -> parent(path)
      error -> error
    end
  end

  defp parent(path) do
    if Path.dirname(path) == path, do: :ok, else: ancestors(Path.dirname(path))
  end

  defp list_files(dir) do
    case File.ls(dir) do
      {:error, :enoent} -> {:ok, []}
      result -> result
    end
  end

  defp remove_record(path) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp scoped(%{scope: scope}, scope), do: :ok
  defp scoped(_state, _scope), do: {:error, :lesson_scope_mismatch}
  defp valid_id?(id), do: is_binary(id) and Regex.match?(@id, id)

  defp record_id(name),
    do: name |> String.replace_suffix(".pruned.json", "") |> String.replace_suffix(".json", "")

  defp parse_time!(value), do: value |> DateTime.from_iso8601() |> elem(1)
  defp parse_time(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_time(_value), do: {:error, :invalid_lesson_timestamp}
end
