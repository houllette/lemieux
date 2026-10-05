defmodule Lemieux.Entry do
  @moduledoc """
  One immutable fact in a session's transcript.

  A session is not a mutable conversation that gets rewritten as it grows; it
  is an append-only list of these. Everything lemieux promises on top —
  resume, fork, replay — is a read over that list, which is only true as long
  as entries are never edited in place. Compaction is the interesting case and
  it obeys the same rule: it appends an entry saying what was summarised
  rather than deleting what it summarised.

  ## The shape

    * `id` — a `Lemieux.ID`, so entries sort into causal order on their own.
    * `parent_id` — the entry this one followed, or `nil` for the first.
      Redundant with file order in a linear transcript and load-bearing the
      moment a session is forked: a fork copies a prefix, and lineage is what
      distinguishes "these two entries are the same fact" from "these two
      entries happen to be adjacent".
    * `seq` — this entry's position in its transcript, counting from zero.
      Redundant in a JSONL file, where append order is the file's order, and
      necessary the moment a host keeps entries anywhere that has none: rows
      in a table come back in whatever order the query implies, and
      reconstructing the conversation by walking `parent_id` is a linked-list
      traversal where an `ORDER BY` should do. Assigned by the session that
      appends it; zero for an entry nobody has placed in a transcript.
    * `type` — one of `#{inspect(~w(user assistant tool_result system error cancelled compaction fork session harness_snapshot request run_evidence approval subagent_spawn subagent_steer subagent_result subagent_group_result extension_state)a)}`.
    * `payload` — the entry's content. Always a JSON-shaped map.
    * `usage` — token accounting for the request or paid extension operation
      this entry came from, or `nil`. Also JSON-shaped.
    * `meta` — a host's own data, and the one field lemieux never reads.
      `payload` is defined per type and belongs to this library, so an
      embedder that hung its own identifiers there would collide with the
      next type that needed the same key. Empty by default.
    * `at` — when it happened, UTC.
    * `v` — schema `2` for ordinary entries, `4` for opaque extension checkpoints.
      Mixed-version transcripts retain every entry's original version.

  ## Why the payload is stringly-typed

  Payload and usage maps are required to have **string keys, all the way
  down**, and `new/3` raises rather than converting. Atom keys would encode
  fine and decode to string keys, so an entry would stop being equal to itself
  across a write and a read — the bug would surface as a resumed session
  quietly losing content, long after the write that caused it. Better to fail
  at the call site.

  It also keeps the atom table out of the file format. A decoder that turned
  arbitrary payload keys into atoms would be a memory leak with an on-disk
  attack surface; the only atoms this module creates from a file are entry
  types, and those come from a fixed compile-time list.

  ## What a session was, not just what was said

  A `:session` entry records the model, system prompt, tool set and working
  directory a session was running with, written when a session starts and
  again whenever any of it changes. It is what makes a transcript
  self-contained: without it, resuming rebuilds the conversation but not the
  configuration, so a session started with a restricted tool set silently got
  the default one back, and a custom system prompt was replaced by the stock
  one. Both were real, and both looked like the resume had worked.

  ## Why the version ships in version one

  `v` is written from the first line ever persisted, before there is anything
  to migrate, because the alternative is discovering that unversioned lines
  exist at the moment the format first has to change. A reader that meets a
  version it does not know refuses the line instead of guessing at it.
  """

  alias Lemieux.ID

  @version_1_types ~w(user assistant tool_result system error cancelled compaction fork session request approval subagent_spawn subagent_steer subagent_result subagent_group_result)a
  @version_2_types @version_1_types ++ [:harness_snapshot, :run_evidence]
  @types @version_2_types ++ [:extension_state]
  @type_strings Map.new(@version_2_types, &{Atom.to_string(&1), &1})
  @version_4_type_strings Map.put(@type_strings, "extension_state", :extension_state)
  @version_1_type_strings Map.new(@version_1_types, &{Atom.to_string(&1), &1})

  # Research builds wrote v3, adding paid guidance records. Preserve them as
  # inert history so existing builder sessions still resume after research closes.
  # New entries use the released v2 vocabulary; no graph executor is restored.
  @research_type_strings Map.put(@type_strings, "guidance", :guidance)

  @version 2

  # A version-2 entry whose large repeated fields are written as references
  # (`Lemieux.Transcript.Dedup`). Readers expand it back to version 2; a build
  # that does not know it refuses the line rather than reading a reference as
  # the value it stands for.
  @compacted_version 5

  @typedoc """
  The kind of fact an entry records.

  There is no separate `:tool_use` type. A model's tool calls live on the
  `:assistant` entry that made them, in its payload, because that is where
  they live in the conversation the provider will be sent — and a second
  record of the same fact, in a second entry, is a thing that can disagree
  with the first. What a hook *changed* about a call is recorded on the
  `:tool_result` next to the output it produced, where it cannot drift away
  from it.
  """
  @type type ::
          :user
          | :assistant
          | :tool_result
          | :system
          | :error
          | :cancelled
          | :compaction
          | :guidance
          | :fork
          | :session
          | :harness_snapshot
          | :request
          | :run_evidence
          | :extension_state
          | :approval
          | :subagent_spawn
          | :subagent_steer
          | :subagent_result
          | :subagent_group_result

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          seq: non_neg_integer(),
          type: type(),
          payload: map(),
          usage: map() | nil,
          meta: map(),
          at: DateTime.t(),
          v: pos_integer()
        }

  @enforce_keys [:id, :type, :payload, :at]
  defstruct [:id, :parent_id, :type, :payload, :usage, :at, seq: 0, meta: %{}, v: @version]

  @doc """
  Returns every entry type this schema version knows.
  """
  @spec types() :: [type()]
  def types, do: @types

  @doc """
  Builds an entry.

  ## Options

    * `:parent` — the entry (or entry id) this one follows.
    * `:usage` — token accounting, JSON-shaped.
    * `:at` — the timestamp, defaulting to now.
    * `:id` — the id, defaulting to a fresh one. Passing one is for
      reconstruction, not for ordinary appends.
    * `:seq` — this entry's position in its transcript, assigned by the
      session that appends it. Zero for an entry nobody has placed in one.
    * `:meta` — a host's own data. lemieux never reads it.
  """
  @spec new(type :: type(), payload :: map(), opts :: keyword()) :: t()
  def new(type, payload, opts \\ []) when is_map(payload) and is_list(opts) do
    unless type in @types do
      raise ArgumentError,
            "unknown entry type #{inspect(type)}, expected one of #{inspect(@types)}"
    end

    usage = Keyword.get(opts, :usage)
    meta = Keyword.get(opts, :meta, %{})

    validate_json_shape!(payload, "payload")
    validate_json_shape!(meta, "meta")
    if usage, do: validate_json_shape!(usage, "usage")

    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, &ID.generate/0),
      parent_id: parent_id(Keyword.get(opts, :parent)),
      seq: Keyword.get(opts, :seq, 0),
      type: type,
      v: if(type == :extension_state, do: 4, else: @version),
      payload: payload,
      usage: usage,
      meta: meta,
      at: Keyword.get_lazy(opts, :at, &DateTime.utc_now/0)
    }
  end

  @doc """
  The schema version of a line whose large repeated fields are written as
  references. See `Lemieux.Transcript.Dedup`.
  """
  @spec compacted_version() :: pos_integer()
  def compacted_version, do: @compacted_version

  @doc """
  Encodes an entry as one line of JSON, with no trailing newline.

  Single-line output is what makes a transcript file greppable and appendable
  without a parser: the caller adds the newline that separates records.
  """
  @spec encode!(entry :: t()) :: String.t()
  def encode!(%__MODULE__{} = entry) do
    JSON.encode!(%{
      "v" => entry.v,
      "id" => entry.id,
      "parent_id" => entry.parent_id,
      "seq" => entry.seq,
      "type" => Atom.to_string(entry.type),
      "payload" => entry.payload,
      "usage" => entry.usage,
      "meta" => entry.meta,
      "at" => DateTime.to_iso8601(entry.at)
    })
  end

  @doc """
  Decodes one line written by `encode!/1`.

  Raises on anything it does not recognise — an unknown schema version, an
  unknown type, a malformed timestamp. A transcript is the only copy of what
  happened, so a reader that silently dropped the parts it could not
  understand would hand the model a conversation missing its middle.
  """
  @spec decode!(line :: String.t()) :: t()
  def decode!(line) when is_binary(line) do
    line |> JSON.decode!() |> from_json!()
  end

  @doc """
  Builds an entry from an already-decoded JSON map.
  """
  @spec from_json!(map()) :: t()
  def from_json!(%{"v" => @version} = json), do: from_supported_json!(json, @type_strings)

  def from_json!(%{"v" => @compacted_version} = json),
    do: from_supported_json!(json, @type_strings)

  def from_json!(%{"v" => 1} = json), do: from_supported_json!(json, @version_1_type_strings)

  def from_json!(%{"v" => 4} = json), do: from_supported_json!(json, @version_4_type_strings)

  def from_json!(%{"v" => 3} = json), do: from_supported_json!(json, @research_type_strings)

  def from_json!(%{"v" => other}) do
    raise ArgumentError,
          "entry schema version #{inspect(other)} is not supported by this build " <>
            "(this one writes versions #{@version}, 4 and #{@compacted_version} and reads " <>
            "versions 1, 2, 3, 4 and #{@compacted_version})"
  end

  def from_json!(_json), do: raise(ArgumentError, "entry is missing its schema version")

  defp from_supported_json!(json, type_strings) do
    version = Map.fetch!(json, "v")

    %__MODULE__{
      id: Map.fetch!(json, "id"),
      parent_id: Map.get(json, "parent_id"),
      seq: Map.get(json, "seq", 0),
      type: decode_type!(Map.fetch!(json, "type"), type_strings),
      payload: Map.fetch!(json, "payload"),
      usage: Map.get(json, "usage"),
      meta: Map.get(json, "meta") || %{},
      at: json |> Map.fetch!("at") |> DateTime.from_iso8601() |> elem(1),
      v: version
    }
  end

  defp decode_type!(string, type_strings) do
    case Map.fetch(type_strings, string) do
      {:ok, type} -> type
      :error -> raise ArgumentError, "unknown entry type #{inspect(string)}"
    end
  end

  defp parent_id(nil), do: nil
  defp parent_id(%__MODULE__{id: id}), do: id
  defp parent_id(id) when is_binary(id), do: id

  defp validate_json_shape!(map, where) when is_map(map) do
    Enum.each(map, fn {key, value} ->
      unless is_binary(key) do
        raise ArgumentError,
              "#{where} keys must be strings, got #{inspect(key)} — an entry with atom keys " <>
                "would not decode back to itself"
      end

      validate_json_shape!(value, where)
    end)
  end

  defp validate_json_shape!(list, where) when is_list(list) do
    Enum.each(list, &validate_json_shape!(&1, where))
  end

  defp validate_json_shape!(_other, _where), do: :ok
end
