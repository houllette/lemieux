# Public integrity/consistency check; no private stores, providers or graders.
alias Lemieux.Contract

directory = __DIR__
repository = Path.expand("../../..", directory)
read = fn name -> directory |> Path.join(name) |> File.read!() |> JSON.decode!() end

for row <- directory |> Path.join("SHA256SUMS") |> File.read!() |> String.split("\n", trim: true) do
  [expected, path] = String.split(row, "  ", parts: 2)
  true = Path.type(path) == :relative and ".." not in Path.split(path)
  true = expected == Contract.sha256(File.read!(Path.join(directory, path)))
end

audit = read.("audit.json")
:ok = Contract.verify_digest(audit, "sha256")
42 = audit["population"]
20 = audit["reviewed"]
3 = audit["source_sessions"]
1 = audit["source_projects"]
0 = audit["approved"]
0 = audit["hosted_requests"]
false = audit["independent_confirmation"]
false = audit["ordinary_use_prospective_cohort_qualified"]
nil = audit["median_approved_curation_minutes"]
"not_qualified" = audit["v2_status"]
false = audit["historical_scores_changed"]
false = audit["raw_feedback_or_transcripts_published"]
20 = length(audit["rows"])
9 = Enum.count(audit["rows"], &(&1["original_actor_type"] == "human"))
11 = Enum.count(audit["rows"], &(&1["original_actor_type"] == "model"))
1 = Enum.count(audit["rows"], &(not &1["primary_anchor_present"]))
2 = Enum.count(audit["rows"], &(&1["missing_citation_count"] > 0))
3 = Enum.sum(Enum.map(audit["rows"], & &1["missing_citation_count"]))

decisions = read.("decisions.json")
false = decisions["independent_human_review"]
"codex_model_curator" = decisions["review_actor"]

for {row, decision} <- Enum.zip(audit["rows"], decisions["rows"]) do
  false = row["approved"]
  true = row["historical_revisions_unchanged"]
  true = Map.take(row, Map.keys(decision)) == decision
end

protocol = read.("review-protocol.json")

true =
  Enum.map(protocol["selected_records"], & &1["bytes_sha256"]) ==
    Enum.map(audit["rows"], & &1["feedback_bytes_sha256"])

regression = audit["source_backed_regression"]
true = regression["historical_citations_replayed"]
false = regression["private_claim_text_replayed"]
true = regression["baseline_accepts_invalid_citations"]
true = regression["candidate_refuses_invalid_citations"]
0 = regression["candidate_writes_before_refusal"]
true = regression["candidate_accepts_synthetic_valid_citations"]

2 = length(audit["existing_grader_controls"])

for grader <- audit["existing_grader_controls"] do
  "not_demonstrated" = grader["qualification"]
  true = grader["source_unchanged"]
  false = grader["controls"]["wrong"]["passed"]
  true = grader["controls"]["correct"]["passed"]
  true = grader["controls"]["ambiguous_refusal"]["passed"]
  true = Enum.all?(grader["controls"], fn {_kind, control} -> not control["timed_out"] end)
end

true = Enum.any?(audit["existing_grader_controls"], &(not &1["manifest_validation"]["accepted"]))

for {path, expected} <- read.("source-pins.json")["files"] do
  true = expected == Contract.sha256(File.read!(Path.join(repository, path)))
end

benchmark = read.("benchmark.json")
0 = benchmark["hosted_requests"]
true = benchmark["receipt"]["qualified"]
8 = length(benchmark["receipt"]["scenarios"])
true = Enum.all?(benchmark["receipt"]["scenarios"], &(&1["status"] == "qualified"))

for {path, expected} <- benchmark["library_files"] do
  true = expected == Contract.sha256(File.read!(Path.join(repository, path)))
end

archives = read.("archive-controls.json")
0 = archives["hosted_requests"]
2 = length(archives["rows"])

for row <- archives["rows"] do
  true = row["commit_archive_refused"]
  true = row["tree_archive_accepted"]
  true = row["source_file_bytes_preserved"]
  1 = row["commit_unknown_members"]
  0 = row["tree_unknown_members"]
end

platform = read.("platform-control.json")
0 = platform["hosted_requests"]
"invalid_tar_checksum" = platform["implicit_platform"]["tar_validation"]
"passed" = platform["explicit_platform"]["tar_validation"]
"passed" = platform["explicit_platform"]["strict_extraction"]
1761 = platform["source_file_count"]
true = platform["source_file_bytes_preserved"]

"passed" = read.("validation.json")["final_gate"]["status"]

IO.puts(
  "feedback provenance packet verified without provider or grader calls; RSI remains unqualified"
)
