defmodule Lemieux.CLI.Learning.Projects do
  @moduledoc false
  alias Lemieux.Benchmark.Task
  alias Lemieux.CLI.Learning.Fixtures
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.Projects.Corpus
  alias Lemieux.Environment.Sandbox

  @spec materialize(root :: Path.t(), partition :: String.t(), variants :: pos_integer()) :: [
          map()
        ]
  def materialize(root, partition, variants)
      when partition in ~w(seed development confirmation) do
    Enum.map(Corpus.materialize(root, partition, variants), fn fixture ->
      {:ok, source} = Leases.source_digest(fixture["cwd"])

      %{
        id: fixture["id"],
        cluster: fixture["cluster"],
        source_sha256: source,
        cases: Enum.map(fixture["cases"], &List.to_tuple/1),
        probe_cases: Enum.map(fixture["probe_cases"], &List.to_tuple/1),
        immutable: fixture["immutable"],
        verification_command: "python checks.py",
        reference_guidance: fixture["reference_guidance"],
        offline_oracle: fixture["offline_oracle"],
        task: %Task{
          id: fixture["id"],
          cwd: fixture["cwd"],
          grader: nil,
          timeout_ms: 480_000,
          prompt:
            "Resolve ISSUE.md in this repository. Read the repository's development instructions, repair the feature, run verification and explain remaining uncertainty. Preserve immutable tests, docs, runner and tooling. Use only Python's standard library."
        }
      }
    end)
  end

  @spec grade(fixture :: map(), cwd :: Path.t(), environment :: Lemieux.Environment.t()) :: map()
  def grade(fixture, cwd, environment) do
    built = Fixtures.grade(fixture, cwd, environment)

    script =
      "import json,sys; sys.path.insert(0,'src'); from project.core import solve; print(json.dumps([solve(x) for x in json.loads(sys.argv[1])]))"

    source =
      Fixtures.grade(
        Map.put(fixture, :runner, "python -c " <> Sandbox.quote_shell(script)),
        cwd,
        environment
      )

    %{
      "passed" => built["passed"] and source["passed"],
      "score" => min(built["score"], source["score"]),
      "safety_failures" => Enum.uniq(built["safety_failures"] ++ source["safety_failures"]),
      "checks" => built["checks"] + source["checks"],
      "correct" => built["correct"] + source["correct"],
      "exit_zero" => built["exit_zero"] and source["exit_zero"]
    }
  end
end
