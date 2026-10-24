# Provider-free integrity inspection of public development artifacts. The
# archival context below reconstructs content identity; it is never receiving
# host authority, runtime qualification or permission to activate the asset.
alias Lemieux.Contract
alias Lemieux.Learning.Asset

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

IO.puts(
  "Public ancestry and learned-skill integrity checks passed; qualification remains unassessed."
)
