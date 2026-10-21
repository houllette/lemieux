defmodule Lemieux.CLI.Learning.RefinementLesson do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson
  alias Lemieux.Learning.Promotion
  alias Lemieux.Learning.Refinement

  @spec retain(
          receipt :: map() | nil,
          task_id :: String.t(),
          store :: term(),
          authority :: function(),
          opts :: keyword()
        ) ::
          {:ok, [String.t()]} | {:error, term()}
  def retain(receipt, task_id, store, authority, opts \\ [])

  def retain(%{"decision" => "proposed"} = receipt, task_id, store, authority, opts) do
    with :ok <- Refinement.verify(receipt),
         {:ok, context} <- authority.(),
         {:ok, lesson} <- build(receipt, task_id, context, opts),
         {:ok, _} <- Promotion.retain(store, lesson, authority) do
      {:ok, [lesson.id]}
    end
  end

  def retain(_abstention, _task_id, _store, _authority, _opts), do: {:ok, []}

  defp build(receipt, task_id, context, opts) do
    bytes = Contract.encode!(receipt)

    reference =
      ArtifactReference.from_bytes("refinement", bytes,
        scope: context.scope,
        id: "refinement-source"
      )

    with {:ok, bundle} <-
           Bundle.new(%{
             "id" => "refinement-" <> receipt["sha256"],
             "scope" => context.scope,
             "plan" => %{
               "id" => "refinement-retention/v1",
               "sha256" => Contract.sha256("refinement-retention/v1"),
               "scope" => context.scope
             },
             "seeds" => [],
             "candidates" => [],
             "evaluations" => [],
             "exposures" => [],
             "raw" => [
               %{
                 "id" => "contrast",
                 "scope" => context.scope,
                 "case_id" => task_id,
                 "reference" => ArtifactReference.to_map(reference)
               }
             ],
             "derived" => [
               %{"id" => "finding", "scope" => context.scope, "source_references" => ["contrast"]}
             ],
             "artifacts" => [
               %{
                 "id" => "executable-profile-and-probes",
                 "scope" => context.scope,
                 "path" => "refinement.json",
                 "reference" => ArtifactReference.to_map(reference)
               }
             ]
           }) do
      suffix = get_in(receipt, ["selected_profile", "options", "system"]) || ""

      Lesson.new(bundle, %{reference.sha256 => bytes}, %{
        "key" => "refinement-" <> receipt["sha256"],
        "kind" => "proposer_lesson",
        "outcome" => "supported",
        "qualification" =>
          if(receipt["qualification"] == "experimental_task_local",
            do: "unconfirmed",
            else: "behavioral"
          ),
        "applicability" => ["coding verification failure recovery repository workflow"],
        "mechanism" =>
          "A task-local contrast supported this profile. Recheck its assumptions on the new repository; it proves no transfer and grants no activation authority. Retained profile guidance: " <>
            String.slice(suffix, 0, 2048),
        "supporting" => ["finding"],
        "contradicting" => [],
        "candidate_ids" => [],
        "binding" => context.lesson_context,
        "provenance" => %{
          "actor" => "qualification-host",
          "refinement_sha256" => receipt["sha256"]
        },
        "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "expires_at" => nil,
        "supersedes" => [],
        "source_lessons" => Enum.map(Keyword.get(opts, :source_lessons, []), &Lesson.to_map/1)
      })
    end
  end
end
