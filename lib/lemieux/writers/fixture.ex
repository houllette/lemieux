defmodule Lemieux.Writers.Fixture do
  @moduledoc """
  An offline matched workload using real sessions, worktrees, patches and checks.

  The two arms use identical Scripted providers and allowances; only writer
  concurrency differs. Artificial provider latency exposes scheduling mechanics,
  not a model-quality advantage. All transcripts and artifacts remain in the
  requested directory. This module never chooses a hosted provider.
  """
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Writers
  alias Lemieux.Writers.Artifact
  alias Lemieux.Writers.Evaluation
  alias Lemieux.Writers.Plan
  alias Lemieux.Writers.Worktree

  @usage %{"input_tokens" => 10, "output_tokens" => 5, "cost_usd" => 0.01}
  @limits [max_requests: 10, max_cost_usd: 1.0]
  @files %{"alpha.txt" => "alpha\n", "beta.txt" => "beta\n"}

  @doc "Runs once in a new directory and retains reviewable receipts."
  @spec run(directory :: Path.t()) :: {:ok, map()} | {:error, term()}
  def run(directory) do
    with :ok <- File.mkdir(directory),
         {:ok, serial} <- arm(Path.join(directory, "serial"), 1),
         {:ok, parallel} <- arm(Path.join(directory, "parallel"), 2),
         {:ok, receipt} <- Evaluation.compare(serial, parallel),
         :ok <- File.write(Path.join(directory, "comparison.json"), JSON.encode!(receipt)) do
      {:ok, receipt}
    end
  end

  defp arm(directory, concurrency) do
    root = Path.join(directory, "repo")

    with :ok <- File.mkdir_p(root), :ok <- repository(root) do
      runtime = :"writers_fixture_#{System.unique_integer([:positive])}"
      {:ok, supervisor} = Lemieux.Supervisor.start_link(name: runtime)

      provider = Scripted.new([])

      try do
        execute(root, directory, runtime, concurrency, provider)
      after
        Supervisor.stop(supervisor)
        if Process.alive?(elem(provider, 1)), do: Agent.stop(elem(provider, 1))
      end
    end
  end

  defp execute(root, directory, runtime, concurrency, root_provider) do
    store = JSONL.new(Path.join(directory, "sessions"))

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        store: store,
        cwd: root,
        provider: root_provider,
        model: "test:model",
        tools: [],
        job_limits: @limits
      )

    plans =
      Enum.map(Enum.sort(@files), fn {path, content} ->
        Plan.new(
          id: Path.rootname(path),
          task: "Create #{path} containing #{inspect(content)}",
          paths: [path],
          tools: ["write"]
        )
      end)

    workspace = Worktree.new(root: root, directory: Path.join(directory, "writers"))
    started = System.monotonic_time(:millisecond)

    opts = [
      workspace: workspace,
      factory: &factory/2,
      max_active: concurrency,
      authority: :fixture,
      authorize: &authorize/3,
      verify: &verify/3,
      checks: &checks/1
    ]

    with {:ok, group} <- Writers.start(parent, plans, opts) do
      try do
        with {:ok, %{status: :ready} = result} <- Writers.await(group),
             {:ok, _} <-
               Writers.integrate(group, Enum.map(result.writers, & &1.artifact.digest), :fixture),
             {:ok, %{base_revision: revision}} <- base(workspace) do
          {:ok, observation(root, result, revision, started)}
        else
          other -> {:error, {:fixture_failed, other}}
        end
      after
        Writers.close(group, :fixture)
      end
    end
  end

  defp factory(plan, _workspace) do
    path = hd(plan.paths)

    report =
      JSON.encode!(%{"summary" => plan.id, "critical_findings" => [path], "uncertainties" => []})

    turns = [
      Scripted.tool_call("write", "write", %{"path" => path, "content" => @files[path]},
        usage: @usage
      ),
      Scripted.complete(report, usage: @usage)
    ]

    provider = Scripted.new(Enum.map(turns, &Scripted.delayed(80, &1)), estimated_cost_usd: 0.01)

    {:ok,
     [
       provider: provider,
       model: "test:model",
       tools: [Lemieux.Tools.Write],
       compact_at: nil,
       hooks: [session_end: fn _reason, _ctx -> Agent.stop(elem(provider, 1)) end]
     ]}
  end

  defp authorize(_action, _context, :fixture), do: :ok
  defp authorize(_action, _context, _principal), do: {:error, :unauthorized}

  defp verify(workspace, plan, result) do
    path = hd(plan.paths)

    if File.read(Path.join(workspace.cwd, path)) == {:ok, @files[path]} and
         result.report["critical_findings"] == [path],
       do: {:ok, %{"status" => "passed", "check" => "literal file and finding"}},
       else: {:error, :fixture_requirements_missing}
  end

  defp checks(cwd) do
    if Enum.all?(@files, fn {path, content} ->
         File.read(Path.join(cwd, path)) == {:ok, content}
       end),
       do: {:ok, %{"status" => "passed", "check" => "both literal file requirements"}},
       else: {:error, :fixture_requirements_missing}
  end

  defp base({_module, state}), do: {:ok, state}

  defp observation(root, result, revision, started) do
    {:ok, snapshot} = Git.snapshot(root)
    {:ok, changes} = Git.changed(root, revision <> "^{tree}", snapshot.tree)
    changed = Enum.map(changes, &elem(&1, 1)) |> Enum.sort()
    unauthorized = length(changed -- Map.keys(@files))
    artifacts = Enum.map(result.writers, & &1.artifact)

    lost_findings =
      Enum.count(artifacts, fn artifact ->
        report = artifact.report_path |> File.read!() |> JSON.decode!()
        report["report"]["critical_findings"] != artifact.paths
      end)

    %{
      "case_id" => "two_independent_files.v1",
      "base_revision" => revision,
      "policy_digest" => Artifact.hash("Scripted test:model/write/requests=10/USD=1"),
      "grader_digest" =>
        Artifact.hash("literal alpha,beta contents and complete critical findings v1"),
      "source" => "scripted",
      "quality" =>
        Enum.count(@files, fn {path, content} ->
          File.read(Path.join(root, path)) == {:ok, content}
        end),
      "requests" => result.budget.requests,
      "spent_usd" => result.budget.spent_usd,
      "wall_ms" => System.monotonic_time(:millisecond) - started,
      "violations" => %{
        "unauthorized_writes" => unauthorized,
        "missing_effects" => length(Map.keys(@files) -- changed),
        "lost_findings" => lost_findings
      },
      "evidence" => %{
        "artifacts" => Enum.map(artifacts, &Artifact.reference/1),
        "transcripts" => Enum.map(result.writers, & &1.transcript_id)
      }
    }
  end

  defp repository(root) do
    with :ok <- git(root, ["init", "--quiet", "--template="]),
         :ok <- File.write(Path.join(root, "initial.txt"), "fixture\n"),
         :ok <- git(root, ["add", "initial.txt"]),
         do: git(root, ["commit", "--quiet", "-m", "fixture"])
  end

  defp git(root, args) do
    config = [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "core.fsmonitor=false",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.autocrlf=false",
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid"
    ]

    env = [
      {"GIT_DIR", nil},
      {"GIT_WORK_TREE", nil},
      {"GIT_INDEX_FILE", nil},
      {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
      {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
    ]

    case System.cmd("git", config ++ args, cd: root, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:git, status, output}}
    end
  end
end
