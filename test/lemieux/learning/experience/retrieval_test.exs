defmodule Lemieux.Learning.Experience.RetrievalTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Learning.Experience.Retrieval
  alias LemieuxTest.LessonFixtures, as: F

  @moduletag :tmp_dir
  @now ~U[2026-10-17 01:00:00Z]
  @query %{"task" => "repair the failing parser", "failure_cues" => ["check parser"]}

  test "filters before ranking and qualifies negative evidence without releasing full history", %{
    tmp_dir: dir
  } do
    store = LessonFiles.new(dir, F.scope())
    relevant = F.lesson()

    rejected =
      F.lesson(%{"key" => "rejected", "outcome" => "rejected", "qualification" => "unconfirmed"})

    unrelated = F.lesson(%{"key" => "unrelated", "applicability" => ["database backups"]})

    stale =
      F.lesson(%{
        "key" => "stale",
        "kind" => "workspace_fact",
        "binding" => Map.put(F.context(), "revision", "old")
      })

    contradicted =
      F.lesson(%{
        "key" => "counterexample",
        "outcome" => "contradicted",
        "contradicting" => ["evaluation"]
      })

    for lesson <- [relevant, rejected, unrelated, stale, contradicted],
        do: assert(:ok = Lessons.append(store, lesson))

    assert {:ok, library} = Retrieval.freeze(store, F.scope())
    assert {:ok, report} = Retrieval.inspect(store, library, @query, F.context(), now: @now)
    assert report["status"] == "complete"
    assert report["counts"]["applicability_mismatch"] == 1
    assert report["counts"]["binding_changed"] == 1
    assert report["counts"]["selected"] == 3
    refute JSON.encode!(report) =~ relevant.mechanism

    commit = fn scope, exposure ->
      assert scope == F.scope()
      assert exposure.source_case_ids == relevant.source_case_ids

      assert Enum.sort(exposure.derived_artifact_ids) ==
               Enum.sort([relevant.id, rejected.id, contradicted.id])

      send(self(), :committed)
      :ok
    end

    assert {:ok, result} =
             Retrieval.retrieve(store, library, @query, F.context(), F.consumer(), commit,
               now: @now
             )

    assert_received :committed
    assert result.receipt == report
    assert Enum.any?(result.notes, &(&1["id"] == rejected.id and &1["use"] == "counterexample"))

    assert Enum.any?(
             result.notes,
             &(&1["id"] == contradicted.id and &1["use"] == "counterexample")
           )

    assert Enum.all?(result.notes, &(&1["experience_sha256"] == relevant.experience["sha256"]))
    refute JSON.encode!(result.notes) =~ "observed trace"
    assert map_size(result.evidence) == 3
  end

  test "a frozen library and its updating variant reproduce independently", %{tmp_dir: dir} do
    store = LessonFiles.new(dir, F.scope())
    assert {:ok, frozen} = Retrieval.freeze(store, F.scope())
    first = F.lesson()
    assert :ok = Lessons.append(store, first)
    assert {:ok, updated} = Retrieval.freeze(store, F.scope())
    refute frozen["sha256"] == updated["sha256"]
    assert {:ok, old_report} = Retrieval.inspect(store, frozen, @query, F.context(), now: @now)
    assert old_report["selected"] == []
    assert {:ok, new_report} = Retrieval.inspect(store, updated, @query, F.context(), now: @now)
    assert [%{"id" => id, "sha256" => digest}] = new_report["selected"]
    assert id == first.id and digest == first.sha256
    assert {:ok, ^new_report} = Retrieval.inspect(store, updated, @query, F.context(), now: @now)

    assert {:error, _} =
             Retrieval.inspect(store, Map.put(updated, "lesson_ids", []), @query, F.context(),
               now: @now
             )

    assert :ok = Lessons.prune(store, first.id, "retention", @now)
    assert {:ok, pruned} = Retrieval.inspect(store, updated, @query, F.context(), now: @now)
    assert pruned["selected"] == []
    assert pruned["counts"]["pruned"] == 1
  end

  test "large histories bound source reads, decisions and returned context", %{tmp_dir: dir} do
    store = LessonFiles.new(dir, F.scope())

    for n <- 1..40 do
      assert :ok = Lessons.append(store, F.lesson(%{"key" => "parser-#{n}"}))
    end

    assert {:ok, library} = Retrieval.freeze(store, F.scope())

    assert {:ok, report} =
             Retrieval.inspect(store, library, @query, F.context(),
               now: @now,
               max_results: 3,
               max_decisions: 5
             )

    assert length(report["selected"]) == 3
    assert Enum.map(report["selected"], & &1["id"]) == Enum.take(library["lesson_ids"], 3)
    assert report["counts"]["rank_limit"] == 37
    assert length(report["decisions"]) == 5
    assert report["omitted_decisions"] == 35

    assert {:ok, incomplete} =
             Retrieval.inspect(store, library, @query, F.context(),
               now: @now,
               max_source_bytes: 1
             )

    assert incomplete["status"] == "incomplete"
    assert incomplete["stop_reason"] == "source_bytes_limit"

    assert {:error, {:retrieval_incomplete, ^incomplete}} =
             Retrieval.retrieve(
               store,
               library,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> flunk("partial release") end,
               now: @now,
               max_source_bytes: 1
             )
  end

  test "superseded lessons stay suppressed after pruning and ambiguous siblings are excluded", %{
    tmp_dir: dir
  } do
    store = LessonFiles.new(dir, F.scope())
    first = F.lesson()

    replacement =
      F.lesson(%{"mechanism" => "Check the parser twice.", "supersedes" => [first.id]}, [first])

    sibling = F.lesson(%{"mechanism" => "Check parser diagnostics before editing."})
    for lesson <- [first, replacement, sibling], do: assert(:ok = Lessons.append(store, lesson))
    assert {:ok, library} = Retrieval.freeze(store, F.scope())
    assert {:ok, report} = Retrieval.inspect(store, library, @query, F.context(), now: @now)
    assert report["selected"] == []
    assert report["counts"] == %{"superseded" => 1, "conflict" => 2}
    assert :ok = Lessons.prune(store, replacement.id, "retention", @now)
    assert {:ok, pruned} = Retrieval.inspect(store, library, @query, F.context(), now: @now)
    assert Enum.map(pruned["selected"], & &1["id"]) == [sibling.id]
    assert pruned["counts"]["superseded"] == 1
    assert pruned["counts"]["pruned"] == 1
  end

  test "missing frozen records refuse release and corrupt records fail verification", %{
    tmp_dir: dir
  } do
    store = LessonFiles.new(dir, F.scope())
    lesson = F.lesson()
    assert :ok = Lessons.append(store, lesson)
    assert {:ok, library} = Retrieval.freeze(store, F.scope())
    path = Path.join(dir, lesson.id <> ".json")
    File.rm!(path)

    assert {:error, {:retrieval_incomplete, receipt}} =
             Retrieval.retrieve(
               store,
               library,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> flunk("missing source released") end,
               now: @now
             )

    assert receipt["stop_reason"] == "missing_record"
    assert receipt["selected"] == []
    File.write!(path, "{}")
    assert {:error, _} = Retrieval.inspect(store, library, @query, F.context(), now: @now)
  end

  test "negative evidence keeps a result slot and all output budgets are enforced", %{
    tmp_dir: dir
  } do
    store = LessonFiles.new(dir, F.scope())
    positive = F.lesson()

    negative =
      F.lesson(%{
        "key" => "negative",
        "outcome" => "rejected",
        "mechanism" => "Ineffective change."
      })

    expired = F.lesson(%{"key" => "expired", "expires_at" => "2026-10-17T01:00:00Z"})
    future = F.lesson(%{"key" => "future", "created_at" => "2026-10-18T00:00:00Z"})

    for lesson <- [positive, negative, expired, future],
        do: assert(:ok = Lessons.append(store, lesson))

    assert {:ok, library} = Retrieval.freeze(store, F.scope())

    assert {:ok, result} =
             Retrieval.retrieve(
               store,
               library,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> :ok end,
               now: @now,
               max_results: 1,
               max_note_bytes: 16
             )

    assert [note] = result.notes
    assert note["id"] == negative.id
    assert note["use"] == "counterexample"

    assert byte_size(note["mechanism"]) + Enum.sum(Enum.map(note["applicability"], &byte_size/1)) <=
             16

    assert result.receipt["counts"]["expired"] == 1
    assert result.receipt["counts"]["not_yet_created"] == 1

    assert {:error, :retrieval_evidence_limit} =
             Retrieval.retrieve(
               store,
               library,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> flunk("unbounded evidence") end,
               now: @now,
               max_evidence_bytes: 1
             )

    assert {:error, :invalid_retrieval_time} =
             Retrieval.inspect(store, library, @query, F.context(), now: "invalid")

    assert {:error, :lesson_retrieval_not_supported} =
             Retrieval.freeze({__MODULE__, nil}, F.scope())

    assert {:error, :lesson_retrieval_not_supported} =
             Lessons.fetch({__MODULE__, nil}, negative.id, 1024)
  end

  test "scope mismatch and failed exposure release no notes", %{tmp_dir: dir} do
    store = LessonFiles.new(dir, F.scope())
    assert :ok = Lessons.append(store, F.lesson())
    assert {:ok, library} = Retrieval.freeze(store, F.scope())
    other = LessonFiles.new(dir, %{"id" => "tenant-b/project-b"})

    assert {:error, :lesson_scope_mismatch} =
             Retrieval.inspect(other, library, @query, F.context(), now: @now)

    assert {:error, {:exposure_not_committed, :offline}} =
             Retrieval.retrieve(
               store,
               library,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> {:error, :offline} end,
               now: @now
             )

    assert {:error, _} =
             Retrieval.inspect(
               store,
               library,
               %{"task" => String.duplicate("x", 10_000)},
               F.context()
             )

    assert {:error, _} = Retrieval.inspect(store, library, @query, F.context(), max_results: -1)

    assert {:ok, empty} =
             Retrieval.freeze(LessonFiles.new(Path.join(dir, "empty"), F.scope()), F.scope())

    assert {:ok, %{notes: [], exposure: nil}} =
             Retrieval.retrieve(
               store,
               empty,
               @query,
               F.context(),
               F.consumer(),
               fn _, _ -> flunk("empty exposure") end,
               now: @now
             )

    assert library["sha256"] == Contract.digest(library, ["sha256"])
  end
end
