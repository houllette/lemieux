# Provider-free integrity inspection of public development artifacts. The
# archival context below reconstructs content identity; it is never receiving
# host authority, runtime qualification or permission to activate the asset.
alias Lemieux.Contract
alias Lemieux.Learning.Asset
alias Lemieux.Learning.Asset.Source
alias Lemieux.Learning.Extension.Export

read = fn name ->
  __DIR__ |> Path.join(name) |> File.read!() |> JSON.decode!()
end

file_digest = fn name ->
  __DIR__ |> Path.join(name) |> File.read!() |> Contract.sha256()
end

status = read.("confirmation-preparation-status.json")
history = read.("confirmation-history-audit.json")
objects = read.("confirmation-object-inventory.json")
true = status["history_report_sha256"] == file_digest.("confirmation-history-audit.json")
true = status["object_inventory_sha256"] == file_digest.("confirmation-object-inventory.json")
true = objects["ancestry_report_sha256"] == status["history_report_sha256"]
true = history["full_pinned_ancestries"] == 120
true = map_size(history["graph_sha256"]) == 120
true = history["source_history_clusters"] == 120
true = history["shared_ancestry_pairs"] == 0
true = history["unique_ancestor_commits"] == 204_461
true = objects["file_blob_objects"] == 0
true = objects["object_types"]["tree"] == 9
true = Enum.all?([status, history, objects], &(&1["qualified_independent_streams"] == 0))

asset = read.("learned-skill-review/asset-record.json")
provenance = read.("learned-skill-review/provenance.json")
content = asset["content"]

archive_context = %{
  scope: content["scope"],
  binding: content["binding"],
  trust: "personal",
  tools: content["requires_tools"],
  description_tools: [],
  settings_allowlist: [],
  helper_extensions: [".py"],
  approved_digests: []
}

attributes = Map.take(content, ~w(kind payload files requires_tools triggers))
{:ok, rebuilt} = Asset.new(attributes, archive_context)
true = rebuilt.content == content
true = rebuilt.digest == asset["sha256"]
true = provenance["asset_id"] == asset["id"]
true = provenance["asset_sha256"] == asset["sha256"]
true = Map.keys(content["files"]) == ["SKILL.md"]

for {name, bytes} <- content["files"] do
  true = File.read!(Path.join([__DIR__, "learned-skill-review", name])) == bytes
  true = provenance["file_sha256"][name] == Contract.sha256(bytes)
end

true = provenance["qualification"] == "unassessed_incomplete_development_scope"
true = provenance["independent_confirmation"] == "not_run"
false = provenance["default_activation"]
false = provenance["host_authority_exported"]
false = provenance["experimental_critic"]["human_review"]
true = provenance["source_scope"]["asset_restored"]
false = provenance["source_scope"]["reflection_complete"]
true = provenance["original_created_at"] == "not_retained_in_asset_search_wire_record"

archival = read.("offline-selected-source-archival.json")
source = Path.join(__DIR__, "selected-source-archival-driver-v1.ex.txt")
true = archival["asset_lane_source_sha256"] == Contract.sha256(File.read!(source))
true = Enum.all?(archival["checks"], &elem(&1, 1))
true = archival["selected_source_trees_verified"] == 12
true = archival["unapproved_activation_refusals"] == 12
true = archival["changed_scope_refusals"] == 12
true = archival["scripted_dispatches"] == 1054
true = archival["scripted_tokens"] == 4216
true = archival["hosted_requests"] == 0
false = archival["credential_loan_created"]
true = archival["qualification"] == "unassessed_scripted_mechanics"

component = read.("shared-values-component.json")
true = component["hosted_requests"] == 0
true = component["source_wire_limit"] == 1_048_576
true = component["lesson_wire_limit"] == 2_097_152
true = component["expanded_limit"] == 8_388_608

true =
  Enum.all?(
    component["records"],
    &(&1["encoded_bytes"] <= 1_048_576 and &1["complete_disclosure_roundtrip"])
  )

stock = read.("stock-live-supplement.json")
true = stock["rows"] == 8 and stock["qualification_complete_rows"] == 8
true = stock["physical_requests"] == 70
true = stock["benefit"] == "unassessed"

fresh = read.("fresh-repository-calibration-v4.json")
true = fresh["physical_requests"] == 220 and fresh["tokens"] == 4_459_923
true = fresh["all_rows_complete_and_known"]
true = length(fresh["rows"]) == 12
true = fresh["task_request_horizon"] == 48
true = fresh["benefit"] == "not_tested" and fresh["independent_confirmation"] == "not_run"

