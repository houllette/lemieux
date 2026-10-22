defmodule Lemieux.Learning.Experience.Retrieval.Evidence do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Calibration
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy
  alias Lemieux.Learning.Experience.Lesson

  @spec note(lesson :: Lesson.t(), max_bytes :: pos_integer()) :: map()
  def note(lesson, max_bytes) do
    %{
      "id" => lesson.id,
      "sha256" => lesson.sha256,
      "outcome" => lesson.outcome,
      "qualification" => lesson.qualification,
      "use" =>
        if(lesson.outcome in ~w(rejected contradicted), do: "counterexample", else: "hypothesis"),
      "mechanism" => clip(lesson.mechanism, div(max_bytes, 2)),
      "applicability" =>
        lesson.applicability |> Enum.take(4) |> Enum.map(&clip(&1, div(max_bytes, 8))),
      "experience_sha256" => lesson.experience["sha256"],
      "evidence_file" => lesson.id <> ".json"
    }
  end

  @spec materialize(
          lessons :: [Lesson.t()],
          max_bytes :: pos_integer(),
          artifact_bytes :: pos_integer()
        ) ::
          {:ok, map(), [map()]} | {:error, term()}
  def materialize(lessons, max_bytes, artifact_bytes \\ 1024)
  def materialize([], _max_bytes, _artifact_bytes), do: {:ok, %{}, []}

  def materialize(lessons, max_bytes, artifact_bytes) do
    per_lesson = div(max_bytes, length(lessons))

    files =
      Map.new(lessons, &{&1.id <> ".json", bounded_evidence(&1, per_lesson, artifact_bytes)})

    guards = Enum.flat_map(lessons, &guards/1)

    if byte_size(JSON.encode!(files)) <= max_bytes and byte_size(JSON.encode!(guards)) <= 32_768,
      do: {:ok, files, guards},
      else: {:error, :retrieval_evidence_limit}
  end

  defp bounded_evidence(lesson, budget, artifact_bytes) do
    observations =
      lesson.experience
      |> Map.take(~w(raw derived evaluations))
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&(&1["id"] in (lesson.supporting ++ lesson.contradicting)))
      |> Enum.take(8)

    artifacts =
      lesson.experience["artifacts"]
      |> Enum.take(3)
      |> Enum.map(&artifact(lesson, &1, artifact_bytes))

    evidence = %{
      "lesson_id" => lesson.id,
      "lesson_sha256" => lesson.sha256,
      "experience_sha256" => lesson.experience["sha256"],
      "qualification" => lesson.qualification,
      "assessment" => assessment(lesson),
      "observations" => observations,
      "artifacts" => artifacts,
      "state" => "bounded_excerpt"
    }

    if byte_size(JSON.encode!(evidence)) + 100 <= budget do
      evidence
    else
      %{
        "lesson_id" => lesson.id,
        "experience_sha256" => lesson.experience["sha256"],
        "state" => "not_materialized",
        "reason" => "evidence_bytes_limit"
      }
    end
  end

  defp artifact(lesson, descriptor, maximum) do
    reference = descriptor["reference"]
    bytes = Base.decode64!(lesson.artifacts[reference["sha256"]])
    excerpt = binary_part(bytes, 0, min(byte_size(bytes), maximum))

    view = %{
      "id" => reference["id"],
      "sha256" => reference["sha256"],
      "size_bytes" => byte_size(bytes),
      "encoding" => "base64",
      "excerpt" => Base.encode64(excerpt),
      "truncated" => byte_size(excerpt) < byte_size(bytes)
    }

    # Expanded research disclosure preserves the source reference and full
    # bytes in the lesson, while exposing readable JSON rather than requiring
    # a model to reconstruct a large base64 blob. Default bounded views stay small.
    case {maximum > 1024, JSON.decode(excerpt)} do
      {true, {:ok, content}} ->
        view
        |> Map.drop(~w(excerpt encoding))
        |> Map.merge(%{"encoding" => "json", "content" => content})

      _bounded_or_not_json ->
        view
    end
  end

  defp guards(%Lesson{outcome: outcome} = lesson) when outcome in ~w(rejected contradicted) do
    lesson.experience["candidates"]
    |> Enum.filter(&(&1["id"] in lesson.candidate_ids))
    |> Enum.flat_map(&profile_guard(lesson, &1))
  end

  defp guards(_lesson), do: []

  defp profile_guard(
         lesson,
         %{"content" => %{"sha256" => sha, "content_schema" => "lemieux.session-profile/v1"}} =
           candidate
       ) do
    with encoded when is_binary(encoded) <- lesson.artifacts[sha],
         {:ok, profile} <- encoded |> Base.decode64!() |> Contract.decode() do
      paths = get_in(candidate, ["extensions", "changed_paths"]) || []
      paths = if is_list(paths), do: Enum.filter(paths, &is_binary/1), else: []
      changes = Enum.map(paths, &%{"path" => &1, "after_sha256" => value_digest(profile, &1)})

      [
        %{
          "lesson_id" => lesson.id,
          "profile_sha256" => Contract.digest(profile),
          "changes" => changes,
          "source_digests" => source_evaluations(lesson, "sha256"),
          "source_evaluation_ids" => source_evaluations(lesson, "id")
        }
      ]
    else
      _unavailable -> []
    end
  end

  defp profile_guard(_lesson, _candidate), do: []

  @spec value_digest(profile :: map(), path :: String.t()) :: String.t()
  def value_digest(profile, path) do
    value = Enum.reduce_while(String.split(path, "."), {:present, profile}, &value_at/2)

    case value do
      {:present, value} -> Contract.digest(%{"present" => true, "value" => value})
      :missing -> Contract.digest(%{"present" => false})
    end
  end

  defp value_at(key, {:present, map}) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:cont, {:present, value}}
      :error -> {:halt, :missing}
    end
  end

  defp value_at(_key, _value), do: {:halt, :missing}

  defp source_evaluations(lesson, key) do
    own =
      lesson.experience["evaluations"] |> Enum.map(& &1[key]) |> Enum.filter(&is_binary/1)

    nested =
      Enum.flat_map(lesson.source_lessons, fn map ->
        {:ok, source} = map |> JSON.encode!() |> Lesson.decode()
        source_evaluations(source, key)
      end)

    Enum.sort(Enum.uniq(own ++ nested))
  end

  # A bundle may intentionally contain only a plan reference. Without full
  # verified comparative contracts it supports no causal diagnosis here.
  defp assessment(lesson) do
    with {:ok, plan} <- lesson.experience["plan"] |> JSON.encode!() |> Plan.decode(),
         {:ok, candidates} <-
           decode_all(lesson.experience["candidates"], &Candidate.decode(plan, JSON.encode!(&1))),
         {:ok, evaluations} <-
           decode_evaluations(plan, candidates, lesson.experience["evaluations"]) do
      policy = Policy.read(plan)
      usable = Enum.reject(evaluations, &infrastructure?(Digest.signature(&1, nil, policy)))

      %{
        "state" => "comparative",
        "calibration" => Calibration.summarize(plan, candidates, usable, policy),
        "candidates" =>
          Map.new(Enum.filter(candidates, &(&1.id in lesson.candidate_ids)), fn candidate ->
            {candidate.id, comparison(plan, candidate, candidates, evaluations, policy)}
          end)
      }
    else
      _unassessed -> %{"state" => "unassessed", "reason" => "complete_comparison_unavailable"}
    end
  end

  defp comparison(plan, candidate, candidates, evaluations, policy) do
    selected = Enum.filter(evaluations, &(&1.candidate_id == candidate.id))

    signatures = Enum.map(selected, &Digest.signature(&1, nil, policy))

    if signatures != [] and Enum.all?(signatures, &infrastructure?/1) do
      %{
        "state" => "infrastructure_failure",
        "attribution" => "no_edit_effect_established",
        "causes" => signatures |> Enum.map(& &1["cause"]) |> Enum.uniq() |> Enum.sort()
      }
    else
      usable = Enum.reject(evaluations, &infrastructure?(Digest.signature(&1, nil, policy)))
      comparison_result(Calibration.realized(plan, candidate, candidates, usable, policy))
    end
  end

  defp infrastructure?(%{"cause" => cause}),
    do: cause == "runtime_failed" or String.starts_with?(cause, "provider_")

  defp comparison_result({:ok, realized}) do
    state =
      cond do
        realized["regressed"] != [] -> "observed_regression"
        realized["fixed"] != [] -> "observed_fix"
        realized["compared_case_ids"] != [] -> "no_observed_fix"
        true -> "unassessed"
      end

    Map.put(realized, "state", state)
  end

  defp comparison_result(_unavailable), do: %{"state" => "unassessed"}

  defp decode_evaluations(plan, candidates, evaluations) do
    index = Map.new(candidates, &{&1.id, &1})

    decode_all(evaluations, fn map ->
      case Map.fetch(index, map["candidate_id"]) do
        {:ok, candidate} -> Evaluation.decode(plan, candidate, JSON.encode!(map))
        :error -> {:error, :missing_candidate}
      end
    end)
  end

  defp decode_all(maps, decode) do
    Enum.reduce_while(maps, {:ok, []}, fn map, {:ok, decoded} ->
      case decode.(map) do
        {:ok, value} -> {:cont, {:ok, decoded ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp clip(text, max_bytes) do
    text
    |> String.to_charlist()
    |> Enum.reduce_while({[], 0}, fn char, {chars, bytes} ->
      size = byte_size(<<char::utf8>>)

      if bytes + size <= max_bytes,
        do: {:cont, {[char | chars], bytes + size}},
        else: {:halt, {chars, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end
end
