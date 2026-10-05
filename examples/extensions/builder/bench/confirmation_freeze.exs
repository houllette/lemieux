# Writes the frozen confirmation plan before any live dispatch:
#
#     mix run bench/confirmation_freeze.exs
#
# It prepares and seals the fixture inputs, then records both profiles
# verbatim, the digest of every bench file and fixture input, the sample, the
# budget, the runtime, the grader digest, the predeclared decision rule and the
# authoring cost. bench/confirmation.exs refuses to run unless this file
# matches what it loads. The file is written exclusively: re-freezing means
# choosing a new directory, not editing a plan after the fact.
Code.require_file("confirmation_cases.exs", __DIR__)

alias Lemieux.Extension.Profile
alias Lemieux.Learning.Extension.Tree
alias Lemieux.Contract
alias LemieuxBuilderBench.ConfirmationCases

model = System.fetch_env!("LMX_MODEL")
repository = System.fetch_env!("LEMIEUX_EXTENSION_BASE")
root = Path.expand(System.get_env("BUILDER_CONFIRMATION_DIR", "tmp/builder-confirmation"))
iterations = System.fetch_env!("BUILDER_AUTHORING_ITERATIONS") |> String.to_integer()
:ok = File.mkdir_p(root)
inputs = Path.join(root, "inputs")
ids = ConfirmationCases.prepare(inputs, repository)
{:ok, receipt} = Tree.read(Path.join(inputs, "inputs.json"))

bench_files =
  ~w(confirmation.exs confirmation_cases.exs confirmation_grade.exs confirmation_freeze.exs confirmation_control_profile.json)

hashes = Map.new(bench_files, &{&1, Contract.sha256(File.read!(Path.join(__DIR__, &1)))})

control =
  Path.join(__DIR__, "confirmation_control_profile.json") |> File.read!() |> JSON.decode!()

^model = control["model"]
candidate = model |> Lemieux.Learning.Builder.profile() |> Profile.quota(12)

{head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repository)

[req_llm] =
  Regex.run(
    ~r/"req_llm": \{:hex, :req_llm, "([^"]+)"/,
    File.read!(Path.join(repository, "mix.lock")),
    capture: :all_but_first
  )

tool_versions =
  repository
  |> Path.join(".tool-versions")
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Map.new(fn line ->
    [tool, version] = String.split(line, " ", parts: 2)
    {tool, version}
  end)

arms = ["control", "candidate"]
repetitions = 2

sample =
  for id <- ids, repetition <- 1..repetitions, arm <- arms do
    %{
      "case_id" => id,
      "cluster_id" => ConfirmationCases.cluster(id),
      "repetition" => repetition,
      "arm" => arm
    }
  end

started = root |> Path.join("authoring-started.txt") |> File.read!() |> String.trim()
{:ok, started_at, 0} = DateTime.from_iso8601(started)
frozen_at = DateTime.utc_now() |> DateTime.truncate(:second)

plan = %{
  "version" => 1,
  "purpose" =>
    "Independent confirmation of the provisional builder recipe on fresh clusters (roadmap V1). Development exposure; these cases can never become hidden confirmation cases.",
  "exposure" => "development",
  "model" => model,
  "arms" => arms,
  "profiles" => %{
    "control" => control,
    "control_sha256" => Contract.digest(control),
    "control_source" =>
      "archive/procedural-graphs-2026-09-14:docs/implementation/agent-extensions/04-bounded-refinement/evidence/2026-09-14-builder-tuning/default-profile.json, verbatim (file sha256 " <>
        hashes["confirmation_control_profile.json"] <> "); no field needed changing",
    "candidate" => candidate,
    "candidate_sha256" => Contract.digest(candidate),
    "candidate_source" =>
      "Lemieux.Learning.Builder.profile(model) |> Lemieux.Extension.Profile.quota(12) at git " <>
        String.trim(head)
  },
  "bench_files" => hashes,
  "graders" => %{"confirmation_grade.exs" => hashes["confirmation_grade.exs"]},
  "inputs" => %{
    "root" => inputs,
    "receipt_sha256" => receipt["sha256"],
    "files" => receipt["files"]
  },
  "case_ids" => ids,
  "clusters" => Map.new(ids, &{&1, ConfirmationCases.cluster(&1)}),
  "sample" => sample,
  "budget" => %{
    "usage_mode" => "quota",
    "cost_cap_usd" => nil,
    "max_requests_per_attempt" => 12,
    "repetitions" => repetitions,
    "max_concurrency" => 2,
    "max_attempts" => 32,
    "planned_attempts" => length(sample),
    "attempt_timeout_ms" => 180_000,
    "grader_timeout_ms" => 300_000,
    "maximum_direct_requests" => length(sample) * 12
  },
  "runtime" => %{
    "git_head" => String.trim(head),
    "tool_versions" => tool_versions,
    "elixir" => System.version(),
    "otp" => List.to_string(:erlang.system_info(:otp_release)),
    "req_llm" => req_llm,
    "lemieux_version" => Lemieux.version(),
    "router" => "direct",
    "provider" => "zai_coding_plan (Z.AI Coding Plan, quota-billed, no dollar accounting)",
    "workbench" => "mix lemieux.extension.workbench bench/confirmation.exs; run, run-live"
  },
  "decision_rule" =>
    "Accept the candidate only if (1) in every cluster the candidate's accepted attempts are at least the control's, (2) the candidate's accepted attempts overall are strictly more than the control's, and (3) there are zero matched regressions, where a matched pair is the same case id and repetition number and a regression is control accepted with candidate not accepted. Otherwise the verdict is 'not confirmed'. Timeouts, request exhaustion and infrastructure errors count as not accepted for the arm they ran under and stay in the evidence; missing observations are reported as missing and never imputed as zero.",
  "authoring_cost" => %{
    "started_at" => DateTime.to_iso8601(started_at),
    "frozen_at" => DateTime.to_iso8601(frozen_at),
    "wall_clock_seconds" => DateTime.diff(frozen_at, started_at, :second),
    "iterations" => iterations,
    "note" =>
      "Wall clock from the start of reading the background material to writing this file, including grader dry runs; no model requests were made while authoring."
  }
}

path = Path.join(root, "frozen.json")
File.write!(path, [JSON.encode!(plan), ?\n], [:exclusive])
IO.puts("Frozen plan: #{path}")
IO.puts("Frozen plan sha256: #{Contract.sha256(File.read!(path))}")
IO.puts("Planned attempts: #{length(sample)}")
