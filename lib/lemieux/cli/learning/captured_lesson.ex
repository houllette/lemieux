defmodule Lemieux.CLI.Learning.CapturedLesson do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extensions.Capture
  alias Lemieux.Extensions.Capture.Storage
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Promotion

  @spec retain(
          records :: [map()],
          workspace :: Path.t(),
          task_id :: String.t(),
          store :: term(),
          authority :: function(),
          opts :: keyword()
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def retain(records, workspace, task_id, store, authority, opts \\ []) do
    Enum.reduce_while(records, {:ok, []}, fn record, {:ok, ids} ->
      with :ok <- Capture.verify(record),
           true <- record["scope"] == Storage.scope(workspace),
           {:ok, context} <- authority.(),
           {:ok, lesson} <- lesson(record, task_id, context, opts),
           {:ok, _receipt} <- Promotion.retain(store, lesson, authority) do
        {:cont, {:ok, ids ++ [lesson.id]}}
      else
        error -> {:halt, {:error, {:capture_retention_refused, error}}}
      end
    end)
  end

  defp lesson(record, task_id, context, opts) do
    bytes = JSON.encode!(record)

    reference =
      ArtifactReference.from_bytes("capture", bytes,
        scope: context.scope,
        id: "source-" <> record["sha256"]
      )

    raw = "observation-" <> record["sha256"]
    finding = "finding-" <> record["sha256"]

    with {:ok, bundle} <-
           Bundle.new(%{
             "id" => "capture-experience-" <> record["sha256"],
             "scope" => context.scope,
             "plan" => %{
               "id" => "ordinary-capture/v1",
               "sha256" => Contract.sha256("ordinary-capture/v1"),
               "scope" => context.scope
             },
             "seeds" => [],
             "candidates" => [],
             "evaluations" => [],
             "exposures" => [],
             "raw" => [
               %{
                 "id" => raw,
                 "scope" => context.scope,
                 "case_id" => task_id,
                 "reference" => ArtifactReference.to_map(reference)
               }
             ],
             "derived" => [
               %{"id" => finding, "scope" => context.scope, "source_references" => [raw]}
             ],
             "artifacts" => [
               %{
                 "id" => "capture-file-" <> record["sha256"],
                 "scope" => context.scope,
                 "path" => "capture.json",
                 "reference" => ArtifactReference.to_map(reference)
               }
             ]
           }) do
      Lesson.new(bundle, %{reference.sha256 => bytes}, %{
        "key" => record["id"],
        "kind" => "procedure",
        "outcome" => "insufficient_evidence",
        "qualification" => "unconfirmed",
        "applicability" => ["coding verification failure recovery"],
        "mechanism" =>
          "Observed #{record["kind"]} for #{record["command"] || "a tool or correction"}. Inspect the bounded source before proposing a change; this observation proves neither task correctness nor transfer.",
        "supporting" => [finding],
        "contradicting" => [],
        "candidate_ids" => [],
        "binding" => context.lesson_context,
        "provenance" => %{"actor" => "qualification-host", "capture_sha256" => record["sha256"]},
        "created_at" => DateTime.to_iso8601(context.now),
        "expires_at" => nil,
        "supersedes" => [],
        "source_lessons" => Enum.map(Keyword.get(opts, :source_lessons, []), &Lesson.to_map/1)
      })
    end
  end
end
