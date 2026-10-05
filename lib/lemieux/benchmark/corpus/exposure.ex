defmodule Lemieux.Benchmark.Corpus.Exposure do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A versioned record of direct or derived case exposure.

  It carries only identifiers and digests. Case prompts, fixtures, graders,
  and secret membership never enter the encoding, so a host can commit the
  closure before granting a consumer access without revealing case content.
  """

  alias Lemieux.Contract

  @version 2

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          consumer_role: String.t(),
          consumer_id: String.t(),
          lineage_id: String.t() | nil,
          model: String.t() | nil,
          context_digest: String.t() | nil,
          experiment_id: String.t() | nil,
          direct_case_ids: [String.t()],
          derived_artifact_ids: [String.t()],
          source_case_ids: [String.t()],
          at: DateTime.t()
        }

  @enforce_keys [
    :id,
    :sha256,
    :consumer_role,
    :consumer_id,
    :direct_case_ids,
    :derived_artifact_ids,
    :source_case_ids,
    :at
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            consumer_role: nil,
            consumer_id: nil,
            lineage_id: nil,
            model: nil,
            context_digest: nil,
            experiment_id: nil,
            direct_case_ids: [],
            derived_artifact_ids: [],
            source_case_ids: [],
            at: nil

  @doc "Builds an exposure record with sorted, unique closure ids."
  @spec new(attrs :: map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)

    with :ok <- nonempty(attrs["id"], "id"),
         :ok <- nonempty(attrs["consumer_role"], "consumer_role"),
         :ok <- nonempty(attrs["consumer_id"], "consumer_id"),
         :ok <- ids(attrs["direct_case_ids"], "direct_case_ids"),
         :ok <- ids(attrs["derived_artifact_ids"], "derived_artifact_ids"),
         :ok <- ids(attrs["source_case_ids"], "source_case_ids"),
         {:ok, at} <- parse_time(Map.get(attrs, "at", DateTime.to_iso8601(DateTime.utc_now()))) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "consumer_role" => attrs["consumer_role"],
        "consumer_id" => attrs["consumer_id"],
        "lineage_id" => attrs["lineage_id"],
        "model" => attrs["model"],
        "context_digest" => attrs["context_digest"],
        "experiment_id" => attrs["experiment_id"],
        "direct_case_ids" => normalize_ids(attrs["direct_case_ids"]),
        "derived_artifact_ids" => normalize_ids(attrs["derived_artifact_ids"]),
        "source_case_ids" => normalize_ids(attrs["source_case_ids"]),
        "at" => DateTime.to_iso8601(at)
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok,
         %__MODULE__{
           id: base["id"],
           sha256: sha256,
           consumer_role: base["consumer_role"],
           consumer_id: base["consumer_id"],
           lineage_id: base["lineage_id"],
           model: base["model"],
           context_digest: base["context_digest"],
           experiment_id: base["experiment_id"],
           direct_case_ids: base["direct_case_ids"],
           derived_artifact_ids: base["derived_artifact_ids"],
           source_case_ids: base["source_case_ids"],
           at: at
         }}
      else
        {:error, :digest_mismatch}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_exposure}

  @doc "Returns the content-free wire representation."
  @spec to_map(exposure :: t()) :: map()
  def to_map(%__MODULE__{} = exposure) do
    %{
      "schema_version" => exposure.schema_version,
      "id" => exposure.id,
      "sha256" => exposure.sha256,
      "consumer_role" => exposure.consumer_role,
      "consumer_id" => exposure.consumer_id,
      "lineage_id" => exposure.lineage_id,
      "model" => exposure.model,
      "context_digest" => exposure.context_digest,
      "experiment_id" => exposure.experiment_id,
      "direct_case_ids" => exposure.direct_case_ids,
      "derived_artifact_ids" => exposure.derived_artifact_ids,
      "source_case_ids" => exposure.source_case_ids,
      "at" => DateTime.to_iso8601(exposure.at)
    }
  end

  @doc "Encodes an exposure record."
  @spec encode!(exposure :: t()) :: String.t()
  def encode!(%__MODULE__{} = exposure), do: exposure |> to_map() |> Contract.encode!()

  @doc "Decodes and verifies an exposure record."
  @spec decode(json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         :ok <- Contract.verify_digest(map, "sha256") do
      new(map)
    end
  end

  @doc "Verifies the schema and digest without decoding again."
  @spec verify(exposure_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = exposure), do: exposure |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_exposure}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_exposure_field, field}}

  defp ids(values, _field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, :invalid_exposure_ids}
  end

  defp ids(_values, field), do: {:error, {:invalid_exposure_field, field}}

  defp normalize_ids(ids), do: ids |> Enum.uniq() |> Enum.sort()

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_exposure_timestamp}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_exposure_timestamp}
end
