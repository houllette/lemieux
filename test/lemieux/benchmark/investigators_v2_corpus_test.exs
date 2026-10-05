defmodule Lemieux.Benchmark.InvestigatorsV2CorpusTest do
  @moduledoc """
  Proves the investigators-v2 corpus is worth spending model calls on: every
  case is report-only, so its grader must pass the untouched fixture with the
  reference answer, fail with no answer, and fail with a plausible non-answer.

  v2 exists because v1 tied on both arms of the delegation experiment: a parent
  with `bash` reads a twelve-file fixture in one command. So this test also
  holds every fixture to the size floor that makes a single tool call
  insufficient: at least 250,000 bytes across at least 40 files in at least
  six directories, with at least one file the `bash` tool would truncate (or,
  failing that, more than that cap in every directory). A fixture that shrank
  below the floor would quietly turn the experiment back into v1.

  Every grader runs once per verdict inside `setup_all`, concurrently, so the
  per-case tests below only read a result.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command, as: Grader
  alias Lemieux.Benchmark.Manifest

  @corpus Path.expand("../../../eval/corpus/investigators-v2", __DIR__)
  @manifest Path.join(@corpus, "manifest.json")
  @external_resource @manifest

  # The bash tool's output cap (`Lemieux.Tools.Bash`); a file over it cannot be
  # dumped whole by `cat`, and a directory over it cannot be dumped by `cat *`.
  @bash_cap 30_000
  @min_bytes 250_000
  @min_files 40
  @min_dirs 6

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
        "lemieux-investigators-v2-corpus-#{System.unique_integer([:positive])}"
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

  test "manifest has thirty read-only cases in six clusters of five with complete metadata", %{
    manifest: manifest
  } do
    assert length(manifest.tasks) == 30

    clusters = Enum.group_by(manifest.tasks, & &1.metadata["cluster_id"])
    assert map_size(clusters) == 6

    for {cluster, members} <- clusters do
      assert length(members) == 5, "cluster #{cluster} has #{length(members)} cases, expected 5"
    end

    for task <- manifest.tasks do
      metadata = task.metadata
      assert is_binary(metadata["cluster_id"]) and metadata["cluster_id"] != "", task.id
      assert is_list(metadata["tags"]), task.id

      for tag <- ~w(investigators v2 read report) do
        assert tag in metadata["tags"], "#{task.id}: tags lack #{tag}"
      end

      assert metadata["required_tools"] == ["read"], task.id
      assert Enum.all?(~w(write edit), &(&1 in metadata["forbidden_tools"])), task.id
      assert get_in(metadata, ["safety", "allowed_changed_paths"]) == [], task.id
      assert is_integer(metadata["minimum_files"]) and metadata["minimum_files"] >= 4, task.id
      assert is_binary(metadata["notes"]) and metadata["notes"] != "", task.id
      assert String.length(task.prompt) < 400, "#{task.id}: prompt is not one to three sentences"
      assert task.prompt =~ "without changing any files", "#{task.id}: prompt permits edits"
      refute task.prompt =~ ~r/grader|solution|check\.sh/i, "#{task.id}: prompt leaks the grading"
      assert task.cwd == Path.join([@corpus, "repos", task.id])
      assert File.dir?(task.cwd), "#{task.id}: fixture directory #{task.cwd} is missing"
      assert File.regular?(Path.join([@corpus, "answers", "#{task.id}.txt"])), task.id

      files = fixture_files(task.cwd)
      assert length(files) == metadata["fixture_files"], "#{task.id}: fixture_files is stale"
      assert metadata["minimum_files"] <= length(files), task.id

      bytes = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      assert bytes == metadata["fixture_bytes"], "#{task.id}: fixture_bytes is stale"
    end
  end

  test "every fixture is too large for one tool call and spread across directories", %{
    manifest: manifest
  } do
    for task <- manifest.tasks do
      files = fixture_files(task.cwd)
      bytes = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      assert bytes >= @min_bytes, "#{task.id}: #{bytes} bytes, expected at least #{@min_bytes}"

      assert length(files) >= @min_files,
             "#{task.id}: #{length(files)} files, expected at least #{@min_files}"

      dirs = files |> Enum.map(fn {path, _size} -> Path.dirname(path) end) |> Enum.uniq()

      assert length(dirs) >= @min_dirs,
             "#{task.id}: #{length(dirs)} directories, expected #{@min_dirs}"

      assert Enum.any?(dirs, &String.contains?(&1, "/")),
             "#{task.id}: no directory is nested two levels deep"

      per_dir =
        files
        |> Enum.group_by(fn {path, _size} -> Path.dirname(path) end, fn {_path, size} -> size end)
        |> Enum.map(fn {_dir, sizes} -> Enum.sum(sizes) end)

      assert Enum.any?(files, fn {_path, size} -> size > @bash_cap end) or
               Enum.all?(per_dir, &(&1 > @bash_cap)),
             "#{task.id}: no file over #{@bash_cap} bytes and some directory fits in one bash output"
    end
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
  # is about, so it counts towards neither the file count nor the byte size.
  # Paths are relative to the fixture so directory grouping is by fixture
  # layout, not by where the checkout lives.
  defp fixture_files(cwd) do
    cwd
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&(Path.basename(&1) == "check.sh"))
    |> Enum.map(&{Path.relative_to(&1, cwd), File.stat!(&1).size})
  end
end
