defmodule Lemieux.Session.Core do
  @moduledoc false

  alias Lemieux.Compaction
  alias Lemieux.Entry
  alias Lemieux.Session.Subscribers
  alias Lemieux.Store
  alias Lemieux.Transcript.Dedup

  # Requests without an automatic threshold compaction after one fails,
  # doubling per consecutive failure up to the last.
  @compaction_backoff [2, 4, 8, 16, 32]

  def pending(state) do
    Enum.map(state.parked, fn {call_id, waiting} ->
      %{call_id: call_id, kind: waiting.kind, payload: waiting.payload}
    end)
  end

  def busy?(state), do: status(state) == :busy

  def status(%{
        turn: nil,
        wave: %{tool_tasks: tasks},
        compaction: %{compacting: nil},
        hook_task: nil,
        mcp_wait: nil,
        subagent_groups: groups
      })
      when map_size(tasks) == 0 and map_size(groups) == 0,
      do: :idle

  def status(_state), do: :busy

  def entries(state), do: Enum.reverse(state.reversed_entries)

  # Evidence records describe the conversation but are not part of it. The
  # provider adapter would drop them, yet leaving their large manifests in
  # context accounting or compaction would still charge and cut based on bytes
  # the model can never see.
  #
  # A partial answer kept from a retried request is the same kind of record:
  # what the model had said when the stream died, for a reader, never for the
  # model, which is answering the same request again. Dropped here as well as
  # by `Lemieux.Compaction.applied/2` so a host's own compaction cannot resend it.
  def behavior_entries(state) do
    Enum.reject(entries(state), fn entry ->
      entry.type in [:harness_snapshot, :run_evidence, :guidance] or Compaction.partial?(entry)
    end)
  end

  # The grouped parts of the state — `Lemieux.Session.State` says which and
  # why — are written through these so a pipeline reads as one step, and a
  # misspelt key still fails at the struct rather than growing the map.
  def put_compaction(state, key, value),
    do: %{state | compaction: %{state.compaction | key => value}}

  def forget_compaction_failures(state),
    do: %{state | compaction: %{state.compaction | failures: 0, retry_at: nil}}

  def back_off_compaction(state), do: back_off_compaction(state, state.compaction.failures + 1)

  # A summary that left the next request still over the threshold freed
  # nothing, and the next one would free nothing either: what stays is the
  # session's own instructions, its tools and a summary, none of which a cut
  # can shrink. The doubling a failed summary gets would summarise again
  # three, eight and seventeen requests later — minutes each on a local
  # model — so this goes straight to the longest wait. A successful summary,
  # a clear, a model change or a new served window forgets it; a window
  # stated by a refusal does not (`Catalog.learn_window/2`).
  def back_off_ineffective_compaction(state),
    do:
      back_off_compaction(
        state,
        max(state.compaction.failures + 1, length(@compaction_backoff))
      )

  defp back_off_compaction(state, failures) do
    wait = Enum.at(@compaction_backoff, failures - 1, List.last(@compaction_backoff))

    %{
      state
      | compaction: %{
          state.compaction
          | failures: failures,
            retry_at: state.request_count + wait
        }
    }
  end

  def put_wave(state, key, value), do: %{state | wave: %{state.wave | key => value}}

  def put_evidence(state, key, value),
    do: %{state | evidence: %{state.evidence | key => value}}

  def forget_assembly(state),
    do:
      put_evidence(
        state,
        :harness_context,
        Map.delete(state.evidence.harness_context, "assembly")
      )

  def forget_wave(state),
    do: %{state | wave: %{state.wave | last_wave: nil, repeats: 0, recent_calls: []}}

  def forget_context_recovery(state) do
    %{
      state
      | compaction: %{
          state.compaction
          | context_recovery_attempted?: false,
            context_recovery_reason: nil
        }
    }
  end

  def append(state, {type, payload, usage}) do
    append(state, {type, payload, usage}, [])
  end

  def append(state, {type, payload, usage}, opts) do
    parent = List.first(state.reversed_entries)

    entry =
      Entry.new(
        type,
        payload,
        Keyword.merge(opts, parent: parent, usage: usage, seq: state.next_seq)
      )

    # A session that cannot write its transcript has nothing left to promise —
    # resume, fork and replay are all reads over this file. Crashing is louder
    # than continuing with a log that has a hole in it, and the entries
    # already written are still on disk.
    # What is written may refer to large values written before; what is kept
    # in memory, and sent to subscribers, is always the whole entry.
    {stored, seen} = stored_form(entry, state.transcript_seen)

    case Store.append(state.store, state.id, [stored]) do
      :ok ->
        %{
          state
          | reversed_entries: [entry | state.reversed_entries],
            transcript_seen: seen,
            next_seq: state.next_seq + 1,
            request_count: state.request_count + if(type == :request, do: 1, else: 0)
        }
        |> emit({:entry, entry})

      {:error, reason} ->
        raise "lemieux: could not persist an entry to session #{state.id}: #{inspect(reason)}"
    end
  end

  defp stored_form(entry, nil), do: {entry, nil}
  defp stored_form(entry, seen), do: Dedup.compact(entry, seen)

  def emit(state, event) do
    Subscribers.broadcast(state.subscribers, state.id, event)
    state
  end
end
