# Run offline from the repository root:
# mix run docs/qualification/2026-10-20-learning-study/verify.exs
alias Lemieux.Contract
alias Lemieux.Learning.Qualification

root = __DIR__
read = fn path -> path |> File.read!() |> JSON.decode!() end

plans = Path.wildcard(Path.join(root, "**/plan.json"))

for path <- plans do
  plan = read.(path)
  :ok = Contract.verify_digest(plan, "sha256")
  :ok = Contract.verify_digest(plan["runtime"], "sha256")
  if plan["schema_version"] == 3, do: :ok = Qualification.verify(plan)

  # The earliest calibration predates the separate seed-registration file.
  for registration_path <- Path.wildcard(Path.join(Path.dirname(path), "registration.json")) do
    registration = read.(registration_path)
    :ok = Contract.verify_digest(registration["template"], "sha256")
  end
end

reports = Path.wildcard(Path.join(root, "**/report.json"))

for path <- reports do
  report = read.(path)
  plan = read.(Path.join(Path.dirname(path), "plan.json"))
  audit = read.(Path.join(Path.dirname(path), "audit.json"))
  :ok = Contract.verify_digest(report, "sha256")
  :ok = Contract.verify_digest(report["runtime"], "sha256")
  true = report["plan_sha256"] == plan["sha256"]
  true = audit["source_report_bytes_sha256"] == Contract.sha256(File.read!(path))
  rows = report["rows"] ++ Map.get(report, "warmup_rows", [])
  true = length(rows) == length(audit["episodes"])

  for row <- rows do
    episode =
      Enum.find(audit["episodes"], fn episode ->
        Enum.all?(~w(task_id arm repetition), &(episode[&1] == row[&1]))
      end)

    true = episode["source_evidence_bytes_sha256"] == row["evidence_sha256"]
    true = episode["ledger_tokens"] == row["tokens"]

    if episode["physical_dispatches"] do
      true = map_size(episode["physical_dispatches"]) == row["requests"]

      true =
        Enum.sum(Enum.map(episode["physical_dispatches"], fn {_, v} -> v["tokens"] end)) ==
          row["tokens"]

      true = episode["meter_matches_ledger"]
    end
  end

  if plan["schema_version"] == 3 do
    {:ok, recomputed} = Qualification.report(plan, report["rows"])

    # Preserve the historical explanatory string and original seal. No numeric
    # result, decision, threshold or outcome may change in this comparison.
    for {key, value} <- Map.drop(recomputed, ~w(sha256 resource_policy)) do
      true = report[key] == value
    end
  end
end

IO.puts("Verified #{length(plans)} plans and #{length(reports)} completed reports offline.")
