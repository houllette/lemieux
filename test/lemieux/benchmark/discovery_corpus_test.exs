defmodule Lemieux.Benchmark.DiscoveryCorpusTest do
  @moduledoc """
  Proves the discovery corpus is worth running before anyone spends a model
  call on it: every grader is satisfiable (the checked-in solution passes it)
  and none is trivially satisfied (the untouched fixture fails it). A case
  that fails both ways or passes both ways carries no selection signal.

  Every grader is run once per verdict inside `setup_all`, concurrently, so
  the per-case tests below only read a result. That keeps the module fast
  enough to stay in the default suite even with `mix test` graders.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command, as: Grader
  alias Lemieux.Benchmark.Manifest

  @corpus Path.expand("../../../eval/corpus/discovery-v1", __DIR__)
  @manifest Path.join(@corpus, "manifest.json")
  @external_resource @manifest

  @reused_v1 ~w(
    read-before-answer write-new-file edit-existing-file
    run-focused-command recover-after-failure refuse-destructive-request
  )

  # Case ids are read at compile time so each case gets its own named test and
  # a failure names the case rather than the loop that hit it.
  @ids @manifest |> File.read!() |> JSON.decode!() |> Map.fetch!("tasks") |> Enum.map(& &1["id"])

  setup_all do
    {:ok, manifest} = Manifest.read(@manifest)

    root =
      Path.join(
        System.tmp_dir!(),
        "lemieux-discovery-corpus-#{System.unique_integer([:positive])}"
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

  test "manifest has enough cases, enough clusters and complete metadata", %{manifest: manifest} do
    assert length(manifest.tasks) >= 14

    clusters = manifest.tasks |> Enum.map(& &1.metadata["cluster_id"]) |> Enum.uniq()
    assert length(clusters) >= 6

    for task <- manifest.tasks do
      metadata = task.metadata
      assert is_binary(metadata["cluster_id"]) and metadata["cluster_id"] != "", task.id
      assert is_list(metadata["tags"]) and "discovery" in metadata["tags"], task.id
      assert is_list(get_in(metadata, ["safety", "allowed_changed_paths"])), task.id
      assert String.length(task.prompt) < 400, "#{task.id}: prompt is not one to three sentences"
      refute task.prompt =~ ~r/grader|solution/i, "#{task.id}: prompt leaks the grading setup"
      assert File.dir?(task.cwd), "#{task.id}: fixture directory #{task.cwd} is missing"
    end

    for task <- manifest.tasks, "safety" in task.metadata["tags"] do
      # A refusal case changes nothing the request asked for, but it may run
      # the approved alternative its README names, so a directory pattern for
      # that side effect is allowed; a specific file never is.
      allowed = task.metadata["safety"]["allowed_changed_paths"]
      assert Enum.all?(allowed, &String.ends_with?(&1, "/**")), task.id
    end
  end

  test "the six reusable v1 cases point at the v1 fixtures", %{manifest: manifest} do
    v1_root = Path.expand("../v1/repos", @corpus)
    by_id = Map.new(manifest.tasks, &{&1.id, &1})

    for id <- @reused_v1 do
      assert %{cwd: cwd} = by_id[id], "#{id} is not in the manifest"
      assert cwd == Path.join(v1_root, id)
    end

    for task <- manifest.tasks, task.id not in @reused_v1 do
      assert task.cwd == Path.join([@corpus, "repos", task.id])
    end
  end

  test "graders are argv vectors whose scripts live in the fixture", %{manifest: manifest} do
    for task <- manifest.tasks do
      assert [program | args] = task.grader.command
      assert Enum.all?([program | args], &is_binary/1)

      case {program, args} do
        {"sh", ["-c", _script]} -> :ok
        {"sh", [script | _]} -> assert File.regular?(Path.join(task.cwd, script)), task.id
        {"elixir", [script]} -> assert File.regular?(Path.join(task.cwd, script)), task.id
        {"mix", ["test"]} -> assert File.regular?(Path.join(task.cwd, "mix.exs")), task.id
      end
    end
  end

  for id <- @ids do
    @id id
    test "#{id}: grader fails only where the work is missing", %{verdicts: verdicts} do
      verdict = Map.fetch!(verdicts, @id)

      if verdict.mutation? do
        refute verdict.untouched.passed,
               "grader passed the untouched fixture:\n#{verdict.untouched.output}"

        assert verdict.solved.passed,
               "grader failed with the solution applied:\n#{verdict.solved.output}"

        assert verdict.solution_files != [], "no solution files under solutions/#{@id}"

        assert verdict.out_of_scope == [],
               "solution touches paths outside allowed_changed_paths: " <>
                 inspect(verdict.out_of_scope)
      else
        # Without a reference solution the case must be a report, a refusal
        # or a read-only task; otherwise a forgotten solutions directory
        # would pass silently.
        assert verdict.answer || verdict.refusal? || verdict.read_only? || verdict.allowed == [],
               "#{verdict.id} has no reference solution, no answer, no refusal tag and allows writes"

        assert verdict.untouched.passed,
               "grader failed the untouched fixture:\n#{verdict.untouched.output}"

        if verdict.answer do
          refute verdict.unanswered.passed,
                 "answer-graded case passed with an empty answer:\n#{verdict.unanswered.output}"
        end
      end
    end
  end

  defp verdict(task, root) do
    allowed = task.metadata["safety"]["allowed_changed_paths"]
    answer = read_answer(task.id)
    solution_dir = Path.join([@corpus, "solutions", task.id])
    solution_files = files_under(solution_dir)
    # A mutation case is one that ships a reference solution. A refusal case
    # may still allow an approved side effect (the sanctioned cleanup in
    # `refuse-purge-customer-records` removes `tmp/`), and an overlay cannot
    # express a deletion, so the allowlist alone does not decide.
    mutation? = File.dir?(solution_dir)

    untouched = grade(task, Path.join(root, "#{task.id}-untouched"), answer || "", [])

    verdict = %{
      id: task.id,
      allowed: allowed,
      mutation?: mutation?,
      refusal?: "refusal" in (task.metadata["tags"] || []),
      read_only?: Enum.all?(~w(write edit), &(&1 in (task.metadata["forbidden_tools"] || []))),
      answer: answer,
      untouched: untouched,
      solution_files: solution_files,
      out_of_scope: Enum.reject(solution_files, &allowed?(&1, allowed))
    }

    cond do
      mutation? ->
        solved = grade(task, Path.join(root, "#{task.id}-solved"), "", [solution_dir])
        Map.put(verdict, :solved, solved)

      answer ->
        unanswered = grade(task, Path.join(root, "#{task.id}-unanswered"), "", [])
        Map.put(verdict, :unanswered, unanswered)

      true ->
        verdict
    end
  end

  defp grade(task, workspace, answer, overlays) do
    File.mkdir_p!(workspace)
    {:ok, _copied} = File.cp_r(task.cwd, workspace)
    Enum.each(overlays, fn overlay -> {:ok, _copied} = File.cp_r(overlay, workspace) end)

    {:ok, result} = Grader.grade(task.grader, %{task | cwd: workspace}, answer)
    %{passed: result["passed"], output: result["output"]}
  end

  defp read_answer(id) do
    path = Path.join([@corpus, "answers", "#{id}.txt"])
    if File.regular?(path), do: String.trim(File.read!(path))
  end

  defp files_under(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&Path.relative_to(&1, dir))
      |> Enum.sort()
    else
      []
    end
  end

  # Mirrors the safety scorer's rule in `Lemieux.Benchmark.Gate`: an exact
  # path, or a `dir/**` prefix.
  defp allowed?(path, allowed) do
    Enum.any?(allowed, fn
      "*" -> true
      pattern -> path == pattern or prefix_match?(path, pattern)
    end)
  end

  defp prefix_match?(path, pattern) do
    String.ends_with?(pattern, "/**") and
      String.starts_with?(path, String.trim_trailing(pattern, "**"))
  end
end
