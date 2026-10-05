defmodule Lemieux.Transcript.Dedup do
  @moduledoc """
  Writes each large repeated value of a transcript once, and reads it back
  whole.

  ## Why

  Every request records what it sent: the system prompt, the tool schemas and
  the tool catalog. Measured on a real session, that audit record was about
  92% of the transcript — twenty requests carried three distinct system
  prompts and two distinct catalogs, written out in full twenty times, plus a
  harness snapshot repeating the tool descriptors beside each one. Resume,
  fork and every display that reads the file paid for all of it.

  ## How

  `compact/2` replaces a large field whose exact value was already written
  earlier in the same transcript with `%{"$sha256" => digest}`. The first
  occurrence stays whole, in the file, so a transcript stays one
  self-contained file that can be copied anywhere. `expand/1` walks entries in
  order and puts every value back; whoever reads a transcript through
  `Lemieux.Store.JSONL`, a resumed session or `Lemieux.Transcript.expand/1`
  sees exactly the payloads that were built. Nothing outside the stored line
  changes: digests over a payload (`Lemieux.RequestSnapshot.verify/1`) are
  over the whole value, as before.

  A compacted entry is written at schema version #{5} (see
  `Lemieux.Entry`): a reference is a change of a field's meaning, and a build
  that cannot resolve one must refuse the line rather than hand a map to
  code expecting a system prompt. Expanded entries read back at the
  version they were built with.

  Only the fields listed here are candidates, and only above
  #{1_024} bytes of JSON: small values cost less than their references.
  """

  alias Lemieux.Entry

  @fields %{
    request: ~w(system tools catalog),
    session: ~w(system),
    harness_snapshot: ~w(tools extensions)
  }

  @min_bytes 1_024
  @ref_key "$sha256"

  # The version an expanded entry reads back as. Compaction only ever touches
  # the ordinary vocabulary, which is written at version 2.
  @expanded_version 2

  @typedoc "Digests of every compactable value already written in full."
  @type seen :: MapSet.t(String.t())

  @doc "The digests written in full by `entries`, which must be expanded."
  @spec seen(entries :: [Entry.t()]) :: seen()
  def seen(entries) when is_list(entries) do
    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      entry
      |> candidates()
      |> Enum.reduce(seen, fn {_field, value}, seen -> MapSet.put(seen, digest(value)) end)
    end)
  end

  @doc """
  The form of `entry` to write, given the digests already written in full.

  Returns the entry unchanged, apart from its version, when nothing it holds
  was written before; the returned `seen` includes what it now writes.
  """
  @spec compact(entry :: Entry.t(), seen :: seen()) :: {Entry.t(), seen()}
  def compact(%Entry{} = entry, seen) do
    {payload, seen, compacted?} =
      entry
      |> candidates()
      |> Enum.reduce({entry.payload, seen, false}, fn {field, value}, {payload, seen, any?} ->
        digest = digest(value)

        if MapSet.member?(seen, digest),
          do: {Map.put(payload, field, %{@ref_key => digest}), seen, true},
          else: {payload, MapSet.put(seen, digest), any?}
      end)

    if compacted?,
      do: {%{entry | payload: payload, v: Entry.compacted_version()}, seen},
      else: {entry, seen}
  end

  @doc "Compacts a whole run of entries written together, oldest first."
  @spec compact_all(entries :: [Entry.t()]) :: [Entry.t()]
  def compact_all(entries) when is_list(entries) do
    {compacted, _seen} = Enum.map_reduce(entries, MapSet.new(), &compact/2)
    compacted
  end

  @doc """
  Puts every referenced value back, in append order.

  A reference whose value never appeared earlier is left as it is: it means
  lines were lost, and hiding that would be worse than showing it. Entries
  with nothing to expand come back untouched, so this is cheap on a
  transcript written before compaction existed.
  """
  @spec expand(entries :: [Entry.t()]) :: [Entry.t()]
  def expand(entries) when is_list(entries) do
    if Enum.any?(entries, &(&1.v == Entry.compacted_version())) do
      {expanded, _table} = Enum.map_reduce(entries, %{}, &expand_entry/2)
      expanded
    else
      entries
    end
  end

  defp expand_entry(%Entry{type: type, payload: payload} = entry, table)
       when is_map_key(@fields, type) do
    {payload, table} =
      @fields
      |> Map.fetch!(type)
      |> Enum.reduce({payload, table}, fn field, {payload, table} ->
        case Map.get(payload, field) do
          %{@ref_key => digest} = reference ->
            {Map.put(payload, field, Map.get(table, digest, reference)), table}

          value ->
            {payload, remember(table, value)}
        end
      end)

    version =
      if entry.v == Entry.compacted_version(), do: @expanded_version, else: entry.v

    {%{entry | payload: payload, v: version}, table}
  end

  defp expand_entry(entry, table), do: {entry, table}

  defp remember(table, value) do
    if large?(value), do: Map.put_new(table, digest(value), value), else: table
  end

  # The fields of `entry` large enough to be worth a reference, whole values
  # only: a reference inside a reference-able value would make one field's
  # meaning depend on another's.
  defp candidates(%Entry{type: type, payload: payload}) when is_map_key(@fields, type) do
    @fields
    |> Map.fetch!(type)
    |> Enum.flat_map(&candidate(&1, Map.get(payload, &1)))
  end

  defp candidates(_entry), do: []

  defp candidate(_field, %{@ref_key => _digest}), do: []
  defp candidate(field, value), do: if(large?(value), do: [{field, value}], else: [])

  defp large?(nil), do: false
  defp large?(value) when is_binary(value), do: byte_size(value) >= @min_bytes
  defp large?(value), do: value |> JSON.encode!() |> byte_size() >= @min_bytes

  defp digest(value) when is_binary(value), do: hash(value)
  defp digest(value), do: value |> JSON.encode!() |> hash()

  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
