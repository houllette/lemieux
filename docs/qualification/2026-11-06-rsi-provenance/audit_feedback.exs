# Private inputs stay private. This performs no model request and never changes
# the personal feedback/session stores. Run from the repository root with a new
# output path: mix run --no-start THIS_SCRIPT PRIVATE_SNAPSHOT OUTPUT.json
alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
alias Lemieux.Benchmark.Manifest
alias Lemieux.Benchmark.Task
alias Lemieux.Contract
alias Lemieux.Entry
alias Lemieux.Feedback
alias Lemieux.Feedback.Store, as: FeedbackStore
alias Lemieux.Feedback.Store.JSONL, as: FeedbackJSONL
alias Lemieux.Reflection.Opportunities
alias Lemieux.Store
alias Lemieux.Store.JSONL

[input, output] = System.argv()
read = fn path -> path |> File.read!() |> JSON.decode!() end
inventory = read.(Path.join(input, "feedback-inventory.json"))
protocol = read.(Path.join(input, "feedback-review-protocol.json"))
decisions = read.(Path.join(__DIR__, "decisions.json"))
selected = Enum.take(inventory["rows"], 20)
true = length(selected) == 20
true = protocol["selected_ids"] == Enum.map(selected, & &1["id"])
true = length(decisions["rows"]) == 20
private = Path.join(input, "audit-" <> Lemieux.ID.generate())
:ok = File.mkdir(private)
:ok = File.chmod(private, 0o700)

sessions =
  selected
  |> Enum.map(& &1["provenance"]["session_id"])
  |> Enum.uniq()
  |> Enum.with_index(1)
  |> Map.new(fn {id, index} ->
    {:ok, entries} = Store.read(JSONL.new(Path.join(input, "sessions")), id)
    {id, %{entries: entries, public_group: "session-#{index}"}}
  end)

rows =
  selected
  |> Enum.zip(decisions["rows"])
  |> Enum.map(fn {source, decision} ->
    path = Path.join([input, "feedback", source["file"]])
    bytes = File.read!(path)
    true = Contract.sha256(bytes) == source["bytes_sha256"]
    history = bytes |> String.split("\n", trim: true) |> Enum.map(&Feedback.decode!/1)
    first = hd(history)
    true = first.id == source["id"]
    true = Enum.map(history, & &1.revision) == Enum.to_list(1..length(history))

    true =
      Enum.all?(history, &(&1.raw_text == first.raw_text and &1.provenance == first.provenance))

    session = sessions[first.provenance["session_id"]]
    known = MapSet.new(session.entries, & &1.id)
    cited = get_in(first.provenance, ["opportunity", "evidence_entry_ids"]) || []
    missing = Enum.reject(cited, &MapSet.member?(known, &1))

    Map.merge(decision, %{
      "feedback_bytes_sha256" => source["bytes_sha256"],
      "original_actor_type" => first.actor["type"],
      "source_group" => session.public_group,
      "source_entry_count" => length(session.entries),
      "source_entries_sha256" =>
        Contract.sha256(Enum.map(session.entries, &[Entry.encode!(&1), ?\n])),
      "primary_anchor_present" => MapSet.member?(known, first.provenance["entry_id"]),
      "citation_count" => length(cited),
      "missing_citation_count" => length(missing),
      "missing_citation_fingerprints" => Enum.map(missing, &Contract.sha256/1),
      "historical_revisions_unchanged" => true
    })
  end)

# Reproduce the exact historical citation defect using neutral wording, not the
# private claim text. Only record/4 is invoked: neither module calls a provider.
source = Enum.at(selected, 11)

[first | _] =
  input
  |> Path.join("feedback")
  |> Path.join(source["file"])
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(&Feedback.decode!/1)

entries = sessions[first.provenance["session_id"]].entries

opportunity = %{
  "title" => "Historical citation membership probe",
  "claim" => "Inspect the retained source evidence before curating this observation.",
  "type" => "unknown",
  "verifiability" => "unknown",
  "evidence_entry_ids" => first.provenance["opportunity"]["evidence_entry_ids"],
  "proposed_case" => nil,
  "confidence" => nil
}

baseline = "76cea618f84c05e95404d030592b5290760d3128"

{legacy_source, 0} =
  System.cmd("git", ["show", baseline <> ":lib/lemieux/reflection/opportunities.ex"])

legacy = Lemieux.RSIQualification.UncheckedOpportunities

legacy_source
|> String.replace(
  "defmodule Lemieux.Reflection.Opportunities do",
  "defmodule Lemieux.RSIQualification.UncheckedOpportunities do",
  global: false
)
|> Code.compile_string()

provenance = %{
  "tenant_id" => "local",
  "project_id" => "qualification-probe",
  "session_id" => first.provenance["session_id"]
}

opts = [model: "test:model", source_entries: entries, fallback_entry_id: List.last(entries).id]
legacy_store = FeedbackJSONL.new(Path.join(private, "baseline"))
{:ok, [_]} = apply(legacy, :record, [[opportunity], provenance, legacy_store, opts])
candidate_store = FeedbackJSONL.new(Path.join(private, "candidate"))

{:error, {:invalid_evidence_entry_ids, invalid}} =
  Opportunities.record([opportunity], provenance, candidate_store, opts)

{:ok, []} = FeedbackStore.list_feedback(candidate_store)
true = invalid != []

