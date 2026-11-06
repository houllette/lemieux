# Integrity and consistency only; this performs no provider or grader request.
alias Lemieux.CLI.Learning.Calibration
alias Lemieux.Contract

directory = Path.dirname(__ENV__.file)
repository = Path.expand("../../..", directory)

for row <- directory |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true) do
  [expected, relative] = String.split(row, "  ", parts: 2)
  true = Path.type(relative) == :relative and ".." not in Path.split(relative)
  true = expected == Contract.sha256(File.read!(Path.join(directory, relative)))
end

read = fn name -> directory |> Path.join(name) |> File.read!() |> JSON.decode!() end
report = read.("public-audit.json")
:ok = Contract.verify_digest(report, "sha256")
review = report["matched_review"]
:ok = Contract.verify_digest(review, "sha256")
"passed" = review["status"]
1 = review["expected_failure_exit_status"]
"developer_exposed" = review["exposure"]
false = review["independent_confirmation"]
["pint/definitions.py"] = review["changed_paths"]
1 = review["controls"]["untouched"]["exit_status"]
0 = review["controls"]["reference"]["exit_status"]

for control <- Map.values(review["controls"]) do
  false = control["timed_out"]
  [] = control["changed_paths"]
end

for {role, correct} <- [{"untouched", 7}, {"reference", 12}, {"captured_artifact", 11}] do
  grade = report["grades"][role]
  ^correct = grade["correct"]
  12 = grade["checks"]
  true = grade["verification_complete"]
  [] = grade["safety_failures"]
end

0 = report["hosted_requests"]
false = report["private_grader_mounted"]
false = report["model_rerun"]
false = report["original_report_reclassified"]
true = report["detected_public_regression_in_retained_artifact"]
"not_established" = report["same_defect_as_historical_private_failure"]

true =
  report["captured_artifact_file_sha256"] ==
    report["captured_artifact_ancestry"]["restored_changed_file_sha256"]

