defmodule Lemieux.Learning.Experience.Lessons do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Host-owned lesson persistence and exposure-gated recall.

  Adapters implement atomic, idempotent append and durable pruning. They bind
  a store to one complete tenant/project scope. `read/2` and `history/1` are
  host inspection APIs; improvers receive content only through `recall/5`,
  which calls the host's exposure committer before returning any lesson.
  The committer must durably record the supplied `Corpus.Exposure` in the
  named scope, including its complete source-case closure, and return `:ok`.
  An error or exception releases no content. Exposure may conservatively
  remain recorded if the caller dies after commit; it is never rolled back.

  Supersession is explicit, within the same logical key. All historical
  supersession edges, including tombstones, suppress old versions. Concurrent
  siblings remain auditable and recall refuses their ambiguous key until a
  new lesson explicitly supersedes both. Neither recency nor a supported
  outcome is an activation or a tie-breaker.

  No process, scheduler, model request or runtime activation starts here.
  Retention is an explicit host operation; adapters must retain tombstones
  so pruning cannot resurrect obsolete advice or erase exposure ancestry.
  """

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Lesson

  @type t :: {module(), state :: term()}
  @type summary :: map()
  @callback append(state :: term(), lesson :: Lesson.t()) :: :ok | {:error, term()}
  @callback read(state :: term(), id :: String.t()) :: {:ok, Lesson.t()} | {:error, term()}
  @callback history(state :: term()) :: {:ok, [summary()]} | {:error, term()}
  @callback prune(state :: term(), id :: String.t(), reason :: String.t(), at :: DateTime.t()) ::
              :ok | {:error, term()}

  @doc "Appends verified immutable content under the adapter's bound scope."
  @spec append(store :: t(), lesson :: Lesson.t()) :: :ok | {:error, term()}
  def append({module, state}, %Lesson{} = lesson) do
    with :ok <- Lesson.verify(lesson), do: module.append(state, lesson)
  end

  @doc "Reads full content for authorized host inspection, never model context."
  @spec read(store :: t(), id :: String.t()) :: {:ok, Lesson.t()} | {:error, term()}
  def read({module, state}, id) do
    with {:ok, lesson} <- module.read(state, id), :ok <- Lesson.verify(lesson), do: {:ok, lesson}
  end

  @doc "Lists bounded metadata for retained and pruned lessons."
  @spec history(store :: t()) :: {:ok, [summary()]} | {:error, term()}
  def history({module, state}), do: module.history(state)

  @doc "Removes source/content bytes, retaining an immutable audit tombstone."
  @spec prune(store :: t(), id :: String.t(), reason :: String.t(), at :: DateTime.t()) ::
          :ok | {:error, term()}
  def prune({module, state}, id, reason, %DateTime{} = at),
    do: module.prune(state, id, reason, at)

  @doc """
  Releases current, unambiguous lessons only after durable exposure commit.

  `consumer` uses `Corpus.Exposure` attributes and requires explicit `id` and
  UTC `at` for repeatable delivery. Its case/derivation ids and context digest
  are computed here, rather than accepted from the consumer. The host passes
  current identity strings as `context`, and may pass `now:` for a fixed
  replay clock. Empty recall calls no committer and returns a nil exposure.
  `max_lessons:` (16) and `max_bytes:` (eight MiB of complete encodings) refuse
  an oversized result before exposure, without silently truncating it. This
  is eligibility filtering; relevance ranking belongs to the host.
  """
  @spec recall(
          store :: t(),
          context :: map(),
          consumer :: map(),
          commit :: (map(), Exposure.t() -> :ok | {:error, term()}),
          opts :: keyword()
        ) ::
          {:ok, [Lesson.t()], Exposure.t() | nil} | {:error, term()}
  def recall(store, context, consumer, commit, opts \\ [])
      when is_map(context) and is_map(consumer) and is_function(commit, 2) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, history} <- history(store),
         {:ok, current} <- current(store, history, context, now, opts),
         :ok <- unambiguous(current) do
      release(current, context, consumer, commit)
    end
  end

  defp current(store, history, context, now, opts) do
    superseded = history |> Enum.flat_map(& &1["supersedes"]) |> MapSet.new()
    limits = {Keyword.get(opts, :max_lessons, 16), Keyword.get(opts, :max_bytes, 8 * 1024 * 1024)}

    history
    |> Enum.reject(&(&1["status"] == "pruned" or MapSet.member?(superseded, &1["id"])))
    |> Enum.reduce_while({:ok, {[], 0}}, fn summary, {:ok, accumulator} ->
      collect_current(read(store, summary["id"]), accumulator, context, now, limits)
    end)
    |> case do
      {:ok, {lessons, _bytes}} -> {:ok, lessons}
      error -> error
    end
  end

  defp collect_current({:ok, lesson}, accumulator, context, now, limits) do
    if Lesson.applicable(lesson, context, now) == :ok,
      do: collect_bounded(lesson, accumulator, limits),
      else: {:cont, {:ok, accumulator}}
  end

  defp collect_current({:error, :pruned}, accumulator, _context, _now, _limits),
    do: {:cont, {:ok, accumulator}}

  defp collect_current(error, _accumulator, _context, _now, _limits), do: {:halt, error}

  defp collect_bounded(lesson, {lessons, bytes}, {max_lessons, max_bytes}) do
    next_bytes = bytes + byte_size(Lesson.encode!(lesson))

    if is_integer(max_lessons) and is_integer(max_bytes) and length(lessons) < max_lessons and
         next_bytes <= max_bytes,
       do: {:cont, {:ok, {lessons ++ [lesson], next_bytes}}},
       else: {:halt, {:error, :lesson_recall_limit}}
  end

  defp unambiguous(lessons) do
    case lessons
         |> Enum.group_by(& &1.key)
         |> Enum.sort()
         |> Enum.find(fn {_key, group} -> length(group) > 1 end) do
      nil -> :ok
      {key, group} -> {:error, {:lesson_conflict, key, Enum.map(group, & &1.id)}}
    end
  end

  defp release([], _context, _consumer, _commit), do: {:ok, [], nil}

  defp release([first | _] = lessons, context, consumer, commit) do
    attrs =
      consumer
      |> Map.take(~w(id consumer_role consumer_id lineage_id model experiment_id at))
      |> Map.merge(%{
        "context_digest" => Contract.digest(context),
        "direct_case_ids" => [],
        "derived_artifact_ids" => Enum.map(lessons, & &1.id),
        "source_case_ids" =>
          lessons |> Enum.flat_map(& &1.source_case_ids) |> Enum.uniq() |> Enum.sort()
      })

    with true <- is_binary(consumer["id"]) and is_binary(consumer["at"]),
         true <- Enum.all?(lessons, &(&1.scope == first.scope)),
         {:ok, exposure} <- Exposure.new(attrs),
         :ok <- committed(commit, first.scope, exposure) do
      {:ok, lessons, exposure}
    else
      false -> {:error, :invalid_lesson_consumer}
      error -> error
    end
  end

  defp committed(commit, scope, exposure) do
    case commit.(scope, exposure) do
      :ok -> :ok
      {:error, reason} -> {:error, {:exposure_not_committed, reason}}
      _other -> {:error, :invalid_exposure_commit_result}
    end
  end
end
