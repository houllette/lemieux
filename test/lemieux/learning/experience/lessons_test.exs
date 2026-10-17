defmodule Lemieux.Learning.Experience.LessonsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Asset.Registry
  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Grader.Command
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.Task, as: BenchmarkTask
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: FileStore
  alias LemieuxTest.LessonFixtures, as: F

  @moduletag :tmp_dir

  test "atomic concurrent delivery is idempotent and a partial file is invisible", %{tmp_dir: dir} do
    store = FileStore.new(dir, F.scope())
    lesson = F.lesson()

    results =
      1..8 |> Task.async_stream(fn _ -> Lessons.append(store, lesson) end) |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert {:ok, [%{"id" => id, "status" => "retained"}]} = Lessons.history(store)
    assert id == lesson.id
    assert {:ok, ^lesson} = Lessons.read(store, id)
    File.write!(Path.join(dir, ".partial-interrupted"), "{\"incomplete\":")
    assert {:ok, [_]} = Lessons.history(FileStore.new(dir, F.scope()))
    assert Bitwise.band(File.stat!(Path.join(dir, id <> ".json")).mode, 0o777) == 0o600
  end

  test "scope is enforced by the store on append and read", %{tmp_dir: dir} do
    own = FileStore.new(dir, F.scope())
    other = FileStore.new(dir, %{"id" => "tenant-b/project-b"})
    lesson = F.lesson()
    assert :ok = Lessons.append(own, lesson)
    assert {:error, :lesson_scope_mismatch} = Lessons.append(other, lesson)
    assert {:error, :lesson_scope_mismatch} = Lessons.read(other, lesson.id)
    assert {:error, _} = Lessons.read(own, "../outside")
  end

  test "recall commits the whole exposure before releasing content", %{tmp_dir: dir} do
    store = FileStore.new(dir, F.scope())
    lesson = F.lesson()
    assert :ok = Lessons.append(store, lesson)

    manifest = %Manifest{
      tasks:
        Enum.map(
          lesson.source_case_ids,
          &%BenchmarkTask{
            id: &1,
            prompt: "fixture",
            cwd: dir,
            grader: %Command{command: ["true"]}
          }
        )
    }

    membership = Map.new(lesson.source_case_ids, &{&1, :development})
    assert {:ok, corpus} = Corpus.new(manifest, membership)

    commit = fn scope, exposure ->
      assert scope == F.scope()
      assert exposure.derived_artifact_ids == [lesson.id]
      assert exposure.source_case_ids == lesson.source_case_ids
      derivations = %{lesson.id => %{"source_case_ids" => exposure.source_case_ids}}

      metadata =
        exposure
        |> Exposure.to_map()
        |> Map.put("exposure_id", exposure.id)

      assert {:ok, exposed} = Corpus.expose_derived(corpus, [lesson.id], derivations, metadata)

      for id <- lesson.source_case_ids do
        assert {:error, {:case_exposed, ^id}} = Corpus.assign(exposed, id, :holdout)
      end

      send(self(), :committed)
      :ok
    end

    assert {:ok, [^lesson], exposure} =
             Lessons.recall(store, F.context(), F.consumer(), commit,
               now: ~U[2026-10-17 00:00:00Z]
             )

    assert_received :committed

    assert {:ok, [^lesson], ^exposure} =
             Lessons.recall(store, F.context(), F.consumer(), commit,
               now: ~U[2026-10-17 00:00:00Z]
             )

    assert {:error, {:exposure_not_committed, :offline}} =
             Lessons.recall(store, F.context(), F.consumer(), fn _, _ -> {:error, :offline} end,
               now: ~U[2026-10-17 00:00:00Z]
             )

    assert {:error, :approved_asset_proposal_required} = Registry.activate(Registry.new(), lesson)
  end

  test "changed identities and expired facts release nothing and record no exposure", %{
    tmp_dir: dir
  } do
    store = FileStore.new(dir, F.scope())
    lesson = F.lesson(%{"kind" => "workspace_fact", "expires_at" => "2026-10-18T00:00:00Z"})
    assert :ok = Lessons.append(store, lesson)
    commit = fn _, _ -> flunk("ineligible content was exposed") end

    assert {:ok, [], nil} =
             Lessons.recall(store, F.context(), F.consumer(), commit,
               now: ~U[2026-10-18 00:00:00Z]
             )

    for field <- ~w(revision source_sha256 environment_sha256 model) do
      assert {:ok, [], nil} =
               Lessons.recall(store, Map.put(F.context(), field, "changed"), F.consumer(), commit,
                 now: ~U[2026-10-17 00:00:00Z]
               )
    end
  end

  test "supersession preserves history, sibling conflicts refuse selection", %{tmp_dir: dir} do
    store = FileStore.new(dir, F.scope())
    first = F.lesson()

    second =
      F.lesson(%{"mechanism" => "A revised hypothesis", "supersedes" => [first.id]}, [first])

    assert {:error, {:missing_superseded_lesson, _}} = Lessons.append(store, second)
    assert :ok = Lessons.append(store, first)
    assert :ok = Lessons.append(store, second)

    assert {:ok, lessons, _} =
             Lessons.recall(store, F.context(), F.consumer(), fn _, _ -> :ok end,
               now: ~U[2026-10-17 00:00:00Z]
             )

    assert lessons == [second]

    sibling =
      F.lesson(%{"mechanism" => "A conflicting hypothesis", "supersedes" => [first.id]}, [first])

    assert :ok = Lessons.append(store, sibling)

    assert {:error, {:lesson_conflict, "check-before-editing", ids}} =
             Lessons.recall(
               store,
               F.context(),
               F.consumer(),
               fn _, _ -> flunk("conflict exposed") end,
               now: ~U[2026-10-17 00:00:00Z]
             )

    assert Enum.sort(ids) == Enum.sort([second.id, sibling.id])
    assert {:ok, history} = Lessons.history(store)
    assert length(history) == 3
    assert {:ok, ^first} = Lessons.read(store, first.id)
  end

  test "prune leaves an auditable tombstone and cannot resurrect a superseded lesson", %{
    tmp_dir: dir
  } do
    store = FileStore.new(dir, F.scope())
    first = F.lesson()
    second = F.lesson(%{"mechanism" => "Revised", "supersedes" => [first.id]}, [first])
    assert :ok = Lessons.append(store, first)
    assert :ok = Lessons.append(store, second)
    assert :ok = Lessons.prune(store, second.id, "retention", ~U[2026-10-18 00:00:00Z])
    assert :ok = Lessons.prune(store, second.id, "retention", ~U[2026-10-18 00:00:00Z])
    refute File.exists?(Path.join(dir, second.id <> ".json"))
    assert {:error, :pruned} = Lessons.read(store, second.id)
    assert {:error, :pruned} = Lessons.append(store, second)

    assert {:ok, [], nil} =
             Lessons.recall(store, F.context(), F.consumer(), fn _, _ -> flunk("resurrected") end,
               now: ~U[2026-10-19 00:00:00Z]
             )

    assert {:ok, history} = Lessons.history(store)

    assert Enum.any?(
             history,
             &(&1["id"] == second.id and &1["status"] == "pruned" and &1["reason"] == "retention")
           )

    tombstone = File.read!(Path.join(dir, second.id <> ".pruned.json"))
    refute tombstone =~ second.mechanism
  end

  test "tombstone wins after interrupted cleanup and altered records fail closed", %{tmp_dir: dir} do
    store = FileStore.new(dir, F.scope())
    lesson = F.lesson()
    assert :ok = Lessons.append(store, lesson)
    path = Path.join(dir, lesson.id <> ".json")
    bytes = File.read!(path)
    assert :ok = Lessons.prune(store, lesson.id, "retention", ~U[2026-10-18 00:00:00Z])
    File.write!(path, bytes)
    assert {:error, :pruned} = Lessons.read(store, lesson.id)
    assert :ok = Lessons.prune(store, lesson.id, "retention", ~U[2026-10-18 00:00:00Z])
    refute File.exists?(path)

    other = F.lesson(%{"key" => "another"})
    assert :ok = Lessons.append(store, other)
    File.write!(Path.join(dir, other.id <> ".json"), "{}")
    assert {:error, _} = Lessons.read(store, other.id)
    assert {:error, _} = Lessons.append(store, other)
  end

  test "symlinks, oversized files and unavailable storage are refused", %{tmp_dir: dir} do
    real = Path.join(dir, "real")
    File.mkdir!(real)
    link = Path.join(dir, "link")
    File.ln_s!(real, link)
    lesson = F.lesson()
    assert {:error, _} = Lessons.append(FileStore.new(link, F.scope()), lesson)
    store = FileStore.new(real, F.scope())
    outside = Path.join(dir, "outside")
    File.write!(outside, "unchanged")
    File.ln_s!(outside, Path.join(real, lesson.id <> ".json"))
    assert {:error, _} = Lessons.append(store, lesson)
    assert {:error, _} = Lessons.read(store, lesson.id)
    assert File.read!(outside) == "unchanged"
    File.rm!(Path.join(real, lesson.id <> ".json"))
    File.write!(Path.join(real, lesson.id <> ".json"), String.duplicate("x", 2_100_000))
    assert {:error, :lesson_too_large} = Lessons.read(store, lesson.id)
    blocked = Path.join(dir, "blocked")
    File.write!(blocked, "not a directory")
    assert {:error, _} = Lessons.append(FileStore.new(blocked, F.scope()), lesson)
  end

  test "recall and history limits fail visibly without exposing a truncated result", %{
    tmp_dir: dir
  } do
    store = FileStore.new(dir, F.scope())
    assert :ok = Lessons.append(store, F.lesson())
    assert :ok = Lessons.append(store, F.lesson(%{"key" => "different"}))
    commit = fn _, _ -> flunk("over-limit result was released") end

    for opts <- [[max_lessons: 1], [max_bytes: 1]] do
      assert {:error, :lesson_recall_limit} =
               Lessons.recall(
                 store,
                 F.context(),
                 F.consumer(),
                 commit,
                 [now: ~U[2026-10-17 00:00:00Z]] ++ opts
               )
    end

    assert {:error, :lesson_history_limit} =
             Lessons.history(FileStore.new(dir, F.scope(), max_entries: 1))
  end

  test "corrupt tombstones refuse reads and cannot suppress arbitrary history", %{tmp_dir: dir} do
    store = FileStore.new(dir, F.scope())
    lesson = F.lesson()
    assert :ok = Lessons.append(store, lesson)
    path = Path.join(dir, lesson.id <> ".pruned.json")
    File.write!(path, "{}")
    assert {:error, _} = Lessons.read(store, lesson.id)
    assert {:error, _} = Lessons.history(store)
  end
end