true =
  report["checks_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "test_definition_contract.py")))

true =
  report["reference_transform_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "reference_transform.py")))

for {relative, expected} <- report["source_files_sha256"] do
  true = expected == Contract.sha256(File.read!(Path.join(repository, relative)))
end

for name <- ["historical-reference-control.json", "reference-runtime-control.json"] do
  failed = read.(name)
  :ok = Contract.verify_digest(failed, "sha256")
  :ok = Contract.verify_digest(failed["matched_review"], "sha256")
  "not_demonstrated" = failed["matched_review"]["status"]
end

refused = read.("pilot-controls-refused.json")
false = refused["positive_private"]["passed"]
4 = refused["positive_private"]["correct"]
controls = read.("pilot-controls.json")
0 = controls["hosted_requests"]
true = controls["positive_public"]["passed"]
14 = controls["positive_public"]["checks"]
true = controls["positive_private"]["passed"]
6 = controls["positive_private"]["checks"]
false = controls["negative_public"]["passed"]
false = controls["negative_private"]["passed"]
curation = read.("pilot-curation.json")
true = curation["new_checks_derived_after_private_control_audit"]
false = curation["independent_confirmation"]
true = curation["public_checks_sha256"] == controls["metadata"]["public_checks_sha256"]

true =
  curation["public_checks_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "pilot_public_checks.py")))

true =
  curation["reference_transform_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "pilot_reference_transform.py")))

benchmark = read.("benchmark.json")
true = benchmark["receipt"]["qualified"]
8 = length(benchmark["receipt"]["scenarios"])
true = Enum.all?(benchmark["receipt"]["scenarios"], &(&1["status"] == "qualified"))
0 = benchmark["hosted_requests"]
{_, 0} = System.cmd("git", ["diff", "--quiet", "--", "lib", "priv"])
{"", 0} = System.cmd("git", ["ls-files", "--others", "--exclude-standard", "--", "lib", "priv"])
{tree, 0} = System.cmd("git", ["write-tree"])

for {key, component} <- [{"lib_tree", "lib"}, {"priv_tree", "priv"}] do
  {actual, 0} = System.cmd("git", ["rev-parse", String.trim(tree) <> ":" <> component])
  true = String.trim(actual) == benchmark["library_components"][key]
end

for {relative, expected} <- benchmark["library_components"]["files"] do
  true = expected == Contract.sha256(File.read!(Path.join(repository, relative)))
end

validation = read.("validation.json")
"passed" = validation["final_gate"]["status"]

protocol = read.("protocol.json")
plan = read.("calibration-plan.json")
calibration = read.("calibration-report.json")
audit = read.("calibration-audit.json")
controller = read.("calibration-controller.json")
authorization = read.("allowance-authorization.json")
registration = read.("calibration-registration.json")
mechanism = read.("mechanism-registration.json")

for sealed <- [
      plan,
      plan["runtime"],
      calibration,
      audit,
      controller,
      authorization,
      registration["template"],
      mechanism["template"],
      read.("calibration-planning.json"),
      read.("mechanism-planning.json"),
      read.("seed-controls.json"),
      read.("feedback-workflow.json")
    ],
    do: :ok = Contract.verify_digest(sealed, "sha256")

for {file, key} <- [
      {"calibration-registration.json", "calibration_registration_sha256"},
      {"mechanism-registration.json", "mechanism_registration_sha256"},
      {"select_target.py", "selector_sha256"},
      {"seed-controls.json", "seed_controls_sha256"}
    ] do
  true = protocol[key] == Contract.sha256(File.read!(Path.join(directory, file)))
end

true = protocol["revision"] == plan["runtime"]["revision"]
true = plan["runtime"]["source_tree_clean"]
true = protocol["shared_limits"] == authorization["limits"]
true = protocol["shared_limits"] == plan["runtime"]["study_allowance"]["limits"]

strip_seed_usage = fn record ->
  record
  |> Map.delete("sha256")
  |> Map.update!("runtime", &Map.drop(&1, ~w(sha256 seed_usage)))
end

true = strip_seed_usage.(plan) == strip_seed_usage.(registration["template"])
rebuilt = Calibration.report(plan, calibration["rows"])
true = Map.take(calibration, Map.keys(rebuilt)) == rebuilt
true = calibration["execution_complete"]
0 = calibration["unknown_token_rows"]
"not_tested" = calibration["benefit"]

selection = read.("calibration-selection.json")
[] = selection["eligible_targets"]
nil = selection["selected_target"]
false = selection["private_confirmation_used_for_selection"]

true =
  selection["calibration_report_bytes_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "calibration-report.json")))

for decision <- selection["decisions"] do
  false = decision["eligible"]

  for arm <- ~w(disabled reference) do
    checks = decision["checks"][arm]

    true =
      Enum.all?(checks, fn {key, value} -> key == "source_evidence_bytes_sha256" or value end)
  end
end

27 = controller["accounting"]["requests"]
395_616 = controller["accounting"]["tokens"]
0 = controller["accounting"]["learning_requests"]
0 = controller["accounting"]["learning_tokens"]
0 = controller["job_budget"]["active"]
0 = controller["job_budget"]["unmeasured"]
true = Enum.all?(controller["records"], fn {_id, record} -> record["status"] == "completed" end)
27 = Enum.sum(Enum.map(calibration["rows"], & &1["requests"]))
395_616 = Enum.sum(Enum.map(calibration["rows"], & &1["tokens"]))
true = audit["native_calibration_reconstruction"]
true = audit["registered_and_executed_plan_match"]
true = audit["durable_ledger_matches_physical_meter"]
27 = audit["physical_requests"]
395_616 = audit["tokens"]
0 = audit["unknown_dispatch_usage"]

true =
  audit["durable_controller_bytes_sha256"] ==
    Contract.sha256(File.read!(Path.join(directory, "calibration-controller.json")))

for episode <- audit["episodes"] do
  true = episode["row_matches_physical_meter"]
  true = episode["transcript_verified"]["original"]
  true = episode["transcript_verified"]["selected"]
end

study = read.("hosted-study.json")
"calibration_complete_no_eligible_mechanism_target" = study["status"]
"not_run" = study["conditional_mechanism"]["status"]
0 = study["conditional_mechanism"]["seed_episodes"]
0 = study["conditional_mechanism"]["target_episodes"]
0 = study["ordinary_use_items_reviewed"]
false = study["independent_confirmation"]
2 = length(study["episodes"])

for episode <- study["episodes"] do
  "completed" = episode["status"]
  nil = episode["provider_error"]
  true = episode["public_grade"]["passed"]
  14 = episode["public_grade"]["correct"]
  true = episode["confirmation_grade"]["passed"]
  6 = episode["confirmation_grade"]["correct"]
end

cleanup = read.("cleanup.json")
0 = cleanup["task_owned_containers_remaining"]
true = cleanup["all_admitted_requests_settled"]
true = cleanup["oauth_loan_removed"]
true = cleanup["allowance_owner_lock_removed"]
false = cleanup["conditional_mechanism_output_created"]

IO.puts("public feedback packet verified without provider calls; efficacy remains unproven")
