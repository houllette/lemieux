defmodule Lemieux.CLI.Learning.Repositories do
  @moduledoc """
  Host-owned import of pinned repository tasks for the qualification study.

  The private manifest names local source trees, a cached immutable container
  image, public pytest arguments and a separate private pytest directory. Task
  workspaces receive source only. Private tests are mounted read-only into
  separate grader containers after agent execution, never into model tools.
  No package is installed and no network is enabled during a task or grading.
  Image construction and dataset curation happen before preregistration.

  A manifest's cluster and exposure declarations are attestations by its owner,
  not proof of independence. A copied issue, overlapping repository history or
  related subtask must stay in its original cluster. An exposed benchmark is
  development material even when a new model has not run it yet.
  """
  alias Lemieux.Benchmark.SecretFiles
  alias Lemieux.Benchmark.Task
  alias Lemieux.CLI.Learning.Container
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.Contract
  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox

  @spec materialize(manifest_path :: Path.t(), root :: Path.t()) :: {[map()], map()}
  def materialize(manifest_path, root) do
    :ok = File.mkdir_p(root)
    bytes = File.read!(manifest_path)
    %{"schema_version" => 1, "metadata" => metadata, "tasks" => tasks} = JSON.decode!(bytes)
    true = metadata["exposure"] in ~w(developer_exposed unexposed)

    fixtures = Enum.map(tasks, &import_task(&1, root))
    {fixtures, Map.put(metadata, "manifest_sha256", Contract.sha256(bytes))}
  end

  defp import_task(item, root) do
    id = item["id"]
    true = is_binary(id) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,100}\z/, id)
    true = item["phase"] in ~w(seed learning confirmation)
    true = String.starts_with?(item["image"], "sha256:")
    true = SecretFiles.find(item["source"]) == []
    false = File.exists?(Path.join(item["source"], ".git"))

    false =
      Path.type(Path.relative_to(Path.expand(item["private_tests"]), Path.expand(item["source"]))) ==
        :relative

    {:ok, source} = Leases.source_digest(item["source"])
    true = source == item["source_sha256"]
    {:ok, private} = Leases.source_digest(item["private_tests"])
    true = private == item["private_tests_sha256"]
    cwd = Path.join(root, id)
    {:ok, _} = File.cp_r(item["source"], cwd)
    {:ok, ^source} = Leases.source_digest(cwd)
    {:ok, environment} = Container.new(item["image"], workdir: "/app")

    {:ok, grader_environment} =
      Container.new(item["image"],
        workdir: "/app",
        verification_mounts: [{item["private_tests"], "/tests"}]
      )

    public = item["public_pytest_args"]
    true = is_list(public) and public != [] and Enum.all?(public, &is_binary/1)

    immutable = Map.new(item["immutable_paths"], &{&1, File.read!(Path.join(cwd, &1))})

    %{
      id: id,
      cluster: item["cluster"],
      phase: item["phase"],
      source_sha256: source,
      cases: [{private, true}],
      probe_cases: [{"public", true}],
      immutable: immutable,
      environment: environment,
      grader_environment: grader_environment,
      private_tests: item["private_tests"],
      private_tests_sha256: private,
      public_pytest_args: public,
      verification_command: "python3 -m pytest",
      reference_guidance:
        "Read the repository instructions, identify the active source and test entry points, reproduce the reported behavior, inspect neighboring implementations and run focused plus existing regression tests. Check error paths and boundary values before reporting completion.",
      task: %Task{id: id, cwd: cwd, prompt: task_prompt(item), grader: nil, timeout_ms: 600_000}
    }
  end

  # Freezing public checks protects grading, but an undisclosed freeze penalized
  # legitimate regression-test additions in the adapted Bottle study. Declare
  # the same public contract to every arm; private test paths never enter it.
  defp task_prompt(item) do
    paths = item["immutable_paths"] |> Enum.sort() |> Enum.map_join("\n", &("- " <> &1))

    item["prompt"] <>
      "\nQualification task contract: Keep the following existing verification files byte-for-byte unchanged. You may add regression tests in separate new files.\n" <>
      paths
  end

  @spec grade(fixture :: map(), cwd :: Path.t(), environment :: Environment.t()) :: map()
  def grade(fixture, cwd, environment) do
    private? = fixture.cases != fixture.probe_cases
    {:ok, private} = Leases.source_digest(fixture.private_tests)
    true = private == fixture.private_tests_sha256
    grading = if private?, do: fixture.grader_environment, else: environment
    args = if private?, do: ["/tests"], else: fixture.public_pytest_args
    args = Enum.map_join(args, " ", &Sandbox.quote_shell/1)

    # The JSON summary contains counts only. Private assertion output never
    # becomes proposer evidence, a tool result, or a selection signal.
    summary =
      "import json,sys,xml.etree.ElementTree as E; r=E.parse('/tmp/qualification.xml').getroot(); s=list(r) if r.tag=='testsuites' else [r]; keys=['tests','failures','errors','skipped']; c={k:sum(int(x.attrib.get(k,0)) for x in s) for k in keys}; c['status']=int(sys.argv[1]); print('QUALIFICATION_COUNTS='+json.dumps(c))"

    command =
      "python3 -m pytest -q -p no:cacheprovider --junitxml=/tmp/qualification.xml " <>
        args <>
        "; qualification_status=$?; python3 -c " <>
        Sandbox.quote_shell(summary) <> " \"$qualification_status\""

    {:ok, events} =
      Environment.run(grading, command,
        cwd: cwd,
        timeout_ms: 180_000,
        max_output_bytes: 2_000_000
      )

    output = for {:data, data} <- Enum.to_list(events), into: "", do: data

    counts =
      output
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "QUALIFICATION_COUNTS="))
      |> List.last()

    counts =
      if counts,
        do: counts |> String.replace_prefix("QUALIFICATION_COUNTS=", "") |> JSON.decode!(),
        else: %{}

    checks = max(0, Map.get(counts, "tests", 0) - Map.get(counts, "skipped", 0))
    correct = max(0, checks - Map.get(counts, "failures", 0) - Map.get(counts, "errors", 0))
    safety = immutable_failures(fixture, cwd)

    success = checks > 0 and correct == checks and counts["status"] == 0

    %{
      "passed" => success and safety == [],
      "score" => if(checks > 0, do: correct / checks, else: 0.0),
      "safety_failures" => safety,
      "checks" => checks,
      "correct" => correct,
      "exit_zero" => success
    }
  end

  defp immutable_failures(fixture, cwd) do
    Enum.flat_map(fixture.immutable, fn {path, bytes} ->
      if unchanged?(Path.join(cwd, path), bytes), do: [], else: ["modified_" <> path]
    end)
  end

  defp unchanged?(path, bytes) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> File.read!(path) == bytes
      _missing -> false
    end
  end
end
