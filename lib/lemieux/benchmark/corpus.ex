defmodule Lemieux.Benchmark.Corpus do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Versioned corpus membership and case-exposure history.

  Hidden is a statement about access history, not a label somebody may add
  after optimization. Once a model/context has seen a case through this
  registry, `assign/3` refuses to relabel it as a holdout. Hosts keep secret
  case material behind their own callback; this struct holds only public ids,
  membership and audit metadata.
  """

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Manifest

  @version 2
  @splits [:development, :validation, :holdout]

  @type split :: :development | :validation | :holdout
  @type exposure :: Exposure.t()
  @type t :: %__MODULE__{
          version: pos_integer(),
          manifest: Manifest.t(),
          membership: %{String.t() => split()},
          exposure_history: %{optional(String.t()) => [exposure()]}
        }

  @enforce_keys [:manifest, :membership]
  defstruct version: @version, manifest: nil, membership: %{}, exposure_history: %{}

  @doc "Builds corpus governance metadata for every manifest case."
  @spec new(manifest :: Manifest.t(), membership :: map()) :: {:ok, t()} | {:error, term()}
  def new(%Manifest{} = manifest, membership) when is_map(membership) do
    ids = Enum.map(manifest.tasks, & &1.id)
    missing = Enum.reject(ids, &Map.has_key?(membership, &1))
    extras = Map.keys(membership) -- ids

    cond do
      missing != [] ->
        {:error, {:missing_split, missing}}

      extras != [] ->
        {:error, {:unknown_cases, extras}}

      invalid = Enum.find(membership, fn {_id, split} -> split not in @splits end) ->
        {id, split} = invalid
        {:error, {:unknown_split, id, split}}

      true ->
        {:ok, %__MODULE__{manifest: manifest, membership: membership}}
    end
  end

  @doc "Records that case content was exposed to a model/context/experiment."
  @spec expose(corpus :: t(), case_ids :: [String.t()], metadata :: map()) ::
          {:ok, t()} | {:error, term()}
  def expose(%__MODULE__{} = corpus, case_ids, metadata)
      when is_list(case_ids) and is_map(metadata) do
    unknown = Enum.reject(case_ids, &Map.has_key?(corpus.membership, &1))
    metadata = reuse_exposure_time(corpus, metadata)

    with [] <- unknown,
         :ok <- exposure_metadata(metadata),
         {:ok, exposure} <- direct_exposure(case_ids, metadata),
         :ok <- exposure_id_available(corpus, exposure) do
      {:ok, record(corpus, exposure)}
    else
      [_ | _] = unknown -> {:error, {:unknown_cases, unknown}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Records a derived artifact and the complete source-case closure it revealed."
  @spec expose_derived(
          corpus :: t(),
          derivation_ids :: [String.t()],
          derivations :: map(),
          metadata :: map()
        ) :: {:ok, t()} | {:error, term()}
  def expose_derived(%__MODULE__{} = corpus, derivation_ids, derivations, metadata)
      when is_list(derivation_ids) and is_map(derivations) and is_map(metadata) do
    metadata = reuse_exposure_time(corpus, metadata)

    with {:ok, source_case_ids} <- source_closure(derivations, derivation_ids),
         [] <- Enum.reject(source_case_ids, &Map.has_key?(corpus.membership, &1)),
         {:ok, exposure} <- derived_exposure(derivation_ids, source_case_ids, metadata),
         :ok <- exposure_id_available(corpus, exposure) do
      {:ok, record(corpus, exposure)}
    else
      [_ | _] = unknown -> {:error, {:unknown_cases, unknown}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Computes deterministic transitive source-case closure for derived artifacts."
  @spec source_closure(derivations :: map(), roots :: [String.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def source_closure(derivations, roots) when is_map(derivations) and is_list(roots) do
    roots
    |> Enum.sort()
    |> Enum.reduce_while({:ok, MapSet.new(), MapSet.new()}, fn id, {:ok, cases, visited} ->
      case visit_derivation(derivations, id, cases, visited) do
        {:ok, next_cases, next_visited} -> {:cont, {:ok, next_cases, next_visited}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, cases, _visited} -> {:ok, cases |> MapSet.to_list() |> Enum.sort()}
      error -> error
    end
  end

  @doc "Assigns a case to a split, refusing exposed-to-holdout relabeling."
  @spec assign(corpus :: t(), case_id :: String.t(), split :: split()) ::
          {:ok, t()} | {:error, term()}
  def assign(%__MODULE__{} = corpus, case_id, split) when split in @splits do
    cond do
      not Map.has_key?(corpus.membership, case_id) -> {:error, {:unknown_case, case_id}}
      split == :holdout and exposures(corpus, case_id) != [] -> {:error, {:case_exposed, case_id}}
      true -> {:ok, %{corpus | membership: Map.put(corpus.membership, case_id, split)}}
    end
  end

  @doc "Returns manifest tasks in their original order for one split."
  @spec cases(corpus :: t(), split :: split()) :: [Lemieux.Benchmark.Task.t()]
  def cases(%__MODULE__{} = corpus, split) when split in @splits do
    Enum.filter(corpus.manifest.tasks, &(Map.fetch!(corpus.membership, &1.id) == split))
  end

  @doc "Returns the complete exposure history for a case."
  @spec exposures(corpus :: t(), case_id :: String.t()) :: [exposure()]
  def exposures(%__MODULE__{} = corpus, case_id),
    do: Map.get(corpus.exposure_history, case_id, [])

  defp direct_exposure(case_ids, metadata) do
    metadata = atomize_known_metadata(metadata)

    Exposure.new(%{
      id: Map.get(metadata, :exposure_id, "exposure_" <> Lemieux.ID.generate()),
      consumer_role: Map.get(metadata, :consumer_role, "development_evaluator"),
      consumer_id: Map.get(metadata, :consumer_id, Map.get(metadata, :experiment_id)),
      lineage_id: Map.get(metadata, :lineage_id),
      model: Map.get(metadata, :model),
      context_digest: Map.get(metadata, :context_digest),
      experiment_id: Map.get(metadata, :experiment_id),
      direct_case_ids: case_ids,
      derived_artifact_ids: [],
      source_case_ids: case_ids,
      at: exposure_time(metadata)
    })
  end

  defp exposure_metadata(metadata) do
    if has_value?(metadata, :consumer_role) and has_value?(metadata, :consumer_id) do
      :ok
    else
      legacy_exposure_metadata(metadata)
    end
  end

  defp legacy_exposure_metadata(metadata) do
    case Enum.find([:model, :context_digest, :experiment_id], &(not has_value?(metadata, &1))) do
      nil -> :ok
      field -> {:error, {:missing_exposure_field, field}}
    end
  end

  defp derived_exposure(derivation_ids, source_case_ids, metadata) do
    metadata = atomize_known_metadata(metadata)

    Exposure.new(%{
      id: Map.get(metadata, :exposure_id, "exposure_" <> Lemieux.ID.generate()),
      consumer_role: Map.get(metadata, :consumer_role),
      consumer_id: Map.get(metadata, :consumer_id),
      lineage_id: Map.get(metadata, :lineage_id),
      model: Map.get(metadata, :model),
      context_digest: Map.get(metadata, :context_digest),
      experiment_id: Map.get(metadata, :experiment_id),
      direct_case_ids: [],
      derived_artifact_ids: derivation_ids,
      source_case_ids: source_case_ids,
      at: exposure_time(metadata)
    })
  end

  defp record(corpus, exposure) do
    history =
      Enum.reduce(exposure.source_case_ids, corpus.exposure_history, fn id, histories ->
        Map.update(histories, id, [exposure], &append_exposure(&1, exposure))
      end)

    %{corpus | exposure_history: history}
  end

  defp append_exposure(existing, exposure) do
    if Enum.any?(existing, &(&1.id == exposure.id)), do: existing, else: existing ++ [exposure]
  end

  defp exposure_id_available(corpus, exposure) do
    existing =
      corpus.exposure_history
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1.id == exposure.id))

    cond do
      is_nil(existing) -> :ok
      existing.sha256 == exposure.sha256 -> :ok
      true -> {:error, {:exposure_id_conflict, exposure.id}}
    end
  end

  defp visit_derivation(derivations, id, cases, visited) do
    if MapSet.member?(visited, id) do
      {:ok, cases, visited}
    else
      derivations
      |> Map.fetch(id)
      |> visit_derivation_value(derivations, id, cases, visited)
    end
  end

  defp visit_derivation_value({:ok, derivation}, derivations, id, cases, visited)
       when is_map(derivation) do
    with {:ok, direct, nested} <- derivation_sources(derivation, id) do
      nested
      |> Enum.sort()
      |> Enum.reduce_while(
        {:ok, MapSet.union(cases, MapSet.new(direct)), MapSet.put(visited, id)},
        &visit_nested(derivations, &1, &2)
      )
    end
  end

  defp visit_derivation_value(:error, _derivations, id, _cases, _visited),
    do: {:error, {:unknown_derivation, id}}

  defp visit_derivation_value({:ok, _invalid}, _derivations, id, _cases, _visited),
    do: {:error, {:invalid_derivation, id}}

  defp derivation_sources(derivation, id) do
    direct = value(derivation, :source_case_ids, [])
    nested = value(derivation, :source_derivation_ids, [])

    if valid_ids?(direct) and valid_ids?(nested),
      do: {:ok, direct, nested},
      else: {:error, {:invalid_derivation_sources, id}}
  end

  defp visit_nested(derivations, id, {:ok, cases, visited}) do
    case visit_derivation(derivations, id, cases, visited) do
      {:ok, next_cases, next_visited} -> {:cont, {:ok, next_cases, next_visited}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp valid_ids?(ids), do: is_list(ids) and Enum.all?(ids, &(is_binary(&1) and &1 != ""))

  defp atomize_known_metadata(metadata) do
    Enum.reduce(
      ~w(exposure_id consumer_role consumer_id lineage_id model context_digest experiment_id at)a,
      metadata,
      fn key, result ->
        string_key = Atom.to_string(key)

        if Map.has_key?(result, string_key),
          do: Map.put(result, key, result[string_key]),
          else: result
      end
    )
  end

  defp reuse_exposure_time(corpus, metadata) do
    id = Map.get(metadata, :exposure_id, Map.get(metadata, "exposure_id"))

    existing =
      corpus.exposure_history
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1.id == id))

    if existing,
      do: Map.put(metadata, :at, existing.at),
      else: metadata
  end

  defp has_value?(metadata, key) do
    Map.get(metadata, key, Map.get(metadata, Atom.to_string(key))) not in [nil, ""]
  end

  defp exposure_time(metadata) do
    case Map.get(metadata, :at) do
      %DateTime{} = time -> DateTime.to_iso8601(time)
      value when is_binary(value) -> value
      nil -> DateTime.to_iso8601(DateTime.utc_now())
    end
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
