# Offline: mix run docs/qualification/2026-10-21-research-sequence/verify.exs
alias Lemieux.Contract
alias Lemieux.Learning.Qualification
alias Lemieux.Learning.Qualification.Endpoints
alias Lemieux.Learning.Qualification.Paired

read = fn path -> path |> File.read!() |> JSON.decode!() end

checksums =
  __DIR__
  |> Path.join("SHA256SUMS")
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Map.new(fn line ->
    [digest, relative] = String.split(line, "  ", parts: 2)
    true = Regex.match?(~r/^[0-9a-f]{64}$/, digest)
    true = Path.type(relative) == :relative
    false = ".." in Path.split(relative)
    true = Contract.sha256(File.read!(Path.join(__DIR__, relative))) == digest
    {relative, digest}
  end)

files =
  __DIR__
  |> Path.join("**/*")
  |> Path.wildcard()
  |> Enum.filter(&File.regular?/1)
  |> Enum.map(&Path.relative_to(&1, __DIR__))
  |> Enum.reject(&(&1 == "SHA256SUMS"))

true = Enum.sort(files) == Enum.sort(Map.keys(checksums))
reports = Path.wildcard(Path.join(__DIR__, "**/report.json"))

for path <- reports do
  root = Path.dirname(path)
  report = read.(path)
  plan = read.(Path.join(root, "plan.json"))
  audit = read.(Path.join(root, "audit.json"))
  :ok = Qualification.verify(plan)
  :ok = Contract.verify_digest(report, "sha256")
  :ok = Contract.verify_digest(report["runtime"], "sha256")
  true = report["plan_sha256"] == plan["sha256"]
  true = audit["source_report_bytes_sha256"] == Contract.sha256(File.read!(path))
  rows = report["rows"] ++ report["warmup_rows"]
  episodes = Map.new(audit["episodes"], &{{&1["task_id"], &1["arm"], &1["repetition"]}, &1})
  true = length(rows) == map_size(episodes)

  for row <- rows do
    episode = Map.fetch!(episodes, {row["task_id"], row["arm"], row["repetition"]})
    true = episode["source_evidence_bytes_sha256"] == row["evidence_sha256"]
    true = episode["ledger_tokens"] == row["tokens"]

    if episode["physical_dispatches"] do
      true = map_size(episode["physical_dispatches"]) == row["requests"]
      true = episode["meter_matches_ledger"]

      true =
        Enum.sum(Enum.map(episode["physical_dispatches"], fn {_, item} -> item["tokens"] end)) ==
          row["tokens"]
    end
  end

  {:ok, recomputed} = Qualification.report(plan, report["rows"])

  for {key, value} <- Map.drop(recomputed, ~w(sha256 resource_policy)),
      do: true = report[key] == value

  if plan["schema_version"] == 4 do
    {:ok, endpoints} = Endpoints.report(plan, report["rows"])
    true = endpoints == report["research_endpoints"]
  end

  if report["budget_stops"] do
    expected =
      Map.new(Enum.group_by(report["rows"], & &1["arm"]), fn {arm, rows} ->
        {arm,
         %{
           "original" => Enum.count(rows, & &1["original_budget_stop"]),
           "selected" => Enum.count(rows, & &1["selected_budget_stop"]),
           "probes" => Enum.sum(Enum.map(rows, & &1["probe_budget_stops"]))
         }}
      end)

    true = report["budget_stops"]["by_arm"] == expected
  end

  if get_in(report, ["runtime", "driver"]) do
    bytes = File.read!(Path.join(__DIR__, "development-driver.exs"))
    true = Contract.sha256(bytes) == report["runtime"]["driver"]["executed_sha256"]
  end

  for mechanism_path <- Path.wildcard(Path.join(root, "mechanism.json")) do
    mechanism = read.(mechanism_path)
    :ok = Contract.verify_digest(mechanism, "sha256")
    true = mechanism["report_sha256"] == report["sha256"]
    true = mechanism["plan_sha256"] == plan["sha256"]

    true =
      Enum.sort(mechanism["evidence_sha256"]) ==
        Enum.sort(Enum.map(report["rows"], & &1["evidence_sha256"]))
  end
end

excluded = read.(Path.join(__DIR__, "excluded-seed.json"))
true = excluded["excluded_from_efficacy"] and not excluded["row"]["qualification_complete"]
true = map_size(excluded["physical_dispatches"]) == excluded["row"]["requests"]

true =
  Enum.sum(Enum.map(excluded["physical_dispatches"], fn {_, item} -> item["tokens"] end)) ==
    excluded["row"]["tokens"]

feasibility = read.(Path.join(__DIR__, "confirmation-feasibility.json"))
assumptions = feasibility["registered_quality_assumptions"]

bench = read.(Path.join(__DIR__, "bench-corpus-assessment.json"))
true = bench["inference_calls"] == 0
true = bench["terminal_bench"]["all_tasks_marked_development"]
true = bench["swebench"]["prepared_sample_repository_groups"] == 10
true = Enum.sum(Map.values(bench["swebench"]["prepared_sample_repositories"])) == 50
true = map_size(bench["swebench"]["local_source_repositories"]) == 18
true = Enum.sum(Map.values(bench["swebench"]["local_source_repositories"])) == 2519

false =
  bench["confirmation_requirements"]["prepared_sufficiently_powered_unexposed_manifest_found"]

for {n, recorded} <- [
      {89, feasibility["optimistic_quality_power"]},
      {110, feasibility["example_powered_size"]}
    ] do
  power = Paired.power(n, assumptions, assumptions["alpha"] / assumptions["primary_tests"])
  true = abs(recorded["per_comparison"] - power["per_comparison"]) < 1.0e-12

  true =
    abs(recorded["three_comparison_lower_bound"] - max(0.0, 3 * power["per_comparison"] - 2)) <
      1.0e-12
end

IO.puts(
  "Verified #{length(reports)} recorded study reports, the excluded seed and prospective power offline."
)
