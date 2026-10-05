# Trusted host configuration for the independent confirmation of the builder
# recipe (roadmap V1). It snapshots fresh inputs before either arm runs and
# refuses to dispatch unless the frozen plan already on disk names exactly
# these bench files, profiles and inputs, so nothing can change between the
# freeze and the run without the run stopping.
Code.require_file("confirmation_cases.exs", __DIR__)

alias Lemieux.Learning.Extension.ModelSearch
alias Lemieux.Extension.Profile
alias Lemieux.Contract
alias LemieuxBuilderBench.ConfirmationCases

model = System.fetch_env!("LMX_MODEL")
repository = System.fetch_env!("LEMIEUX_EXTENSION_BASE")
root = Path.expand(System.get_env("BUILDER_CONFIRMATION_DIR", "tmp/builder-confirmation"))
# Reopening verifies the original snapshot. Use a new directory for new inputs.
:ok = File.mkdir_p(root)
inputs = Path.join(root, "inputs")
ids = ConfirmationCases.prepare(inputs, repository)
grader = Path.join(__DIR__, "confirmation_grade.exs")

tasks =
  Enum.map(ids, fn id ->
    %{
      "id" => id,
      "prompt" => "Read brief.txt and carry out its instructions.",
      "cwd" => Path.join(inputs, id),
      "timeout_ms" => 180_000,
      "metadata" => %{
        "cluster_id" => ConfirmationCases.cluster(id),
        "exposure" => "development"
      },
      "grader" => %{
        "command" => [
          "elixir",
          "--erl",
          "+S 2:2",
          grader,
          "{cwd}",
          "{task_id}",
          inputs,
          repository
        ]
      }
    }
  end)

suite = Path.join(root, "suite.json")
File.write!(suite, JSON.encode!(%{"version" => 1, "tasks" => tasks}))

# The control is the archived original: default-profile.json from the
# 2026-09-14 tuning evidence, byte for byte. The candidate is the recipe the
# library ships today for this model, built exactly as bench/refinement.exs
# builds its arms. Both arms run the same module with the same workflow tool.
control_bytes = File.read!(Path.join(__DIR__, "confirmation_control_profile.json"))

"11da6a61726b5676f0a671710aef7f3e464713c9327fe185247ce51507e49afb" =
  Contract.sha256(control_bytes)

control = JSON.decode!(control_bytes)
^model = control["model"]
candidate = model |> Lemieux.Learning.Builder.profile() |> Profile.quota(12)

provider = Keyword.get_lazy(binding(), :host_provider, &Lemieux.CLI.Runtime.provider/0)

# Only the direct Z.AI Coding Plan connection is authorized for this campaign.
# A host configured for an Ixway gateway would route both arms through the
# gateway's catalog and billing instead; set LMX_ROUTER=direct for this run.
# An Ixway provider carries its connection as a route, which
# `Lemieux.Ixway.connection/1` reads back; matching an `:ixway` field, as this
# once did, never fired.
if Lemieux.Ixway.connection(provider) != nil do
  raise ArgumentError, "confirmation requires the direct provider; set LMX_ROUTER=direct"
end

{:ok, _} = ModelSearch.select(provider, [%{"model" => model, "efforts" => ["default", "low"]}])
# The maintenance brief dictates a shortlist that save_models must be able to
# validate; if the catalog no longer advertises it, neither arm could pass.
{:ok, _} = ModelSearch.select(provider, ConfirmationCases.shortlist())

frozen = Path.join(root, "frozen.json") |> File.read!() |> JSON.decode!()
true = frozen["profiles"]["control"] == control
true = frozen["profiles"]["candidate"] == candidate

for {file, sha256} <- frozen["bench_files"] do
  ^sha256 = Contract.sha256(File.read!(Path.join(__DIR__, file)))
end

{:ok, receipt} = Lemieux.Learning.Extension.Tree.read(Path.join(inputs, "inputs.json"))
true = frozen["inputs"]["receipt_sha256"] == receipt["sha256"]
true = frozen["case_ids"] == ids

agents =
  Enum.map([{"control", control}, {"candidate", candidate}], fn {name, profile} ->
    {name, Lemieux.Learning.Builder,
     fn ->
       {:ok, opts, _} = Profile.configure(profile, provider: provider)
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
    max_attempts: 32,
    max_requests_per_attempt: 12
  ]
]
