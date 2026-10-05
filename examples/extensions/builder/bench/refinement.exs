# Trusted host configuration. Snapshots inputs before either arm runs.
Code.require_file("refinement_cases.exs", __DIR__)
model = System.fetch_env!("LMX_MODEL")
repository = System.fetch_env!("LEMIEUX_EXTENSION_BASE")
root = Path.expand(System.get_env("BUILDER_REFINEMENT_DIR", "tmp/refinement"))
# Reopening verifies the original snapshot. Use a new directory for new inputs.
:ok = File.mkdir_p(root)
inputs = Path.join(root, "inputs")
ids = LemieuxBuilderBench.RefinementCases.prepare(inputs, repository)
grader = Path.join(__DIR__, "refinement_grade.exs")

tasks =
  Enum.map(ids, fn id ->
    %{
      "id" => id,
      "prompt" => "Read brief.txt and carry out its instructions.",
      "cwd" => Path.join(inputs, id),
      "timeout_ms" => 180_000,
      "metadata" => %{
        "cluster_id" =>
          if(String.starts_with?(id, "audit_"), do: "source_audit", else: "project_maintenance"),
        "exposure" => "development"
      },
      "grader" => %{
        "command" => ["elixir", "--erl", "+S 2:2", grader, "{cwd}", "{task_id}", inputs]
      }
    }
  end)

suite = Path.join(root, "suite.json")
File.write!(suite, JSON.encode!(%{"version" => 1, "tasks" => tasks}))
provider = Keyword.get_lazy(binding(), :host_provider, &Lemieux.CLI.Runtime.provider/0)

{:ok, _} =
  Lemieux.Learning.Extension.ModelSearch.select(provider, [
    %{"model" => model, "efforts" => ["default", "low"]}
  ])

profile =
  Lemieux.Learning.Builder.profile(model, reasoning_effort: "default")
  |> Lemieux.Extension.Profile.quota(12)

profiles = [
  {"default", profile},
  {"low", put_in(profile, ["options", "reasoning_effort"], "low")}
]

agents =
  Enum.map(profiles, fn {name, profile} ->
    {name, Lemieux.Learning.Builder,
     fn ->
       {:ok, opts, _} = Lemieux.Extension.Profile.configure(profile, provider: provider)
       opts
     end}
  end)

[
  suite: suite,
  workbench_dir: Path.join(root, "workbench"),
  execution: :live,
  search_provider: provider,
  agents: agents,
  benchmark_options: [
    repetitions: 2,
    max_concurrency: 2,
    usage_mode: :quota,
    max_attempts: 16,
    max_requests_per_attempt: 12
  ]
]