packet = "native-learned-skill-review"
native = read.(packet <> "/review.json")
origin = read.(packet <> "/origin.json")
package = Path.join([__DIR__, packet, "package"])
:ok = Contract.verify_digest(native, "sha256")
:ok = Export.verify(package)
inventory = read.(packet <> "/package/lemieux-extension-export.json")
true = inventory["sha256"] == native["package_sha256"]
true = inventory["qualification"] == "unassessed"
true = origin["review_file_sha256"] == file_digest.(packet <> "/review.json")
true = native["driver_sha256"] == file_digest.(packet <> "/driver-v1.ex.txt")

# These reconstructed contexts check archived data only. No imported scope,
# binding, digest or critic decision is receiving-host permission.
archival_context = fn document ->
  %{
    scope: document["content"]["scope"],
    binding: document["content"]["binding"],
    trust: "repository",
    tools: ~w(read write edit bash glob),
    description_tools: [],
    settings_allowlist: [],
    helper_extensions: [],
    approved_digests: []
  }
end

original_document = read.(packet <> "/package/priv/original/asset.json")
derived_document = read.(packet <> "/package/priv/learned/asset.json")

{:ok, original, _original_files} =
  Source.read(Path.join(package, "priv/original"), archival_context.(original_document))

{:ok, derived, _derived_files} =
  Source.read(Path.join(package, "priv/learned"), archival_context.(derived_document))

{:error, _changed_scope} =
  Source.read(Path.join(package, "priv/original"), archival_context.(derived_document))

true = original.content["files"] == derived.content["files"]
true = original.id != derived.id and original.digest != derived.digest
true = derived.content["scope"]["id"] == "learned-skill-witness-example"
true = original.content["qualification"] == "unconfirmed"
true = derived.content["qualification"] == "unconfirmed"
provenance = read.(packet <> "/package/priv/provenance.json")
true = provenance == native["provenance"]
true = provenance["original_asset_id"] == original.id
true = provenance["original_asset_sha256"] == original.digest
true = provenance["original_created_at"] == DateTime.to_iso8601(original.created_at)
true = provenance["derived_asset_id"] == derived.id
true = provenance["derived_asset_sha256"] == derived.digest
false = provenance["qualification_inherited"]
false = provenance["host_authority_exported"]

bytes = original.content["files"]["SKILL.md"]
expected = %{"skill_sha256" => Contract.sha256(bytes), "source_bytes" => byte_size(bytes)}
true = byte_size(bytes) == 4706
true = native["applied"]["witness"] == expected
true = native["installed_consumer"]["witness"] == expected
true = native["applied"]["assets"] == native["installed_consumer"]["resolved_assets"]
[%{"id" => id, "sha256" => digest}] = native["applied"]["assets"]
true = id == derived.id and digest == derived.digest
true = native["before"]["witness"] == %{"skill_sha256" => nil, "source_bytes" => 0}
true = native["before"]["witness"] == native["after_undo"]["witness"]
true = native["before"]["assets"] == [] and native["after_undo"]["assets"] == []
true = native["before"]["frozen_build_sha256"] == native["after_undo"]["frozen_build_sha256"]
true = Enum.all?(~w(before applied after_undo), &native[&1]["harness_restored"])
true = native["installed_consumer"]["rolled_back"]
true = native["qualification"] == "unassessed" and native["hosted_requests"] == 0
true = native["independent_confirmation"] == "not_run"
false = native["production_active"]
false = origin["human_release_approval"]
true = origin["episode"]["qualification_complete"]
true = origin["episode"]["requests"] == 98 and origin["episode"]["tokens"] == 1_020_608
true = origin["native_witness_hosted_requests"] == 0

mechanism = read.("hosted-text-skill-mechanism-v5.json")
true = mechanism["physical_requests"] == 639 and mechanism["tokens"] == 6_602_336
true = mechanism["unknown_usage_requests"] == 0 and mechanism["execution_complete"]
true = length(mechanism["rows"]) == 12 and mechanism["warmup_rows"] == 1
true = mechanism["mechanism"]["status"] == "passed"
true = length(mechanism["selected_skill_reads"]) == 6
true = Enum.all?(mechanism["selected_skill_reads"], &(&1["selected_skill_reads"] > 0))

for check <- ~w(profile_exercised helper_executed setting_exercised) do
  false = mechanism["mechanism"]["required_checks"][check]
  false = mechanism["mechanism"]["observed_checks"][check]
end

true = mechanism["research_endpoints"]["quality"] == "inconclusive"
true = mechanism["research_endpoints"]["efficiency"] == "inconclusive"
false = mechanism["adequately_powered"]
false = mechanism["default_activation"]