# Synthetic positive control establishes that the gate is not always refusing.
# It does not repair, reattribute or authenticate the historical finding.
positive = Map.put(opportunity, "evidence_entry_ids", [hd(entries).id])
positive_store = FeedbackJSONL.new(Path.join(private, "positive"))
{:ok, [positive_id]} = Opportunities.record([positive], provenance, positive_store, opts)
{:ok, accepted} = FeedbackStore.latest(positive_store, positive_id)
"citation" = accepted.provenance["evidence_validation"]["anchor_kind"]

# Audit the existing answer graders on owned copies. These probes are not
# historical model answers and cannot establish actual tool use or causality.
controls =
  for {path, id, correct} <- [
        {"eval/corpus/v1/manifest.json", "case_01M2RNVB9160D5S9D40VPXV5HW", "186"},
        {"eval/corpus/experiments-v1/manifest.json", "case_01M2S6FMZKDX7YKSPQ0RCQ5C5V", "42500"}
      ] do
    manifest_validation =
      case Manifest.read(path) do
        {:ok, _manifest} -> %{"accepted" => true}
        {:error, reason} -> %{"accepted" => false, "reason" => inspect(reason)}
      end

    # The legacy experiments envelope lacks a version and the current manifest
    # reader refuses it. Preserve that refusal. Only inspect its isolated task's
    # trusted grader through the current Task parser; this does not import or
    # qualify the rejected manifest or rewrite its historical bytes.
    raw = read.(path)
    item = Enum.find(raw["tasks"], &(&1["id"] == id))
    {:ok, task} = Task.from_map(item, Path.dirname(Path.expand(path)))
    copy = Path.join(private, id)
    {:ok, _} = File.cp_r(task.cwd, copy)
    task = %{task | cwd: copy}

    full_digest = fn ->
      copy
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Map.new(&{Path.relative_to(&1, copy), Contract.sha256(File.read!(&1))})
      |> Contract.digest()
    end

    before = full_digest.()

    grades =
      Map.new(
        [
          {"wrong", "0"},
          {"correct", correct},
          {"ambiguous_refusal", "Cannot determine the answer; it may be #{correct} or 0."}
        ],
        fn {kind, answer} ->
          {:ok, grade} = CommandGrader.grade(task.grader, task, answer)
          false = grade["timed_out"]

          {kind,
           grade
           |> Map.take(~w(exit_status timed_out passed))
           |> Map.put("output_sha256", Contract.sha256(grade["output"]))}
        end
      )

    true = full_digest.() == before
    false = grades["wrong"]["passed"]
    true = grades["correct"]["passed"]
    true = grades["ambiguous_refusal"]["passed"]

    %{
      "task_id" => id,
      "manifest_validation" => manifest_validation,
      "manifest_bytes_sha256" => Contract.sha256(File.read!(path)),
      "fixture_sha256" => before,
      "controls" => grades,
      "source_unchanged" => true,
      "qualification" => "not_demonstrated",
      "limitation" =>
        "Answer substring acceptance cannot certify an unambiguous answer or actual required tool use."
    }
  end

result = %{
  "schema_version" => 1,
  "kind" => "consecutive_feedback_provenance_audit/v1",
  "inventory_bytes_sha256" =>
    Contract.sha256(File.read!(Path.join(input, "feedback-inventory.json"))),
  "protocol_bytes_sha256" =>
    Contract.sha256(File.read!(Path.join(input, "feedback-review-protocol.json"))),
  "population" => length(inventory["rows"]),
  "reviewed" => length(rows),
  "source_sessions" => map_size(sessions),
  "source_projects" => 1,
  "source_exposure" => "developer_exposed_retrospective_local_feedback",
  "independent_confirmation" => false,
  "review_actor" => "codex_model_curator",
  "ordinary_use_prospective_cohort_qualified" => false,
  "approved" => Enum.count(rows, & &1["approved"]),
  "required_approved" => 10,
  "median_approved_curation_minutes" => nil,
  "v2_status" => "not_qualified",
  "rows" => rows,
  "source_backed_regression" => %{
    "baseline_revision" => baseline,
    "baseline_module_source_sha256" => Contract.sha256(legacy_source),
    "historical_citations_replayed" => true,
    "private_claim_text_replayed" => false,
    "baseline_accepts_invalid_citations" => true,
    "candidate_refuses_invalid_citations" => true,
    "candidate_writes_before_refusal" => 0,
    "candidate_accepts_synthetic_valid_citations" => true,
    "missing_citations" => length(invalid)
  },
  "existing_grader_controls" => controls,
  "historical_scores_changed" => false,
  "raw_feedback_or_transcripts_published" => false,
  "hosted_requests" => 0,
  "interpretation" =>
    "Entry membership is necessary provenance, not truth, case approval, RSI efficacy or activation authority."
}

File.write!(output, Contract.encode!(Map.put(result, "sha256", Contract.digest(result))), [
  :exclusive
])

IO.puts(
  JSON.encode!(%{
    "reviewed" => length(rows),
    "missing_primary_anchors" => Enum.count(rows, &(not &1["primary_anchor_present"])),
    "records_with_missing_citations" => Enum.count(rows, &(&1["missing_citation_count"] > 0)),
    "approved" => result["approved"],
    "v2_status" => result["v2_status"],
    "hosted_requests" => 0
  })
)
