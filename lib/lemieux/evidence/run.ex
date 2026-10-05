defmodule Lemieux.Evidence.Run do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A versioned terminal manifest for one accepted Lemieux prompt.

  This is an index over the append-only transcript, not a second transcript.
  It contains provider-neutral outcomes, completeness, correlations, and
  digest-bearing references; prompt text, tool arguments/results, paths, and
  grader bodies remain in access-controlled artifacts. Failed, canceled, and
  budget-stopped runs use the same manifest as successful runs.
  """

  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Harness.Snapshot
  alias Lemieux.ModelSpec
  alias Lemieux.Usage

  @version 1
  @outcomes ~w(succeeded failed canceled timed_out budget_stopped stopped)
  @completeness ~w(complete partial unknown not_applicable)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          created_at: DateTime.t(),
          correlations: map(),
          provider: String.t() | nil,
          model: String.t(),
          outcome: String.t(),
          stop_reason: String.t(),
          timing: map(),
          usage: map(),
          cost: map(),
          cache: map(),
          retries: map(),
          observations: map(),
          artifacts: [ArtifactReference.t()],
          transcript: map(),
          completeness: map(),
          harness_snapshot: map(),
          requests: [map()],
          extensions: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :created_at,
    :correlations,
    :model,
    :outcome,
    :stop_reason,
    :timing,
    :usage,
    :cost,
    :cache,
    :retries,
    :observations,
    :artifacts,
    :transcript,
    :completeness,
    :harness_snapshot,
    :requests,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            created_at: nil,
            correlations: %{},
            provider: nil,
            model: nil,
            outcome: nil,
            stop_reason: nil,
            timing: %{},
            usage: %{},
            cost: %{},
            cache: %{},
            retries: %{},
            observations: %{},
            artifacts: [],
            transcript: %{},
            completeness: %{},
            harness_snapshot: %{},
            requests: [],
            extensions: %{}

  @doc "Builds a terminal run manifest from its JSON-shaped facts."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- required_strings(attrs),
         :ok <- outcome(attrs["outcome"]),
         :ok <- maps(attrs),
         {:ok, created_at} <- parse_time(attrs["created_at"]),
         {:ok, artifacts} <- artifact_references(attrs["artifacts"]),
         :ok <- transcript_reference(attrs["transcript"], artifacts),
         :ok <- completeness(attrs["completeness"]),
         :ok <- harness_reference(attrs["harness_snapshot"]),
         :ok <- validate_request_references(attrs["requests"]) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "created_at" => DateTime.to_iso8601(created_at),
        "correlations" => attrs["correlations"],
        "provider" => attrs["provider"],
        "model" => attrs["model"],
        "outcome" => attrs["outcome"],
        "stop_reason" => attrs["stop_reason"],
        "timing" => attrs["timing"],
        "usage" => attrs["usage"],
        "cost" => attrs["cost"],
        "cache" => attrs["cache"],
        "retries" => attrs["retries"],
        "observations" => attrs["observations"],
        "artifacts" => Enum.map(artifacts, &ArtifactReference.to_map/1),
        "transcript" => attrs["transcript"],
        "completeness" => attrs["completeness"],
        "harness_snapshot" => attrs["harness_snapshot"],
        "requests" => attrs["requests"],
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok, from_verified_map(Map.put(base, "sha256", sha256), artifacts, created_at)}
      else
        {:error, :digest_mismatch}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_run_evidence}

  @doc "Builds terminal evidence from the immutable entries belonging to one run."
  @spec from_entries(entries :: [Entry.t()], attrs :: map()) :: {:ok, t()} | {:error, term()}
  def from_entries(entries, attrs) when is_list(entries) and is_map(attrs) do
    snapshot = Map.get(attrs, :harness_snapshot, Map.get(attrs, "harness_snapshot"))

    with :ok <- verify_snapshot(snapshot) do
      attrs = Contract.json(attrs)
      transcript_bytes = Enum.map_join(entries, "\n", &Entry.encode!/1)
      scope = Map.get(attrs, "scope", %{})

      transcript =
        ArtifactReference.from_bytes("transcript", transcript_bytes,
          id: "transcript_" <> Map.fetch!(attrs, "id"),
          media_type: "application/x-ndjson",
          content_schema: "lemieux-transcript/v2",
          scope: scope,
          locator: Map.get(attrs, "transcript_locator")
        )

      usages = request_usages(entries)
      usage = usage_fact(usages)
      cost = cost_fact(usages, entries)
      artifacts = [transcript | Map.get(attrs, "artifacts", [])]
      snapshot = Map.fetch!(attrs, "harness_snapshot")

      evidence_attrs = %{
        "id" => Map.fetch!(attrs, "id"),
        "created_at" => Map.get(attrs, "created_at", DateTime.to_iso8601(DateTime.utc_now())),
        "correlations" => Map.fetch!(attrs, "correlations"),
        "provider" => Map.get(attrs, "provider", ModelSpec.provider(Map.fetch!(attrs, "model"))),
        "model" => Map.fetch!(attrs, "model"),
        "outcome" => terminal_outcome(Map.fetch!(attrs, "stop_reason")),
        "stop_reason" => normalize_stop_reason(Map.fetch!(attrs, "stop_reason")),
        "timing" => %{
          "latency_ms" => Map.get(attrs, "latency_ms"),
          "state" => if(is_integer(Map.get(attrs, "latency_ms")), do: "complete", else: "unknown")
        },
        "usage" => usage,
        "cost" => cost,
        "cache" => cache_fact(usages),
        "retries" => Map.get(attrs, "retries", %{"state" => "unknown", "count" => nil}),
        "observations" => observations(entries, Map.get(attrs, "hook_outcomes", [])),
        "artifacts" => Enum.map(artifacts, &artifact_map/1),
        "transcript" => transcript_range(entries, transcript.id),
        "completeness" => %{
          "usage" => usage["state"],
          "cost" => cost["state"],
          "sandbox" => Map.get(attrs, "sandbox_completeness", "unknown"),
          "artifacts" => "complete"
        },
        "harness_snapshot" => snapshot_reference(snapshot),
        "requests" => request_references(entries),
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      new(evidence_attrs)
    end
  rescue
    error in KeyError -> {:error, {:missing_field, error.key}}
  end

  @doc "Returns the JSON-shaped run manifest."
  @spec to_map(run :: t()) :: map()
  def to_map(%__MODULE__{} = run) do
    %{
      "schema_version" => run.schema_version,
      "id" => run.id,
      "sha256" => run.sha256,
      "created_at" => DateTime.to_iso8601(run.created_at),
      "correlations" => run.correlations,
      "provider" => run.provider,
      "model" => run.model,
      "outcome" => run.outcome,
      "stop_reason" => run.stop_reason,
      "timing" => run.timing,
      "usage" => run.usage,
      "cost" => run.cost,
      "cache" => run.cache,
      "retries" => run.retries,
      "observations" => run.observations,
      "artifacts" => Enum.map(run.artifacts, &ArtifactReference.to_map/1),
      "transcript" => run.transcript,
      "completeness" => run.completeness,
      "harness_snapshot" => run.harness_snapshot,
      "requests" => run.requests,
      "extensions" => run.extensions
    }
  end

  @doc "Encodes the canonical run manifest."
  @spec encode!(run :: t()) :: String.t()
  def encode!(%__MODULE__{} = run), do: run |> to_map() |> Contract.encode!()

  @doc "Decodes and verifies a run manifest."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- verify(map) do
      new(map)
    end
  end

  @doc "Checks the current schema and complete manifest digest."
  @spec verify(run_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = run), do: run |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_run_evidence}

  defp required_strings(attrs) do
    Enum.reduce_while(~w(id model outcome stop_reason created_at), :ok, fn field, :ok ->
      case attrs[field] do
        value when is_binary(value) and value != "" -> {:cont, :ok}
        _invalid -> {:halt, {:error, {:invalid_field, field}}}
      end
    end)
  end

  defp outcome(value) when value in @outcomes, do: :ok
  defp outcome(value), do: {:error, {:invalid_outcome, value}}

  defp maps(attrs) do
    fields =
      ~w(correlations timing usage cost cache retries observations transcript completeness harness_snapshot)

    case Enum.find(fields, &(not is_map(attrs[&1]))) do
      nil ->
        if(is_list(attrs["artifacts"]) and is_list(attrs["requests"]),
          do: :ok,
          else: {:error, :invalid_references}
        )

      field ->
        {:error, {:invalid_field, field}}
    end
  end

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_created_at}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_created_at}

  defp artifact_references(references) do
    Enum.reduce_while(references, {:ok, []}, fn reference, {:ok, built} ->
      case ArtifactReference.from_map(reference) do
        {:ok, value} -> {:cont, {:ok, [value | built]}}
        {:error, reason} -> {:halt, {:error, {:invalid_artifact_reference, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp completeness(value) do
    case Enum.find(value, fn {_name, state} -> state not in @completeness end) do
      nil -> :ok
      {name, state} -> {:error, {:invalid_completeness, name, state}}
    end
  end

  defp transcript_reference(
         %{
           "artifact_id" => artifact_id,
           "entry_count" => count,
           "entry_ids" => entry_ids,
           "first_entry_id" => first_id,
           "last_entry_id" => last_id,
           "first_seq" => first_seq,
           "last_seq" => last_seq,
           "sequences" => sequences,
           "encoding" => "jsonl-no-trailing-newline"
         },
         artifacts
       )
       when is_binary(artifact_id) and is_integer(count) and count >= 0 do
    with true <- Enum.any?(artifacts, &(&1.id == artifact_id and &1.kind == "transcript")),
         true <-
           valid_transcript_bounds?(
             count,
             entry_ids,
             sequences,
             first_id,
             last_id,
             first_seq,
             last_seq
           ) do
      :ok
    else
      false -> {:error, :invalid_transcript_reference}
    end
  end

  defp transcript_reference(_reference, _artifacts),
    do: {:error, :invalid_transcript_reference}

  defp valid_transcript_bounds?(0, [], [], nil, nil, nil, nil), do: true

  defp valid_transcript_bounds?(
         count,
         entry_ids,
         sequences,
         first_id,
         last_id,
         first_seq,
         last_seq
       ) do
    count > 0 and valid_entry_ids?(entry_ids, count, first_id, last_id) and
      valid_sequences?(sequences, count, first_seq, last_seq)
  end

  defp valid_entry_ids?(entry_ids, count, first_id, last_id) when is_list(entry_ids) do
    length(entry_ids) == count and Enum.all?(entry_ids, &valid_entry_id?/1) and
      first_id == List.first(entry_ids) and last_id == List.last(entry_ids)
  end

  defp valid_entry_ids?(_entry_ids, _count, _first_id, _last_id), do: false

  defp valid_entry_id?(entry_id), do: is_binary(entry_id) and entry_id != ""

  defp valid_sequences?(sequences, count, first_seq, last_seq) when is_list(sequences) do
    length(sequences) == count and Enum.all?(sequences, &valid_sequence?/1) and
      first_seq == List.first(sequences) and last_seq == List.last(sequences)
  end

  defp valid_sequences?(_sequences, _count, _first_seq, _last_seq), do: false

  defp valid_sequence?(sequence), do: is_integer(sequence) and sequence >= 0

  defp harness_reference(%{
         "id" => id,
         "semantic_sha256" => semantic,
         "manifest_sha256" => manifest
       })
       when is_binary(id) and byte_size(semantic) == 64 and byte_size(manifest) == 64,
       do: :ok

  defp harness_reference(_reference), do: {:error, :invalid_harness_snapshot_reference}

  defp validate_request_references(references) when is_list(references) do
    if Enum.all?(references, fn
         %{"id" => id, "sha256" => digest, "harness_snapshot_sha256" => harness}
         when is_binary(id) and byte_size(digest) == 64 and byte_size(harness) == 64 ->
           true

         _invalid ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_request_reference}
  end

  defp request_usages(entries) do
    responses =
      Enum.filter(entries, fn
        %Entry{type: type} when type in [:assistant, :compaction, :guidance] -> true
        _entry -> false
      end)

    response_ids = responses |> Enum.map(& &1.payload["request_id"]) |> MapSet.new()

    # A failed request can end in an error without an assistant entry. It must
    # still make usage, cache, and cost incomplete: earlier measured replies
    # cannot establish the total for an unanswered request.
    unanswered =
      Enum.count(entries, fn
        %Entry{type: :request, payload: %{"id" => id}} -> not MapSet.member?(response_ids, id)
        _entry -> false
      end)

    Enum.map(responses, & &1.usage) ++ List.duplicate(nil, unanswered)
  end

  defp usage_fact([]), do: %{"state" => "unknown", "value" => nil, "reason" => "not_reported"}

  defp usage_fact(usages) do
    known = Enum.reject(usages, &is_nil/1)

    if length(known) == length(usages) do
      %{"state" => "complete", "value" => Usage.sum(known), "reason" => nil}
    else
      %{
        "state" => if(known == [], do: "unknown", else: "partial"),
        "value" => nil,
        "observed" => if(known == [], do: nil, else: Usage.sum(known)),
        "reason" => "one_or_more_requests_missing_usage"
      }
    end
  end

  defp cost_fact(usages, entries) do
    request_costs = Enum.map(usages, &request_cost/1)
    tool_costs = Enum.flat_map(entries, &tool_cost/1)
    costs = request_costs ++ tool_costs

    cond do
      costs == [] ->
        %{"state" => "unknown", "usd" => nil, "reason" => "not_reported"}

      Enum.any?(costs, &is_nil/1) ->
        %{"state" => "unknown", "usd" => nil, "reason" => "price_missing"}

      true ->
        %{"state" => "complete", "usd" => Enum.sum(costs), "reason" => nil}
    end
  end

  defp request_cost(nil), do: nil
  defp request_cost(usage), do: Usage.cost_usd(usage)

  defp tool_cost(%Entry{type: :tool_result, payload: payload}) do
    case get_in(payload, ["cost", "usd"]) do
      value when is_number(value) and value >= 0 -> [value]
      nil -> []
      _unknown -> [nil]
    end
  end

  defp tool_cost(_entry), do: []

  defp cache_fact(usages) do
    if usages != [] and Enum.all?(usages, &is_map/1) do
      value = Usage.sum(usages)

      %{
        "state" => "complete",
        "read_tokens" => value["cache_read_tokens"],
        "write_tokens" => value["cache_write_tokens"]
      }
    else
      %{"state" => "unknown", "read_tokens" => nil, "write_tokens" => nil}
    end
  end

  defp observations(entries, hook_outcomes) do
    %{
      "tool_outcomes" => Enum.flat_map(entries, &tool_outcome/1),
      "approvals" => Enum.flat_map(entries, &approval/1),
      "hook_outcomes" => hook_outcomes,
      "compactions" => Enum.count(entries, &(&1.type == :compaction)),
      "cancellations" => Enum.count(entries, &(&1.type == :cancelled)),
      "errors" => Enum.flat_map(entries, &error_observation/1)
    }
  end

  defp tool_outcome(%Entry{type: :tool_result, payload: payload}) do
    [
      Map.take(
        payload,
        ~w(call_id name outcome error duration_ms descriptor_digest tool_identity hook_rewritten)
      )
    ]
  end

  defp tool_outcome(_entry), do: []

  defp approval(%Entry{type: :approval, payload: payload}) do
    [Map.take(payload, ~w(call_id kind status))]
  end

  defp approval(_entry), do: []

  defp error_observation(%Entry{type: :error} = entry),
    do: [%{"entry_id" => entry.id, "category" => "runtime"}]

  defp error_observation(_entry), do: []

  defp artifact_map(%ArtifactReference{} = reference), do: ArtifactReference.to_map(reference)
  defp artifact_map(reference) when is_map(reference), do: Contract.json(reference)

  defp snapshot_reference(%Snapshot{} = snapshot) do
    %{
      "id" => snapshot.id,
      "semantic_sha256" => snapshot.semantic_sha256,
      "manifest_sha256" => snapshot.manifest_sha256
    }
  end

  defp snapshot_reference(reference) when is_map(reference) do
    Map.take(reference, ~w(id semantic_sha256 manifest_sha256))
  end

  defp verify_snapshot(%Snapshot{} = snapshot), do: Snapshot.verify(snapshot)
  defp verify_snapshot(reference) when is_map(reference), do: harness_reference(reference)
  defp verify_snapshot(nil), do: {:error, {:missing_field, "harness_snapshot"}}
  defp verify_snapshot(_reference), do: {:error, :invalid_harness_snapshot_reference}

  defp request_references(entries) do
    Enum.flat_map(entries, fn
      %Entry{type: :request, payload: payload} ->
        [
          %{
            "id" => payload["id"],
            "sha256" => payload["sha256"],
            "harness_snapshot_id" => payload["harness_snapshot_id"],
            "harness_snapshot_sha256" => payload["harness_snapshot_sha256"]
          }
        ]

      _entry ->
        []
    end)
  end

  defp transcript_range([], artifact_id) do
    %{
      "artifact_id" => artifact_id,
      "entry_count" => 0,
      "entry_ids" => [],
      "first_entry_id" => nil,
      "last_entry_id" => nil,
      "first_seq" => nil,
      "last_seq" => nil,
      "sequences" => [],
      "encoding" => "jsonl-no-trailing-newline"
    }
  end

  defp transcript_range(entries, artifact_id) do
    first = List.first(entries)
    last = List.last(entries)

    %{
      "artifact_id" => artifact_id,
      "entry_count" => length(entries),
      "entry_ids" => Enum.map(entries, & &1.id),
      "first_entry_id" => first.id,
      "last_entry_id" => last.id,
      "first_seq" => first.seq,
      "last_seq" => last.seq,
      "sequences" => Enum.map(entries, & &1.seq),
      "encoding" => "jsonl-no-trailing-newline"
    }
  end

  defp terminal_outcome(reason) when reason in [:stop, "stop"], do: "succeeded"
  defp terminal_outcome(reason) when reason in [:cancelled, "cancelled"], do: "canceled"

  defp terminal_outcome(reason) when reason in [:timeout, :timed_out, "timeout", "timed_out"],
    do: "timed_out"

  defp terminal_outcome({:budget, _payload}), do: "budget_stopped"
  defp terminal_outcome(["budget", _payload]), do: "budget_stopped"
  defp terminal_outcome("budget"), do: "budget_stopped"

  defp terminal_outcome(reason) when reason in [:error, :hook_failed, "error", "hook_failed"],
    do: "failed"

  defp terminal_outcome(_reason), do: "stopped"

  defp normalize_stop_reason({reason, _payload}) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_stop_reason([reason, _payload]) when is_binary(reason), do: reason
  defp normalize_stop_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_stop_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp normalize_stop_reason(_reason), do: "other"

  defp from_verified_map(map, artifacts, created_at) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      created_at: created_at,
      correlations: map["correlations"],
      provider: map["provider"],
      model: map["model"],
      outcome: map["outcome"],
      stop_reason: map["stop_reason"],
      timing: map["timing"],
      usage: map["usage"],
      cost: map["cost"],
      cache: map["cache"],
      retries: map["retries"],
      observations: map["observations"],
      artifacts: artifacts,
      transcript: map["transcript"],
      completeness: map["completeness"],
      harness_snapshot: map["harness_snapshot"],
      requests: map["requests"],
      extensions: map["extensions"]
    }
  end
end