interrupted = read.("pint-calibration-v5-incomplete.json")
true = interrupted["physical_requests"] == 5 and interrupted["known_tokens"] == 15_401
true = interrupted["unknown_usage_requests"] == 1 and interrupted["zero_dispatch_rows"] == 5
true = interrupted["unknown_token_rows"] == 6
true = interrupted["status"] == "incomplete"
nil = interrupted["baseline_success"]
nil = interrupted["has_headroom"]
nil = interrupted["tokens"]
false = interrupted["execution_complete"]
false = interrupted["raw_artifacts_modified"]

amendment = read.("allowance-amendment-v2.json")

true =
  amendment["receipt"]["limits"] == %{
    "max_requests" => 7500,
    "max_tokens" => 100_000_000,
    "max_time_ms" => 86_400_000
  }

:ok = Contract.verify_digest(amendment["receipt"], "sha256")
true = amendment["deadline_ms"] == amendment["original_start_ms"] + 86_400_000
true = amendment["physical_requests"] == 2323 and amendment["known_tokens"] == 26_773_752
true = amendment["known_usage_requests"] == 2322 and amendment["unknown_usage_requests"] == 1
true = amendment["records_unchanged"] and amendment["accounting_unchanged"]
true = amendment["historical_checkpoint_bytes_unchanged"]
true = amendment["admission"] == "blocked_usage_unknown"
true = amendment["new_hosted_requests"] == 0
nil = amendment["tokens"]

capacity = read.("pint-source-capacity-component.json")
true = capacity["complete_roundtrip"] and capacity["hosted_requests"] == 0
true = capacity["encoded_bytes"] == 1_154_735
true = capacity["encoded_bytes"] > capacity["source_wire_limit"]
false = capacity["fits_source_wire"]
false = capacity["unimplemented_syntax_prototypes"]["complete_codec_or_decoder"]

tuples = read.("shared-tuples-component.json")
true = tuples["driver_sha256"] == file_digest.("shared-tuples-component-driver-v1.ex.txt")
true = tuples["hosted_requests"] == 0 and tuples["complete_disclosure_roundtrip"]
true = tuples["lesson_storage_roundtrip"]
true = tuples["raw_bytes"] == 2_043_862 and tuples["encoded_bytes"] == 1_041_756
true = tuples["raw_sha256"] == capacity["raw_sha256"]
true = tuples["encoded_bytes"] <= tuples["source_wire_limit"]

true =
  tuples["lesson_bytes"] == 1_391_849 and tuples["lesson_bytes"] <= tuples["lesson_wire_limit"]

true = tuples["expanded_limit"] == 8_388_608

rehearsal = read.("offline-shared-tuples-mechanism-v6.json")
true = rehearsal["source_tree_clean"] and rehearsal["execution_complete"]
true = rehearsal["scripted_dispatches"] == 436 and rehearsal["synthetic_tokens"] == 1744
true = rehearsal["rows"] == 12 and rehearsal["warmup_rows"] == 1
true = rehearsal["selected_source_trees"] == 6
true = rehearsal["asset_applications"] == 6 and rehearsal["asset_restorations"] == 6
true = rehearsal["mechanism"]["status"] == "passed"
true = rehearsal["unknown_token_accounting"] == 0 and rehearsal["hosted_requests"] == 0
true = rehearsal["protocol"] == "whole_record_research/v6"
false = rehearsal["credential_loan_created"]
false = rehearsal["shared_hosted_allowance_used"]
true = rehearsal["benefit"] == "not_assessed"
true = rehearsal["independent_confirmation"] == "not_run"

for check <- ~w(profile_exercised helper_executed setting_exercised) do
  false = rehearsal["mechanism"]["required_checks"][check]
  false = rehearsal["mechanism"]["observed_checks"][check]
end

reserve = read.("approved-usage-reserve.json")
:ok = Contract.verify_digest(reserve["receipt"], "sha256")
true = reserve["receipt"]["tokens"] == 2_000_000
true = reserve["requests"] == 2323 and reserve["unknown_requests"] == 1
true = reserve["known_tokens"] == 26_773_752 and reserve["budget_tokens"] == 28_773_752
true = reserve["records_unchanged"] and reserve["actual_accounting_unchanged"]
true = reserve["limits_unchanged"] and reserve["historical_checkpoint_bytes_unchanged"]
true = reserve["deadline_ms"] == amendment["deadline_ms"]
true = reserve["new_hosted_requests"] == 0
true = reserve["failed_calibration_qualification"] == "incomplete"
nil = reserve["actual_tokens"]

IO.puts(
  "Public ancestry and learned-skill integrity checks passed; qualification remains unassessed."
)
