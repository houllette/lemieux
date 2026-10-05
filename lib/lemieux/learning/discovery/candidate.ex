defmodule Lemieux.Learning.Discovery.Candidate do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  An immutable exploratory candidate with content-addressed lineage.

  A candidate is never active and carries no activation capability. Parents
  refer to immutable content digests, while the candidate's own manifest
  digest covers proposer, rationale, interface result, and exposure evidence.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Plan

  @version 1
  @interface_statuses ~w(passed failed)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          created_at: DateTime.t(),
          plan_id: String.t(),
          plan_sha256: String.t(),
          scope: map(),
          parents: [map()],
          content: ArtifactReference.t(),
          proposer: map(),
          rationale: ArtifactReference.t(),
          interface_validation: map(),
          exposures: [map()],
          mutation_kind: String.t(),
          extensions: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :created_at,
    :plan_id,
    :plan_sha256,
    :scope,
    :parents,
    :content,
    :proposer,
    :rationale,
    :interface_validation,
    :exposures,
    :mutation_kind,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            created_at: nil,
            plan_id: nil,
            plan_sha256: nil,
            scope: %{},
            parents: [],
            content: nil,
            proposer: %{},
            rationale: nil,
            interface_validation: %{},
            exposures: [],
            mutation_kind: nil,
            extensions: %{}

  @doc "Builds a candidate under a frozen discovery plan."
  @spec new(plan :: Plan.t(), attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(%Plan{} = plan, attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)
    scope = plan.scope

    with :ok <- nonempty(attrs["id"], "id"),
         ^scope <- attrs["scope"],
         :ok <- parents(attrs["parents"]),
         {:ok, content} <- ArtifactReference.from_map(attrs["content"]),
         ^scope <- content.scope,
         :ok <- proposer(attrs["proposer"], plan.proposer),
         {:ok, rationale} <- ArtifactReference.from_map(attrs["rationale"]),
         ^scope <- rationale.scope,
         :ok <- interface_validation(attrs["interface_validation"], plan),
         :ok <- exposures(attrs["exposures"]),
         :ok <- nonempty(attrs["mutation_kind"], "mutation_kind"),
         {:ok, created_at} <- parse_time(Map.get(attrs, "created_at", now())) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "created_at" => DateTime.to_iso8601(created_at),
        "plan_id" => plan.id,
        "plan_sha256" => plan.sha256,
        "scope" => plan.scope,
        "parents" => attrs["parents"],
        "content" => ArtifactReference.to_map(content),
        "proposer" => attrs["proposer"],
        "rationale" => ArtifactReference.to_map(rationale),
        "interface_validation" => attrs["interface_validation"],
        "exposures" => attrs["exposures"],
        "mutation_kind" => attrs["mutation_kind"],
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok, from_verified_map(Map.put(base, "sha256", sha256), content, rationale, created_at)}
      else
        {:error, :digest_mismatch}
      end
    else
      mismatch when is_map(mismatch) -> {:error, :candidate_scope_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the immutable content digest selected for execution."
  @spec content_sha256(candidate :: t()) :: String.t()
  def content_sha256(%__MODULE__{} = candidate), do: candidate.content.sha256

  @doc "Validates acyclic candidate lineage and every parent content digest."
  @spec verify_lineage(candidates :: [t()], seeds :: [map()]) :: :ok | {:error, term()}
  def verify_lineage(candidates, seeds) when is_list(candidates) and is_list(seeds) do
    candidate_index = Map.new(candidates, &{&1.id, &1})
    seed_index = Map.new(seeds, &{&1["id"], &1["content_sha256"] || &1["sha256"]})

    with :ok <- unique_lineage_ids(candidate_index, candidates, seed_index, seeds) do
      candidates
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce_while(
        {:ok, %{}},
        &visit_candidate(&1, &2, candidate_index, seed_index)
      )
      |> lineage_result()
    end
  end

  @doc "Returns the JSON-shaped candidate."
  @spec to_map(candidate :: t()) :: map()
  def to_map(%__MODULE__{} = candidate) do
    %{
      "schema_version" => candidate.schema_version,
      "id" => candidate.id,
      "sha256" => candidate.sha256,
      "created_at" => DateTime.to_iso8601(candidate.created_at),
      "plan_id" => candidate.plan_id,
      "plan_sha256" => candidate.plan_sha256,
      "scope" => candidate.scope,
      "parents" => candidate.parents,
      "content" => ArtifactReference.to_map(candidate.content),
      "proposer" => candidate.proposer,
      "rationale" => ArtifactReference.to_map(candidate.rationale),
      "interface_validation" => candidate.interface_validation,
      "exposures" => candidate.exposures,
      "mutation_kind" => candidate.mutation_kind,
      "extensions" => candidate.extensions
    }
  end

  @doc "Encodes a canonical candidate manifest."
  @spec encode!(candidate :: t()) :: String.t()
  def encode!(%__MODULE__{} = candidate), do: candidate |> to_map() |> Contract.encode!()

  @doc "Decodes a candidate only under the exact frozen plan it names."
  @spec decode(plan :: Plan.t(), json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(%Plan{} = plan, json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         true <- map["plan_id"] == plan.id and map["plan_sha256"] == plan.sha256,
         :ok <- verify(map),
         {:ok, candidate} <- new(plan, map) do
      {:ok, candidate}
    else
      false -> {:error, :candidate_plan_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Verifies version and manifest digest."
  @spec verify(candidate_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = candidate), do: candidate |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_candidate}

  defp unique_lineage_ids(candidate_index, candidates, seed_index, seeds) do
    cond do
      map_size(candidate_index) != length(candidates) -> {:error, :duplicate_candidate_id}
      map_size(seed_index) != length(seeds) -> {:error, :duplicate_seed_id}
      true -> :ok
    end
  end

  defp visit_candidate(candidate, {:ok, complete}, index, seeds) do
    candidate
    |> visit(index, seeds, complete, %{})
    |> reduce_result()
  end

  defp lineage_result({:ok, _complete}), do: :ok
  defp lineage_result({:error, reason}), do: {:error, reason}

  defp visit(candidate, index, seeds, complete, active) do
    case visit_status(candidate.id, complete, active) do
      :complete ->
        {:ok, complete}

      :cycle ->
        {:error, {:candidate_lineage_cycle, candidate.id}}

      :visit ->
        visit_parents(candidate, index, seeds, complete, Map.put(active, candidate.id, true))
    end
  end

  defp visit_status(id, complete, active) do
    cond do
      Map.has_key?(complete, id) -> :complete
      Map.has_key?(active, id) -> :cycle
      true -> :visit
    end
  end

  defp visit_parents(candidate, index, seeds, complete, active) do
    candidate.parents
    |> Enum.reduce_while({:ok, complete}, fn parent, {:ok, done} ->
      parent
      |> parent_target(index, seeds)
      |> resolve_parent(parent, index, seeds, done, active)
      |> reduce_result()
    end)
    |> complete_visit(candidate.id)
  end

  defp resolve_parent({:candidate, candidate}, parent, index, seeds, done, active) do
    if parent["content_sha256"] == content_sha256(candidate),
      do: visit(candidate, index, seeds, done, active),
      else: {:error, {:parent_digest_mismatch, parent["id"]}}
  end

  defp resolve_parent({:seed, digest}, parent, _index, _seeds, done, _active) do
    if digest == parent["content_sha256"],
      do: {:ok, done},
      else: {:error, {:parent_digest_mismatch, parent["id"]}}
  end

  defp resolve_parent(:missing, parent, _index, _seeds, _done, _active),
    do: {:error, {:unresolved_parent, parent["id"]}}

  defp reduce_result({:ok, value}), do: {:cont, {:ok, value}}
  defp reduce_result({:error, reason}), do: {:halt, {:error, reason}}

  defp complete_visit({:ok, done}, id), do: {:ok, Map.put(done, id, true)}
  defp complete_visit({:error, reason}, _id), do: {:error, reason}

  defp parent_target(parent, index, seeds) do
    case Map.fetch(index, parent["id"]) do
      {:ok, candidate} ->
        {:candidate, candidate}

      :error ->
        case Map.fetch(seeds, parent["id"]) do
          {:ok, digest} -> {:seed, digest}
          :error -> :missing
        end
    end
  end

  defp parents(value) when is_list(value) do
    if Enum.all?(value, fn
         %{"id" => id, "content_sha256" => digest}
         when is_binary(id) and id != "" and is_binary(digest) and byte_size(digest) == 64 ->
           true

         _invalid ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_candidate_parents}
  end

  defp parents(_value), do: {:error, :invalid_candidate_parents}

  defp immutable_config(%{"id" => id, "sha256" => sha256})
       when is_binary(id) and id != "" and is_binary(sha256) and byte_size(sha256) == 64,
       do: :ok

  defp immutable_config(_value), do: {:error, :invalid_candidate_proposer}

  defp proposer(config, config), do: immutable_config(config)
  defp proposer(_config, _plan_config), do: {:error, :candidate_proposer_mismatch}

  defp interface_validation(
         %{"status" => status, "validator_sha256" => sha256},
         %Plan{interface_validator: %{"sha256" => sha256}}
       )
       when status in @interface_statuses,
       do: :ok

  defp interface_validation(_value, _plan), do: {:error, :invalid_interface_validation}

  defp exposures(value) when is_list(value) do
    if Enum.any?(value, &contains_holdout?/1),
      do: {:error, :holdout_exposure_forbidden},
      else: :ok
  end

  defp exposures(_value), do: {:error, :invalid_candidate_exposures}

  defp contains_holdout?(value) when is_map(value) do
    Enum.any?(value, fn {key, item} ->
      String.contains?(String.downcase(key), "holdout") or contains_holdout?(item)
    end)
  end

  defp contains_holdout?(value) when is_list(value), do: Enum.any?(value, &contains_holdout?/1)

  defp contains_holdout?(value) when is_binary(value),
    do: String.contains?(String.downcase(value), "holdout")

  defp contains_holdout?(_value), do: false

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_candidate_field, field}}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_created_at}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_created_at}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp from_verified_map(map, content, rationale, created_at) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      created_at: created_at,
      plan_id: map["plan_id"],
      plan_sha256: map["plan_sha256"],
      scope: map["scope"],
      parents: map["parents"],
      content: content,
      proposer: map["proposer"],
      rationale: rationale,
      interface_validation: map["interface_validation"],
      exposures: map["exposures"],
      mutation_kind: map["mutation_kind"],
      extensions: map["extensions"]
    }
  end
end
