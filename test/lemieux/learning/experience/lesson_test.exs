defmodule Lemieux.Learning.Experience.LessonTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Bundle
  alias Lemieux.Learning.Experience.Lesson
  alias LemieuxTest.LessonFixtures, as: F

  test "round trip binds every lesson field, source manifest, byte and exposure ancestor" do
    lesson = F.lesson()
    assert {:ok, ^lesson} = lesson |> Lesson.encode!() |> Lesson.decode()
    assert lesson.id == "lesson_" <> lesson.sha256
    assert lesson.source_case_ids == ["case-direct", "case-prior", "case-transitive"]
    assert lesson.scope == F.scope()
    assert lesson.outcome == "supported"
    assert lesson.qualification == "behavioral"
    assert lesson.candidate_ids == ["candidate"]

    for field <-
          ~w(mechanism outcome qualification binding provenance experience artifacts source_case_ids supersedes) do
      tampered = lesson |> Lesson.to_map() |> Map.put(field, "altered") |> JSON.encode!()
      assert {:error, _} = Lesson.decode(tampered), field
    end

    assert {:error, {:unsupported_version, 2}} =
             lesson
             |> Lesson.to_map()
             |> Map.put("schema_version", 2)
             |> JSON.encode!()
             |> Lesson.decode()
  end

  test "rejects missing and modified evidence bytes before making a lesson" do
    {bundle, artifacts} = F.evidence()
    assert {:error, _} = Lesson.new(bundle, %{}, F.attrs())
    wrong = Map.new(artifacts, fn {digest, _} -> {digest, "altered bytes!"} end)
    assert {:error, _} = Lesson.new(bundle, wrong, F.attrs())

    assert {:error, _} =
             Lesson.new(%{bundle | scope: %{"id" => "elsewhere"}}, artifacts, F.attrs())
  end

  test "rejects dangling, cross-scope, cyclic and malformed source ancestry" do
    {bundle, artifacts} = F.evidence()

    for change <- [
          fn map -> put_in(map, ["derived", Access.at(0), "source_references"], ["missing"]) end,
          fn map -> put_in(map, ["derived", Access.at(0), "source_references"], ["finding"]) end,
          fn map -> put_in(map, ["exposures", Access.at(0), "source_case_ids"], "bad") end,
          fn map ->
            put_in(map, ["raw", Access.at(0), "reference", "scope"], %{"id" => "tenant-b"})
          end
        ] do
      map = bundle |> Bundle.to_map() |> Map.delete("sha256") |> change.()
      assert {:ok, changed} = Bundle.new(map)
      assert {:error, _} = Lesson.new(changed, artifacts, F.attrs())
    end

    assert {:error, _} =
             Lesson.new(bundle, artifacts, Map.put(F.attrs(), "supporting", ["missing"]))

    assert {:error, _} =
             Lesson.new(bundle, artifacts, Map.put(F.attrs(), "candidate_ids", ["missing"]))
  end

  test "negative and uncertain outcomes remain distinct and never claim confirmation" do
    for outcome <- ~w(rejected contradicted insufficient_evidence) do
      lesson = F.lesson(%{"outcome" => outcome, "qualification" => "unconfirmed"})
      assert {:ok, decoded} = lesson |> Lesson.encode!() |> Lesson.decode()
      assert decoded.outcome == outcome
      assert decoded.qualification == "unconfirmed"
    end

    {bundle, artifacts} = F.evidence()

    assert {:error, _} =
             Lesson.new(bundle, artifacts, Map.put(F.attrs(), "qualification", "confirmed"))

    assert {:error, _} =
             Lesson.new(bundle, artifacts, Map.put(F.attrs(), "hooks", %{"exec" => "anything"}))
  end

  test "workspace facts require revision and source identity, and expire at the boundary" do
    lesson = F.lesson(%{"kind" => "workspace_fact", "expires_at" => "2026-10-18T00:00:00Z"})
    assert :ok = Lesson.applicable(lesson, F.context(), ~U[2026-10-17 00:00:00Z])
    assert {:error, :expired} = Lesson.applicable(lesson, F.context(), ~U[2026-10-18 00:00:00Z])

    for field <- ~w(model tools_sha256 environment_sha256 repository revision source_sha256) do
      assert {:error, {:binding_changed, ^field}} =
               Lesson.applicable(
                 lesson,
                 Map.put(F.context(), field, "changed"),
                 ~U[2026-10-17 00:00:00Z]
               )
    end

    {bundle, artifacts} = F.evidence()

    attrs =
      F.attrs()
      |> Map.put("kind", "workspace_fact")
      |> update_in(["binding"], &Map.delete(&1, "revision"))

    assert {:error, _} = Lesson.new(bundle, artifacts, attrs)
  end

  test "recomputed hashes cannot hide incomplete closure or unknown payload fields" do
    map = F.lesson() |> Lesson.to_map()

    for changed <- [Map.put(map, "source_case_ids", []), Map.put(map, "callback", "authority")] do
      base = Map.drop(changed, ["id", "sha256"])
      digest = Contract.digest(base)

      encoded =
        base |> Map.merge(%{"id" => "lesson_" <> digest, "sha256" => digest}) |> JSON.encode!()

      assert {:error, _} = Lesson.decode(encoded)
    end
  end

  test "bounded manifests refuse oversized input" do
    {bundle, artifacts} = F.evidence()

    assert {:error, :lesson_too_large} =
             Lesson.new(
               bundle,
               artifacts,
               Map.put(F.attrs(), "mechanism", String.duplicate("x", 2_100_000))
             )

    assert {:error, :lesson_too_large} = Lesson.decode(String.duplicate("x", 2_100_000))
  end

  test "source lessons retain their transitive exposure and exact source bytes" do
    parent = F.lesson()
    {bundle, artifacts} = F.evidence()

    {:ok, different} =
      bundle
      |> Bundle.to_map()
      |> Map.delete("sha256")
      |> put_in(["evaluations", Access.at(0), "case_id"], "new-case")
      |> Map.put("exposures", [])
      |> put_in(["derived", Access.at(0), "source_case_ids"], [])
      |> Bundle.new()

    attrs =
      F.attrs()
      |> Map.put("source_lessons", [Lesson.to_map(parent)])
      |> Map.put("supersedes", [parent.id])
      |> Map.put("supporting", [parent.id])

    assert {:ok, derived} = Lesson.new(different, artifacts, attrs)
    assert derived.source_case_ids == ["case-direct", "case-prior", "case-transitive", "new-case"]
    assert {:ok, ^derived} = derived |> Lesson.encode!() |> Lesson.decode()
    assert {:error, _} = Lesson.new(different, artifacts, Map.put(attrs, "source_lessons", []))
    tampered = attrs |> put_in(["source_lessons", Access.at(0), "mechanism"], "tampered")
    assert {:error, _} = Lesson.new(different, artifacts, tampered)
  end

  test "new lessons cannot carry unreferenced bytes or omit typed exposure ancestry" do
    {bundle, artifacts} = F.evidence()

    assert {:error, :unreferenced_lesson_artifact} =
             Lesson.new(bundle, Map.put(artifacts, Contract.sha256("extra"), "extra"), F.attrs())

    assert {:ok, exposure} =
             Exposure.new(%{
               "id" => "exposure",
               "consumer_role" => "proposer",
               "consumer_id" => "consumer",
               "direct_case_ids" => [],
               "derived_artifact_ids" => ["finding"],
               "source_case_ids" => []
             })

    assert {:ok, incomplete} =
             bundle
             |> Bundle.to_map()
             |> Map.delete("sha256")
             |> Map.put("exposures", [Exposure.to_map(exposure)])
             |> Bundle.new()

    assert {:error, :incomplete_lesson_exposure} = Lesson.new(incomplete, artifacts, F.attrs())
  end

  test "malformed, correctly rehashed records are refused without reconstructing authority" do
    map = F.lesson() |> Lesson.to_map()

    for {field, values} <- %{
          "experience" => [nil, [], %{}],
          "artifacts" => [nil, [], %{"a" => false}],
          "binding" => [nil, [], %{}],
          "source_lessons" => [nil, [false], [%{}]],
          "provenance" => [nil, [], %{}],
          "created_at" => [nil, 1, "invalid"],
          "supporting" => [nil, "finding", [false]],
          "supersedes" => [["../path"]]
        },
        value <- values do
      base = map |> Map.put(field, value) |> Map.drop(["id", "sha256"])
      digest = Contract.digest(base)

      assert {:error, _} =
               base
               |> Map.merge(%{"id" => "lesson_" <> digest, "sha256" => digest})
               |> JSON.encode!()
               |> Lesson.decode()
    end
  end
end
