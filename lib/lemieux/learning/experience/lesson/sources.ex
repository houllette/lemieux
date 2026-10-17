defmodule Lemieux.Learning.Experience.Lesson.Sources do
  @moduledoc false

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Experience.Bundle

  @collections ~w(seeds candidates evaluations raw derived artifacts)
  @max_nodes 512

  @spec verify(experience :: map(), artifacts :: map()) :: {:ok, map()} | {:error, term()}
  def verify(experience, artifacts) when is_map(experience) and is_map(artifacts) do
    with :ok <- shape(experience),
         {:ok, bundle} <- experience |> JSON.encode!() |> Bundle.decode(),
         :ok <- references(experience, bundle.scope, artifacts),
         true <- MapSet.new(Map.keys(artifacts)) == MapSet.new(artifact_digests(experience)),
         {:ok, nodes} <- nodes(bundle),
         :ok <- acyclic(nodes),
         {:ok, cases} <- Corpus.source_closure(nodes, Map.keys(nodes)),
         {:ok, exposed} <- exposure_cases(experience, nodes) do
      {:ok,
       %{
         cases: Enum.sort(Enum.uniq(cases ++ exposed)),
         candidates: Enum.map(bundle.candidates, & &1["id"]),
         observations: Enum.map(bundle.raw ++ bundle.derived ++ bundle.evaluations, & &1["id"])
       }}
    else
      false -> {:error, :unreferenced_lesson_artifact}
      error -> error
    end
  end

  def verify(_experience, _artifacts), do: {:error, :invalid_lesson_sources}

  defp shape(experience) do
    items = Enum.flat_map(@collections, &List.wrap(experience[&1]))

    if Enum.all?(@collections ++ ["exposures"], &is_list(experience[&1])) and
         length(items) <= @max_nodes and
         Enum.all?(items, &(is_map(&1) and nonempty?(&1["id"]))) and
         Enum.all?(experience["exposures"], &(is_map(&1) and ids?(&1["source_case_ids"]))) do
      :ok
    else
      {:error, :invalid_lesson_sources}
    end
  end

  defp references(%{"size_bytes" => _} = value, scope, artifacts) do
    with {:ok, reference} <- ArtifactReference.from_map(value),
         true <- reference.scope == scope,
         bytes when is_binary(bytes) <- artifacts[reference.sha256],
         :ok <- ArtifactReference.verify_bytes(reference, bytes) do
      :ok
    else
      _invalid -> {:error, {:invalid_lesson_artifact, value["id"]}}
    end
  end

  defp references(value, scope, artifacts) when is_map(value) do
    if Map.has_key?(value, "scope") and value["scope"] != scope do
      {:error, :lesson_source_scope_mismatch}
    else
      value |> Map.values() |> references(scope, artifacts)
    end
  end

  defp references(values, scope, artifacts) when is_list(values) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case references(value, scope, artifacts) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp references(_value, _scope, _artifacts), do: :ok

  defp artifact_digests(%{"size_bytes" => _, "sha256" => sha}), do: [sha]
  defp artifact_digests(map) when is_map(map), do: map |> Map.values() |> artifact_digests()
  defp artifact_digests(list) when is_list(list), do: Enum.flat_map(list, &artifact_digests/1)
  defp artifact_digests(_value), do: []

  defp nodes(bundle) do
    items =
      Enum.flat_map(
        ~w(seeds candidates evaluations raw derived),
        &Map.fetch!(Bundle.to_map(bundle), &1)
      )

    artifacts = Enum.map(bundle.artifacts, & &1["reference"])

    Enum.reduce_while(items ++ Enum.uniq(artifacts), {:ok, %{}}, fn item, {:ok, nodes} ->
      id = item["id"]

      with false <- Map.has_key?(nodes, id),
           {:ok, sources} <- source_ids(item),
           {:ok, cases} <- case_ids(item) do
        node = %{"source_case_ids" => cases, "source_derivation_ids" => sources}
        {:cont, {:ok, Map.put(nodes, id, node)}}
      else
        true -> {:halt, {:error, {:duplicate_lesson_source, id}}}
        error -> {:halt, error}
      end
    end)
  end

  defp source_ids(item) do
    explicit = Map.get(item, "source_references", [])
    nested = Map.get(item, "source_derivation_ids", [])
    refs = Enum.flat_map(~w(reference content rationale), &reference_id(item[&1]))
    refs = refs ++ Enum.flat_map(List.wrap(item["artifacts"]), &reference_id/1)
    parents = Enum.flat_map(List.wrap(item["parents"]), &reference_id/1)

    if ids?(explicit) and ids?(nested) and reference_lists?(item) and reference_fields?(item),
      do: {:ok, Enum.uniq(explicit ++ nested ++ refs ++ parents)},
      else: {:error, :invalid_lesson_source_ancestry}
  end

  defp reference_id(%{"id" => id}) when is_binary(id), do: [id]
  defp reference_id(_value), do: []

  defp reference_lists?(item) do
    Enum.all?(~w(parents artifacts), fn key ->
      not Map.has_key?(item, key) or
        (is_list(item[key]) and Enum.all?(item[key], &(is_map(&1) and nonempty?(&1["id"]))))
    end)
  end

  defp reference_fields?(item) do
    Enum.all?(~w(reference content rationale), fn key ->
      not Map.has_key?(item, key) or match?({:ok, _}, ArtifactReference.from_map(item[key]))
    end)
  end

  defp case_ids(item) do
    cases = Map.get(item, "source_case_ids", [])
    direct = Map.get(item, "direct_case_ids", [])
    case_id = item["case_id"]

    if ids?(cases) and ids?(direct) and (is_nil(case_id) or nonempty?(case_id)),
      do: {:ok, Enum.uniq(cases ++ direct ++ List.wrap(case_id))},
      else: {:error, :invalid_lesson_case_ids}
  end

  defp exposure_cases(value, nodes) when is_map(value) do
    with {:ok, own} <- case_ids(value),
         :ok <- verify_exposure(value, nodes),
         {:ok, nested} <- exposure_cases(Map.values(value), nodes) do
      {:ok, own ++ nested}
    end
  end

  defp exposure_cases(values, nodes) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, cases} ->
      case exposure_cases(value, nodes) do
        {:ok, next} -> {:cont, {:ok, cases ++ next}}
        error -> {:halt, error}
      end
    end)
  end

  defp exposure_cases(_value, _nodes), do: {:ok, []}

  defp verify_exposure(%{"consumer_role" => _, "schema_version" => _} = map, nodes) do
    with {:ok, exposure} <- map |> JSON.encode!() |> Exposure.decode(),
         {:ok, closure} <- Corpus.source_closure(nodes, exposure.derived_artifact_ids),
         true <- Enum.all?(closure ++ exposure.direct_case_ids, &(&1 in exposure.source_case_ids)) do
      :ok
    else
      _invalid -> {:error, :incomplete_lesson_exposure}
    end
  end

  defp verify_exposure(_value, _nodes), do: :ok

  # Corpus.source_closure is cycle-safe for audit history. A new lesson must
  # additionally refuse a cyclic proof: a finding cannot support itself.
  defp acyclic(nodes) do
    Enum.reduce_while(Map.keys(nodes), {:ok, %{}}, fn id, {:ok, done} ->
      case visit(nodes, id, %{}, done) do
        {:ok, done} -> {:cont, {:ok, done}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _done} -> :ok
      error -> error
    end
  end

  @spec visit(
          nodes :: map(),
          id :: String.t(),
          path :: map(),
          done :: map()
        ) ::
          {:ok, map()} | {:error, term()}
  defp visit(nodes, id, path, done) do
    cond do
      Map.has_key?(path, id) -> {:error, :cyclic_lesson_sources}
      Map.has_key?(done, id) -> {:ok, done}
      not Map.has_key?(nodes, id) -> {:error, {:missing_lesson_source, id}}
      true -> visit_sources(nodes, id, Map.put(path, id, true), done)
    end
  end

  @spec visit_sources(
          nodes :: map(),
          id :: String.t(),
          path :: map(),
          done :: map()
        ) ::
          {:ok, map()} | {:error, term()}
  defp visit_sources(nodes, id, path, done) do
    Enum.reduce_while(nodes[id]["source_derivation_ids"], {:ok, done}, fn source, {:ok, seen} ->
      case visit(nodes, source, path, seen) do
        {:ok, seen} -> {:cont, {:ok, seen}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, seen} -> {:ok, Map.put(seen, id, true)}
      error -> error
    end
  end

  defp ids?(ids), do: is_list(ids) and Enum.all?(ids, &nonempty?/1)
  defp nonempty?(value), do: is_binary(value) and value != ""
end
