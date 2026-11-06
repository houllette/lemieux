# Integrity and consistency only; this performs no provider or grader request.
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

IO.puts("public feedback packet verified; no hosted request or efficacy claim")
