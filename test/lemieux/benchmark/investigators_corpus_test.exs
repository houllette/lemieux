defmodule Lemieux.Benchmark.InvestigatorsCorpusTest do
  @moduledoc """
  Proves the investigators corpus is worth spending model calls on: every case
  is report-only, so its grader must pass the untouched fixture with the
  reference answer, fail with no answer, and fail with a plausible non-answer.
  A grader that only checks for a non-empty reply carries no signal about
  whether the investigation found the right fact.

  Every grader runs once per verdict inside `setup_all`, concurrently, so the
  per-case tests below only read a result.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command, as: Grader
  alias Lemieux.Benchmark.Manifest

  @corpus Path.expand("../../../eval/corpus/investigators-v1", __DIR__)
  @manifest Path.join(@corpus, "manifest.json")
  @external_resource @manifest

  # A confident-sounding reply that names nothing. Any grader this passes
  # would also pass a model that never opened a file.
  @wrong_answer "I could not determine the answer from the files in this repository."

  # Case ids are read at compile time so each case gets its own named test and
  # a failure names the case rather than the loop that hit it.
  @ids @manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("tasks") |> Enum.map(& &1["id"])

  setup_all do
    {:ok, manifest} = Manifest.read(@manifest)

    root =
      Path.join(
        System.tmp_dir!(),
        "lemieux-investigators-corpus-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    verdicts =
      manifest.tasks
      |> Task.async_stream(&verdict(&1, root),
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :timer.minutes(3)
      )
      |> Map.new(fn {:ok, verdict} -> {verdict.id, verdict} end)

    %{manifest: manifest, verdicts: verdicts}
  end

  test "manifest has thirty read-only cases across six clusters with complete metadata", %{
    manifest: manifest
  } do
    assert length(manifest.tasks) >= 30

    clusters = manifest.tasks |> Enum.group_by(& &1.metadata["cluster_id"])
    assert map_size(clusters) >= 6

    for {cluster, members} <- clusters do
      assert length(members) >= 3, "cluster #{cluster} has fewer than three cases"
    end

    for task <- manifest.tasks do
      metadata = task.metadata
      assert is_binary(metadata["cluster_id"]) and metadata["cluster_id"] != "", task.id
      assert is_list(metadata["tags"]) and "investigators" in metadata["tags"], task.id
      assert Enum.all?(~w(write edit), &(&1 in metadata["forbidden_tools"])), task.id
      assert get_in(metadata, ["safety", "allowed_changed_paths"]) == [], task.id
      assert is_integer(metadata["minimum_files"]) and metadata["minimum_files"] >= 2, task.id
      assert String.length(task.prompt) < 400, "#{task.id}: prompt is not one to three sentences"
      refute task.prompt =~ ~r/grader|solution|check\.sh/i, "#{task.id}: prompt leaks the grading"
      assert task.cwd == Path.join([@corpus, "repos", task.id])
      assert File.dir?(task.cwd), "#{task.id}: fixture directory #{task.cwd} is missing"
      assert File.regular?(Path.join([@corpus, "answers", "#{task.id}.txt"])), task.id

      fixture_files = fixture_files(task.cwd)
      assert fixture_files in 4..12, "#{task.id}: #{fixture_files} fixture files, expected 4..12"
      assert fixture_files == metadata["fixture_files"], "#{task.id}: fixture_files is stale"
      assert metadata["minimum_files"] <= fixture_files, task.id
    end

    # The corpus exists to measure fan-out, so most questions must not be
    # answerable from one lucky file.
    multi_file = Enum.count(manifest.tasks, &(&1.metadata["minimum_files"] >= 3))
    assert multi_file >= 20, "only #{multi_file} cases need three or more files"
  end

  test "every grader is the fixture's own check script receiving the answer", %{
    manifest: manifest
  } do
    for task <- manifest.tasks do
      assert task.grader.command == ["sh", "check.sh", "{answer}"], task.id
      assert File.regular?(Path.join(task.cwd, "check.sh")), task.id
    end
  end

  for id <- @ids do
    @id id
    test "#{id}: grader passes only the right answer on the untouched fixture", %{
      verdicts: verdicts
    } do
      verdict = Map.fetch!(verdicts, @id)

      assert verdict.answered.passed,
             "grader failed the untouched fixture with the reference answer:\n" <>
               verdict.answered.output

      refute verdict.unanswered.passed,
             "grader passed with an empty answer:\n#{verdict.unanswered.output}"

      refute verdict.wrong.passed,
             "grader passed a reply that names no fact:\n#{verdict.wrong.output}"
    end
  end

  defp verdict(task, root) do
    answer = task.id |> answer_path() |> File.read!() |> String.trim()

    %{
      id: task.id,
      answered: grade(task, Path.join(root, "#{task.id}-answered"), answer),
      unanswered: grade(task, Path.join(root, "#{task.id}-unanswered"), ""),
      wrong: grade(task, Path.join(root, "#{task.id}-wrong"), @wrong_answer)
    }
  end

  defp grade(task, workspace, answer) do
    File.mkdir_p!(workspace)
    {:ok, _copied} = File.cp_r(task.cwd, workspace)
    {:ok, result} = Grader.grade(task.grader, %{task | cwd: workspace}, answer)
    %{passed: result["passed"], output: result["output"]}
  end

  defp answer_path(id), do: Path.join([@corpus, "answers", "#{id}.txt"])

  # The check script is part of the grader, not of the material the question
  # is about, so it does not count towards the fixture size.
  defp fixture_files(cwd) do
    cwd
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "check.sh"))
    |> length()
  end
end
