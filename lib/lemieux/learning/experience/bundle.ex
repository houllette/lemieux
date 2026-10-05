defmodule Lemieux.Learning.Experience.Bundle do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A versioned manifest over caller-authorized discovery experience.

  Raw evidence and derived findings are separate collections. Every item and
  artifact repeats the bundle scope so a copied reference from another tenant
  cannot become valid merely by being inserted into a new outer manifest.
  Hidden or forbidden exposure labels invalidate the whole bundle.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference

  @version 1
  @collections ~w(seeds candidates evaluations raw derived exposures artifacts)
  @forbidden_labels ~w(holdout hidden secret forbidden)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          scope: map(),
          plan: map(),
          seeds: [map()],
          candidates: [map()],
          evaluations: [map()],
          raw: [map()],
          derived: [map()],
          exposures: [map()],
          artifacts: [map()],
          frontier: map(),
          extensions: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :scope,
    :plan,
    :seeds,
    :candidates,
    :evaluations,
    :raw,
    :derived,
    :exposures,
    :artifacts,
    :frontier,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            scope: %{},
            plan: %{},
            seeds: [],
            candidates: [],
            evaluations: [],
            raw: [],
            derived: [],
            exposures: [],
            artifacts: [],
            frontier: %{},
            extensions: %{}

  @doc "Builds a complete, scope-consistent experience bundle."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- nonempty(attrs["id"], "id"),
         :ok <- valid_scope(attrs["scope"]),
         :ok <- plan(attrs["plan"], attrs["scope"]),
         :ok <- collections(attrs),
         :ok <- scoped_collections(attrs, attrs["scope"]),
         :ok <- derived_sources(attrs["derived"]),
         :ok <- allowed_exposure(attrs),
         :ok <- artifact_descriptors(attrs["artifacts"], attrs["scope"]) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "scope" => attrs["scope"],
        "plan" => attrs["plan"],
        "seeds" => attrs["seeds"],
        "candidates" => attrs["candidates"],
        "evaluations" => attrs["evaluations"],
        "raw" => attrs["raw"],
        "derived" => attrs["derived"],
        "exposures" => attrs["exposures"],
        "artifacts" => attrs["artifacts"],
        "frontier" => Map.get(attrs, "frontier", %{}),
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok, from_verified_map(Map.put(base, "sha256", sha256))}
      else
        {:error, :digest_mismatch}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_experience_bundle}

  @doc "Returns the JSON-shaped bundle."
  @spec to_map(bundle :: t()) :: map()
  def to_map(%__MODULE__{} = bundle) do
    %{
      "schema_version" => bundle.schema_version,
      "id" => bundle.id,
      "sha256" => bundle.sha256,
      "scope" => bundle.scope,
      "plan" => bundle.plan,
      "seeds" => bundle.seeds,
      "candidates" => bundle.candidates,
      "evaluations" => bundle.evaluations,
      "raw" => bundle.raw,
      "derived" => bundle.derived,
      "exposures" => bundle.exposures,
      "artifacts" => bundle.artifacts,
      "frontier" => bundle.frontier,
      "extensions" => bundle.extensions
    }
  end

  @doc "Encodes the canonical bundle manifest."
  @spec encode!(bundle :: t()) :: String.t()
  def encode!(%__MODULE__{} = bundle), do: bundle |> to_map() |> Contract.encode!()

  @doc "Decodes and verifies a bundle."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- verify(map) do
      new(map)
    end
  end

  @doc "Verifies the current schema and complete manifest digest."
  @spec verify(bundle_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = bundle), do: bundle |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_experience_bundle}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_bundle_field, field}}

  defp valid_scope(%{"id" => id}) when is_binary(id) and id != "", do: :ok
  defp valid_scope(_scope), do: {:error, :invalid_bundle_scope}

  defp plan(%{"id" => id, "sha256" => sha256, "scope" => scope}, scope)
       when is_binary(id) and id != "" and is_binary(sha256) and byte_size(sha256) == 64,
       do: :ok

  defp plan(_plan, _scope), do: {:error, :invalid_bundle_plan}

  defp collections(attrs) do
    case Enum.find(@collections, &(not is_list(attrs[&1]))) do
      nil -> :ok
      field -> {:error, {:invalid_bundle_collection, field}}
    end
  end

  defp scoped_collections(attrs, scope) do
    @collections
    |> Enum.reject(&(&1 in ["exposures"]))
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case Enum.find(attrs[name], &(Map.get(&1, "scope") != scope)) do
        nil -> {:cont, :ok}
        item -> {:halt, {:error, {:scope_mismatch, name, Map.get(item, "id")}}}
      end
    end)
  end

  defp derived_sources(derived) do
    case Enum.find(derived, fn item ->
           not is_list(item["source_references"]) or item["source_references"] == []
         end) do
      nil -> :ok
      item -> {:error, {:derived_item_missing_sources, item["id"]}}
    end
  end

  defp allowed_exposure(attrs) do
    case find_forbidden(attrs) do
      nil -> :ok
      label -> {:error, {:forbidden_exposure, label}}
    end
  end

  defp find_forbidden(value) when is_map(value) do
    Enum.find_value(value, fn {key, item} ->
      key_label = forbidden_label(key)
      key_label || find_forbidden(item)
    end)
  end

  defp find_forbidden(value) when is_list(value), do: Enum.find_value(value, &find_forbidden/1)
  defp find_forbidden(value) when is_binary(value), do: forbidden_label(value)
  defp find_forbidden(_value), do: nil

  defp forbidden_label(value) do
    normalized = String.downcase(value)
    Enum.find(@forbidden_labels, &String.contains?(normalized, &1))
  end

  defp artifact_descriptors(artifacts, scope) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      with path when is_binary(path) and path != "" <- artifact["path"],
           ^scope <- artifact["scope"],
           {:ok, reference} <- ArtifactReference.from_map(artifact["reference"]),
           ^scope <- reference.scope do
        {:cont, :ok}
      else
        _invalid -> {:halt, {:error, {:invalid_bundle_artifact, artifact["id"]}}}
      end
    end)
  end

  defp from_verified_map(map) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      scope: map["scope"],
      plan: map["plan"],
      seeds: map["seeds"],
      candidates: map["candidates"],
      evaluations: map["evaluations"],
      raw: map["raw"],
      derived: map["derived"],
      exposures: map["exposures"],
      artifacts: map["artifacts"],
      frontier: map["frontier"],
      extensions: map["extensions"]
    }
  end
end
