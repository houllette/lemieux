# Provider-free integrity and consistency checks; private trajectories stay private.
alias Lemieux.CLI.Learning.Calibration
alias Lemieux.Contract
alias Lemieux.Learning.Extension.Export

root = __DIR__
read = fn name -> root |> Path.join(name) |> File.read!() |> JSON.decode!() end

for line <- root |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true) do
  [expected, name] = String.split(line, "  ", parts: 2)
  true = Path.type(name) == :relative
  false = Enum.any?(Path.split(name), &(&1 in [".", ".."]))
  path = Path.join(root, name)
  {:ok, %File.Stat{type: :regular}} = File.lstat(path)
  true = Contract.sha256(File.read!(path)) == expected
end

for name <-
      ~w(synthetic-planning synthetic-plan synthetic-report synthetic-audit pint-planning pint-plan pint-report pint-audit pint-controls portable-export power-planning) do
  :ok = Contract.verify_digest(read.(name <> ".json"), "sha256")
end

for prefix <- ~w(synthetic pint) do
  registration = read.(prefix <> "-registration.json")
  planning = read.(prefix <> "-planning.json")
  plan = read.(prefix <> "-plan.json")
  report = read.(prefix <> "-report.json")
  audit = read.(prefix <> "-audit.json")
  rebuilt = Calibration.report(plan, report["rows"])
  true = Map.take(report, Map.keys(rebuilt)) == rebuilt
  true = planning["registration_sha256"] == Contract.digest(registration)
  true = planning["dispatches"] == 0 and planning["credentials_prepared"] == false
  true = report["plan_sha256"] == plan["sha256"]
  true = audit["report_sha256"] == report["sha256"]
  true = report["execution_complete"] and report["unknown_token_rows"] == 0
  true = Enum.map(audit["episodes"], & &1["row"]) == report["rows"]

  true =
    Enum.all?(audit["episodes"], fn episode ->
      episode["row_matches_physical_meter"] and
        Enum.all?(episode["transcript_verified"], &elem(&1, 1))
    end)

  true = plan["runtime"]["revision"] == "404737075f022d0384d41742c66cb2eca7832f3a"
  true = plan["runtime"]["source_tree_clean"]
end

synthetic = read.("synthetic-report.json")
pint = read.("pint-report.json")
true = length(synthetic["rows"]) == 16 and Enum.all?(synthetic["rows"], & &1["passed"])
true = length(pint["rows"]) == 6
true = Enum.count(pint["rows"], &(&1["arm"] == "disabled" and &1["passed"])) == 1
true = read.("synthetic-selection.json")["eligible_streams"] == []
true = read.("pint-selection.json")["eligible_targets"] == []

for selection <- [read.("synthetic-selection.json"), read.("pint-selection.json")] do
  true = selection["private_confirmation_used_for_selection"] == false
end

final = pint["study_allowance"]
:ok = Contract.verify_digest(final, "sha256")
prior = synthetic["study_allowance"]
true = prior["deadline_ms"] == final["deadline_ms"] and prior["limits"] == final["limits"]
true = Map.take(final["records"], Map.keys(prior["records"])) == prior["records"]
records = Map.values(final["records"])
true = length(records) == 266 and Enum.all?(records, &(&1["status"] == "completed"))
true = Enum.sum(Enum.map(records, & &1["usage"]["tokens"])) == 3_497_117
true = final["accounting"]["requests"] == 266
true = final["accounting"]["tokens"] == 3_497_117
true = final["accounting"]["learning_requests"] == 0
true = final["job_budget"]["active"] == 0
true = final["job_budget"]["max_requests"] == 1_200
true = final["limits"]["max_tokens"] == 8_000_000

controls = read.("pint-controls.json")
pint_plan = read.("pint-plan.json")

true =
  controls["metadata"]["manifest_sha256"] == pint_plan["runtime"]["corpus"]["manifest_sha256"]

true = length(controls["cases"]) == 3

true =
  Enum.all?(controls["cases"], fn item ->
    item["positive_public"]["passed"] and item["positive_private"]["passed"] and
      not item["negative_public"]["passed"] and not item["negative_private"]["passed"]
  end)

portable = read.("portable-export.json")
:ok = Export.verify(Path.join(root, "portable-package"))
export = read.("portable-package/lemieux-extension-export.json")
true = export["sha256"] == portable["package_sha256"]
true = portable["qualification"] == "unassessed"
true = portable["independent_confirmation"] == "not_run"
true = portable["hosted_requests"] == 0
true = portable["before"]["records"] == portable["after_undo"]["records"]
true = portable["installed_consumer"]["resolved_assets"] == portable["applied"]["assets"]
true = portable["installed_consumer"]["rolled_back"]
false = portable["installed_consumer"]["library_application_callback"]
true = read.("benchmark-host.json")["qualified"]
true = read.("cleanup.json")["owned_task_worktree_containers_remaining"] == 0
true = read.("review.json")["blocking_findings"] == []
true = read.("review.json")["reviewed_tree_equals_merged_tree"]

IO.puts("Packet byte integrity and public report consistency passed; no provider calls made.")
