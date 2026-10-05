defmodule Lemieux.Transcript do
  @moduledoc """
  Reads over a stored transcript that produce another one.

  Forking lives here rather than on `Lemieux.Session` because it is not
  something a running agent does: it is an operation on entries at rest, and
  the session that continues a fork is started afterwards, the same way any
  other stored transcript is resumed. Keeping it out of the session process
  also means a fork can be taken while the source is still running, and
  needs nothing from it.

  ## What a fork is

  A copy of a transcript's entries up to a chosen one, written under a new
  id, followed by a `:fork` entry recording where the copy came from. That is
  the whole mechanism — there is no branch pointer, no shared storage, and
  nothing the source has to know about.

  **The copied entries keep their ids.** The obvious alternative is to mint
  fresh ones and rewrite every `parent_id` to match, which sounds tidier and
  loses the only cheap way to tell that two transcripts describe the same
  history: an entry id appearing in both. Rewriting also breaks the promise
  the transcript exists to keep — that the request sent at a given turn can
  be rebuilt exactly — by making the rebuilt prefix differ from the one that
  was actually sent.

  The `:fork` entry goes at the end of the copied prefix rather than in front
  of it, so the chain of `parent_id`s runs unbroken from the first entry to
  whatever the forked session does next. In front, it would be a second root.
  """

  alias Lemieux.Entry
  alias Lemieux.ID
  alias Lemieux.RequestSnapshot
  alias Lemieux.Store
  alias Lemieux.Transcript.Dedup

  @doc """
  Copies `source_id`'s history into a new transcript and returns its id.

  Copies up to and including the entry `at`; with no `at`, copies all of it.
  Returns `{:error, :not_found}` for a session that was never written, and
  `{:error, {:unknown_entry, id}}` for a cut point that is not in it — an
  unrecognised cut point is a mistake worth reporting, and forking the whole
  transcript instead would produce something that looks right and is not what
  was asked for.
  """
  @spec fork(store :: Store.t(), source_id :: String.t(), at :: selector() | nil) ::
          {:ok, String.t()} | {:error, term()}
  def fork(store, source_id, at \\ nil), do: fork(store, source_id, at, [])

  @typedoc "A fork cut named by entry id, sequence number, or completed assistant turn."
  @type selector :: String.t() | {:seq, non_neg_integer()} | {:turn, pos_integer()}

  @doc "Forks with options. `unsafe: true` permits a cut inside an active turn."
  @spec fork(Store.t(), String.t(), selector() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def fork(store, source_id, at, opts) do
    with {:ok, entries} <- Store.read(store, source_id),
         :ok <- validate(entries),
         {:ok, prefix} <- prefix(entries, at),
         :ok <- safe(prefix, opts) do
      write(store, source_id, prefix, at)
    end
  end

  @doc "Validates sequence and parent linkage in a transcript."
  @spec validate([Entry.t()]) :: :ok | {:error, term()}
  def validate(entries) when is_list(entries) do
    if Enum.all?(entries, &(&1.seq == 0 and is_nil(&1.parent_id))),
      do: :ok,
      else: validate(entries, nil, 0)
  end

  @doc """
  Whether `entries` are a delegated child's transcript rather than a root's.

  A child session is an ordinary session in an ordinary transcript, written
  to the same store as its parent — which is what makes replay and `lmx log`
  work on one without a second mechanism, and what made a session picker
  offer three scouts nobody had a conversation with for every delegation.

  The signal is structural rather than a recorded flag: a child's coordinator
  writes the child's own result envelope into the child's own transcript, so
  a transcript naming *itself* as the child of a delegation is one. That
  reads a fact already there, which is why it is preferred to recording the
  root id in the session's configuration entry — identity is not something a
  resume restores, and putting it there made every fork record a
  configuration change.

  Best-effort in one direction, on purpose: a child whose session died before
  it could take its envelope has nothing to find, and answers false. So this
  is the right question for *what to offer* somebody, and the wrong one for
  authorization. Resuming a child by id deliberately still works — that is
  how you go and look at one.
  """
  @spec delegated?(entries :: [Entry.t()], id :: String.t()) :: boolean()
  def delegated?(entries, id) when is_list(entries) and is_binary(id) do
    Enum.any?(entries, fn entry ->
      entry.type == :subagent_result and
        (entry.payload["child_id"] == id or entry.payload["transcript_id"] == id)
    end)
  end

  @doc """
  The tool calls on a transcript that nothing ever answered.

  A session answers every call in a wave before its next request, so a
  transcript only holds one of these if the process died inside the wave or
  a fork was cut there (`unsafe: true`). Either way the next request would
  carry an assistant turn whose calls are not all answered, which every
  provider refuses — `Lemieux.Session` answers them as unknown on resume,
  and `Lemieux.Tool.Receipt` says what that tells the model.

  Matched wave by wave rather than by id across the whole transcript: a
  scripted provider, and some real ones, reuse call ids across turns, and
  the result that answered `t1` two turns ago does not answer this one.
  """
  @spec unanswered_calls(entries :: [Entry.t()]) :: [Lemieux.Provider.tool_call()]
  def unanswered_calls(entries) when is_list(entries) do
    {pending, lost} =
      Enum.reduce(entries, {[], []}, fn
        %Entry{type: :assistant, payload: payload}, {pending, lost} ->
          calls = payload |> Map.get("tool_calls", []) |> Enum.map(&call/1)
          {calls, lost ++ pending}

        %Entry{type: :tool_result, payload: %{"call_id" => id}}, {pending, lost} ->
          {Enum.reject(pending, &(&1.id == id)), lost}

        %Entry{type: type}, {pending, lost}
        when type in [:user, :request, :error, :cancelled, :compaction] ->
          {[], lost ++ pending}

        _entry, acc ->
          acc
      end)

    lost ++ pending
  end

  defp call(call) when is_map(call),
    do: %{id: call["id"], name: call["name"] || "", arguments: call["arguments"] || %{}}

  @doc """
  Puts back the large values a transcript wrote once and referenced after.

  `Lemieux.Store.JSONL` and a resumed session do this themselves. A host that
  reads entries from its own store and inspects request or harness snapshots
  calls it first; see `Lemieux.Transcript.Dedup`. Entries with nothing to put
  back are returned as they are.
  """
  @spec expand(entries :: [Entry.t()]) :: [Entry.t()]
  defdelegate expand(entries), to: Dedup

  @doc "Returns every durable request snapshot in order."
  @spec requests([Entry.t()]) :: [Entry.t()]
  def requests(entries), do: Enum.filter(entries, &(&1.type == :request))

  @doc "Finds one durable request snapshot by its request id."
  @spec request([Entry.t()], String.t()) :: {:ok, Entry.t()} | {:error, :not_found}
  def request(entries, request_id) do
    case Enum.find(requests(entries), &(&1.payload["id"] == request_id)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  @doc "Returns the text of the latest assistant entry that contains visible text."
  @spec latest_assistant_text(entries :: [Entry.t()]) ::
          {:ok, String.t()} | {:error, :not_found}
  def latest_assistant_text(entries) when is_list(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Entry{type: :assistant, payload: %{"content" => content}} when is_list(content) ->
        case assistant_text(content) do
          "" -> nil
          text -> {:ok, text}
        end

      _entry ->
        nil
    end)
    |> case do
      nil -> {:error, :not_found}
      result -> result
    end
  end

  @doc """
  Returns the verified canonical input for a historical provider request.

  This is provider-neutral replay, not byte-for-byte HTTP replay: req_llm owns
  provider wire translation, and a future req_llm version may serialize the
  same canonical request differently.
  """
  @spec replay_request([Entry.t()], String.t()) :: {:ok, map()} | {:error, term()}
  def replay_request(entries, request_id) do
    with {:ok, entry} <- request(entries, request_id),
         :ok <- RequestSnapshot.verify(entry.payload) do
      {:ok,
       Map.take(entry.payload, [
         "id",
         "kind",
         "model",
         "system",
         "entry_ids",
         "tools",
         "params",
         "output_schema",
         "lemieux_version",
         "req_llm_version",
         "harness_snapshot_id",
         "harness_snapshot_sha256"
       ])}
    end
  end

  defp assistant_text(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) and text != "" -> [text]
      _content -> []
    end)
    |> Enum.join("\n")
  end

  defp prefix(entries, nil), do: {:ok, entries}

  defp prefix(entries, {:seq, seq}) do
    case Enum.find_index(entries, &(&1.seq == seq)) do
      nil -> {:error, {:unknown_seq, seq}}
      index -> {:ok, Enum.take(entries, index + 1)}
    end
  end

  defp prefix(entries, {:turn, turn}) do
    case entries |> Enum.filter(&(&1.type == :assistant)) |> Enum.at(turn - 1) do
      nil -> {:error, {:unknown_turn, turn}}
      entry -> prefix(entries, entry.id)
    end
  end

  defp prefix(entries, at) do
    case Enum.find_index(entries, &(&1.id == at)) do
      nil -> {:error, {:unknown_entry, at}}
      index -> {:ok, Enum.take(entries, index + 1)}
    end
  end

  defp write(store, source_id, prefix, at) do
    id = ID.generate()

    marker =
      Entry.new(:fork, %{"from" => source_id, "at" => selector_value(at) || last_id(prefix)},
        parent: List.last(prefix),
        seq: length(prefix)
      )

    # The prefix was read whole; written back, its repeated large values are
    # referenced again, as the session that wrote them did.
    case Store.append(store, id, Dedup.compact_all(prefix ++ [marker])) do
      :ok -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp last_id([]), do: nil
  defp last_id(entries), do: entries |> List.last() |> Map.fetch!(:id)

  defp selector_value(nil), do: nil
  defp selector_value(value) when is_binary(value), do: value
  defp selector_value({_kind, value}), do: value

  defp validate([], _parent, _seq), do: :ok

  defp validate([%Entry{seq: seq, parent_id: parent} = entry | rest], expected_parent, seq) do
    if parent == expected_parent,
      do: validate(rest, entry.id, seq + 1),
      else: {:error, {:invalid_parent, entry.id, expected_parent, parent}}
  end

  defp validate([%Entry{seq: actual} | _rest], _parent, expected),
    do: {:error, {:invalid_seq, expected, actual}}

  defp safe(_prefix, unsafe: true), do: :ok

  defp safe(prefix, _opts) do
    if safe_boundary?(prefix),
      do: :ok,
      else: {:error, {:unsafe_fork, last_id(prefix)}}
  end

  defp safe_boundary?([]), do: true

  defp safe_boundary?(entries) do
    case List.last(entries) do
      %Entry{type: type}
      when type in [:error, :cancelled, :compaction, :fork, :session, :run_evidence] ->
        true

      %Entry{type: :assistant, payload: payload} ->
        Map.get(payload, "tool_calls", []) == []

      %Entry{type: :tool_result} ->
        complete_tool_wave?(entries)

      _entry ->
        false
    end
  end

  defp complete_tool_wave?(entries) do
    case Enum.find_index(Enum.reverse(entries), &(&1.type == :assistant)) do
      nil ->
        false

      reverse_index ->
        index = length(entries) - reverse_index - 1
        [%Entry{payload: payload} | after_assistant] = Enum.drop(entries, index)
        expected = payload |> Map.get("tool_calls", []) |> Enum.map(& &1["id"]) |> MapSet.new()

        actual =
          after_assistant
          |> Enum.filter(&(&1.type == :tool_result))
          |> Enum.map(& &1.payload["call_id"])
          |> MapSet.new()

        MapSet.equal?(expected, actual)
    end
  end
end
