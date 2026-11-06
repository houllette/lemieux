# Native private-artifact audit. Arguments: executed root, registered root,
# allowance directory, output JSON. No provider or grader is invoked here.
alias Lemieux.CLI.Learning.Calibration
alias Lemieux.CLI.Learning.Installation
alias Lemieux.Contract
alias Lemieux.Evidence.Run

[root, registered, allowance, output] = System.argv()
read = fn path -> path |> File.read!() |> JSON.decode!() end
plan = read.(Path.join(root, "plan.json"))
report = read.(Path.join(root, "report.json"))
:ok = Contract.verify_digest(plan, "sha256")
:ok = Contract.verify_digest(report, "sha256")
rebuilt = Calibration.report(plan, report["rows"])
true = Map.take(report, Map.keys(rebuilt)) == rebuilt

true =
  File.read!(Path.join(root, "registration.json")) ==
    File.read!(Path.join(registered, "registration.json"))

records =
  Path.wildcard(Path.join([root, "*", "evidence.json"]))
  |> Map.new(fn path ->
    evidence = read.(path)
    {Contract.digest(evidence), {evidence, path}}
  end)

episodes =
  Enum.map(report["rows"], fn row ->
    {evidence, path} = Map.fetch!(records, row["evidence_sha256"])
    true = evidence["context"]["arm"] == row["arm"]
    true = get_in(evidence, ["context", "task", "id"]) == row["task_id"]

    transcripts =
      Map.new(~w(original selected), fn key ->
        entries = evidence[key]["transcript"]
        terminal = Enum.find(Enum.reverse(entries), &(&1["type"] == "run_evidence"))
        {key, terminal != nil and Run.verify_transcript(terminal["payload"], entries) == :ok}
      end)

    meter = evidence["physical_dispatches"]
    unknown = Enum.count(meter, fn {_id, dispatch} -> not is_integer(dispatch["tokens"]) end)

    tokens =
      if unknown == 0,
        do: Enum.sum(Enum.map(meter, fn {_id, dispatch} -> dispatch["tokens"] end))

    %{
      "task_id" => row["task_id"],
      "arm" => row["arm"],
      "row" => row,
      "evidence_bytes_sha256" => Contract.sha256(File.read!(path)),
      "transcript_verified" => transcripts,
      "physical_request_count" => map_size(meter),
      "physical_tokens" => tokens,
      "unknown_dispatch_usage" => unknown,
      "row_matches_physical_meter" =>
        row["requests"] == map_size(meter) and row["tokens"] == tokens
    }
  end)

meters =
  Enum.flat_map(report["rows"], fn row ->
    {evidence, _path} = Map.fetch!(records, row["evidence_sha256"])
    Enum.to_list(evidence["physical_dispatches"])
  end)

true = length(meters) == length(Enum.uniq_by(meters, &elem(&1, 0)))
unknown = Enum.count(meters, fn {_id, dispatch} -> not is_integer(dispatch["tokens"]) end)

tokens =
  if unknown == 0,
    do: Enum.sum(Enum.map(meters, fn {_id, dispatch} -> dispatch["tokens"] end))

ledger_path = Path.join(allowance, "controller.json")
ledger = read.(ledger_path)
:ok = Contract.verify_digest(ledger, "sha256")
true = length(meters) == ledger["accounting"]["requests"]
known_match = unknown == 0 and tokens == ledger["accounting"]["tokens"]

result = %{
  "schema_version" => 1,
  "kind" => "public_feedback_calibration_native_audit/v1",
  "plan_sha256" => plan["sha256"],
  "report_sha256" => report["sha256"],
  "registered_and_executed_plan_match" => true,
  "native_calibration_reconstruction" => true,
  "episodes" => episodes,
  "physical_requests" => length(meters),
  "tokens" => tokens,
  "unknown_dispatch_usage" => unknown,
  "durable_ledger_matches_physical_meter" => known_match,
  "durable_controller_bytes_sha256" => Contract.sha256(File.read!(ledger_path)),
  "oauth_loan_removed" => not File.exists?(Path.join(root, ".auth/oauth.json")),
  "allowance_owner_lock_removed" => not File.exists?(Path.join(allowance, "owner.lock")),
  "interpretation" => "Exposed development calibration, not independent efficacy confirmation."
}

:ok = Installation.write(output, Map.put(result, "sha256", Contract.digest(result)))

IO.puts(
  JSON.encode!(
    Map.take(
      result,
      ~w(physical_requests tokens unknown_dispatch_usage durable_ledger_matches_physical_meter)
    )
  )
)
