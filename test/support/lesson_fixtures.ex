defmodule LemieuxTest.LessonFixtures do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson

  @spec scope() :: map()
  def scope, do: %{"id" => "tenant-a/project-a"}

  @spec context() :: map()
  def context do
    %{
      "model" => "test:model",
      "tools_sha256" => Contract.sha256("tools"),
      "environment_sha256" => Contract.sha256("environment"),
      "repository" => "project-a",
      "revision" => "revision-a",
      "source_sha256" => Contract.sha256("source")
    }
  end

  @spec attrs() :: map()
  def attrs do
    %{
      "key" => "check-before-editing",
      "kind" => "procedure",
      "outcome" => "supported",
      "qualification" => "behavioral",
      "applicability" => ["editing a failing parser"],
      "mechanism" => "Run the failing check before changing the parser.",
      "supporting" => ["finding"],
      "contradicting" => [],
      "candidate_ids" => ["candidate"],
      "binding" => context(),
      "provenance" => %{"actor" => "host-review", "run_id" => "run-a"},
      "created_at" => "2026-10-17T00:00:00Z",
      "expires_at" => nil,
      "supersedes" => []
    }
  end

  @spec evidence() :: {Bundle.t(), map()}
  def evidence do
    ref = ArtifactReference.from_bytes("trace", "observed trace", scope: scope(), id: "trace")

    {:ok, bundle} =
      Bundle.new(%{
        "id" => "experience-a",
        "scope" => scope(),
        "plan" => %{"id" => "plan-a", "sha256" => Contract.sha256("plan"), "scope" => scope()},
        "seeds" => [],
        "candidates" => [%{"id" => "candidate", "scope" => scope()}],
        "evaluations" => [
          %{"id" => "evaluation", "scope" => scope(), "case_id" => "case-direct"}
        ],
        "raw" => [
          %{"id" => "raw", "scope" => scope(), "reference" => ArtifactReference.to_map(ref)}
        ],
        "derived" => [
          %{
            "id" => "finding",
            "scope" => scope(),
            "source_references" => ["raw"],
            "source_case_ids" => ["case-transitive"]
          }
        ],
        "exposures" => [%{"source_case_ids" => ["case-direct", "case-prior"]}],
        "artifacts" => [
          %{
            "id" => "trace-file",
            "scope" => scope(),
            "path" => "raw/trace",
            "reference" => ArtifactReference.to_map(ref)
          }
        ]
      })

    {bundle, %{ref.sha256 => "observed trace"}}
  end

  @spec lesson(changes :: map(), source_lessons :: [Lesson.t()]) :: Lesson.t()
  def lesson(changes \\ %{}, source_lessons \\ []) do
    {bundle, artifacts} = evidence()

    attrs =
      attrs()
      |> Map.merge(changes)
      |> Map.put("source_lessons", Enum.map(source_lessons, &Lesson.to_map/1))

    {:ok, lesson} = Lesson.new(bundle, artifacts, attrs)
    lesson
  end

  @spec consumer() :: map()
  def consumer do
    %{
      "id" => "release-a",
      "consumer_role" => "proposer",
      "consumer_id" => "improver-a",
      "model" => "test:model",
      "at" => "2026-10-17T00:00:00Z"
    }
  end
end
