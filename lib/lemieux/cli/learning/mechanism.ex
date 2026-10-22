defmodule Lemieux.CLI.Learning.Mechanism do
  @moduledoc """
  Host audit of the observed learning chain before a larger hosted study.

  A retained lesson, exposure ledger, changed runtime and executed actions must
  all be present, together with a matched experience-withheld arm. Asset kinds
  additionally need actual procedure/helper use and changed request catalogues.
  This proves an observed data path, never a causal benefit. The six-arm study
  and independent endpoints remain responsible for efficacy.
  """
  alias Lemieux.Contract
  alias Lemieux.Evidence.Run
  alias Lemieux.Learning.Qualification

  @spec audit(root :: Path.t(), plan :: map(), report :: map()) :: {:ok, map()} | {:error, term()}
  def audit(root, plan, report) do
    with :ok <- Qualification.verify(plan),
         :ok <- Contract.verify_digest(report, "sha256"),
         true <- report["plan_sha256"] == plan["sha256"],
         true <- report["mechanics"] == "passed",
         true <- get_in(plan, ["runtime", "research_protocol", "stage"]) == "mechanism",
         {:ok, records} <- records(root, report["rows"]),
         true <- Enum.all?(records, &complete?/1) do
      updating = Enum.filter(records, &(&1.evidence["context"]["arm"] == "updating"))
      withheld = Enum.filter(records, &(&1.evidence["context"]["arm"] == "no_experience"))
      profile? = get_in(plan, ["runtime", "research_protocol", "profile_search"]) == true
      assets? = is_map(get_in(plan, ["runtime", "research_protocol", "asset_search"]))

      checks = %{
        "retained_seed_lessons" =>
          report["warmup_rows"] != [] and
            Enum.all?(report["warmup_rows"], &(&1["created_lesson_ids"] != [])),
        "experience_withheld" => withheld != [] and Enum.all?(withheld, &withheld?/1),
        "observed_lesson_to_execution" => Enum.any?(updating, &chain?(&1, profile?, assets?)),
        "profile_exercised" => not profile? or Enum.any?(updating, &profile?/1),
        "procedure_exercised" => not assets? or Enum.any?(updating, &procedure?/1),
        "helper_executed" => not assets? or Enum.any?(updating, &helper?/1),
        "setting_exercised" => not assets? or Enum.any?(updating, &setting?/1)
      }

      receipt = %{
        "schema_version" => 1,
        "kind" => "observed_learning_mechanism/v1",
        "status" => if(Enum.all?(checks, &elem(&1, 1)), do: "passed", else: "not_demonstrated"),
        "checks" => checks,
        "binding" => binding(plan["runtime"], plan["model"], plan["effort"]),
        "plan_sha256" => plan["sha256"],
        "report_sha256" => report["sha256"],
        "evidence_sha256" => Enum.map(records, & &1.row["evidence_sha256"]),
        "interpretation" => "observed_dataflow_and_execution_not_causal_efficacy"
      }

      {:ok, Map.put(receipt, "sha256", Contract.digest(receipt))}
    else
      _invalid -> {:error, :incomplete_mechanism_archive}
    end
  end

  @spec gate(receipt :: map(), runtime :: map(), model :: String.t(), effort :: String.t()) ::
          :ok | {:error, term()}
  def gate(receipt, runtime, model, effort) do
    with :ok <- Contract.verify_digest(receipt, "sha256"),
         "observed_learning_mechanism/v1" <- receipt["kind"],
         "passed" <- receipt["status"],
         true <- receipt["binding"] == binding(runtime, model, effort),
         true <- Enum.all?(receipt["checks"], &elem(&1, 1)) do
      :ok
    else
      _invalid -> {:error, :matching_mechanism_required}
    end
  end

  defp binding(runtime, model, effort),
    do: %{
      "revision" => runtime["revision"],
      "model" => model,
      "effort" => effort,
      "inference_route" => runtime["inference_route"],
      "research_protocol" => Map.delete(runtime["research_protocol"], "stage")
    }

  defp records(root, rows) do
    index =
      Path.wildcard(Path.join([root, "*", "evidence.json"]))
      |> Map.new(fn path ->
        evidence = path |> File.read!() |> JSON.decode!()
        {Contract.digest(evidence), %{evidence: evidence, dir: Path.dirname(path)}}
      end)

    records = Enum.map(rows, &Map.put(index[&1["evidence_sha256"]] || %{}, :row, &1))

    if Enum.all?(records, &Map.has_key?(&1, :evidence)),
      do: {:ok, records},
      else: {:error, :missing_evidence}
  end

  defp complete?(record) do
    record.row["qualification_complete"] == true and is_integer(record.row["tokens"]) and
      record.row["safety_failures"] == [] and
      Enum.all?(~w(original selected), fn key ->
        transcript = record.evidence[key]["transcript"]
        terminal = Enum.find(Enum.reverse(transcript), &(&1["type"] == "run_evidence"))
        terminal != nil and Run.verify_transcript(terminal["payload"], transcript) == :ok
      end)
  end

  defp withheld?(record) do
    evidence = record.evidence
    context = evidence["context"]

    context["prior_lesson_ids"] == [] and context["available_case_ids"] == [] and
      record.row["exposed_case_ids"] == [] and
      (evidence["retrieval"] || %{})["selected"] in [nil, []] and
      (is_map(evidence["refinement"]) or is_map(evidence["asset_search"]))
  end

  defp chain?(record, profile?, assets?) do
    selected = get_in(record.evidence, ["retrieval", "selected"]) || []

    exposures =
      Path.wildcard(Path.join(record.dir, "exposure-*.json"))
      |> Enum.map(&(File.read!(&1) |> JSON.decode!()))

    ids = Enum.map(selected, & &1["id"])

    exposed =
      Enum.any?(exposures, &exposed?(&1, ids))

    selected != [] and exposed and
      actions(record.evidence["original"]) != actions(record.evidence["selected"]) and
      consumed?(record, profile?, assets?)
  end

  defp exposed?(exposure, ids),
    do:
      exposure["consumer_role"] == "proposer" and exposure["source_case_ids"] != [] and
        Enum.any?(ids, &(&1 in exposure["derived_artifact_ids"]))

  defp consumed?(record, profile?, assets?),
    do:
      (profile? and profile?(record) and proposer_read?(record)) or
        (assets? and procedure?(record) and asset_experience?(record))

  defp profile?(record) do
    receipt = record.evidence["refinement"] || %{}

    receipt["decision"] == "proposed" and record.row["promotion_count"] > 0 and
      record.row["promotion_count"] == record.row["rollback_count"] and
      snapshots(record.evidence["original"])
      |> Enum.any?(fn original ->
        Enum.any?(
          snapshots(record.evidence["selected"]),
          &(&1["system_prompt_sha256"] != original["system_prompt_sha256"] or
              &1["tools"] != original["tools"])
        )
      end)
  end

  defp proposer_read?(record) do
    Path.wildcard(Path.join([record.dir, "sessions", "*.jsonl"]))
    |> Enum.any?(fn path ->
      path
      |> File.stream!()
      |> Enum.map(&JSON.decode!/1)
      |> Enum.any?(fn entry ->
        entry["type"] == "tool_result" and entry["payload"]["name"] == "read" and
          entry["payload"]["error"] == false and
          String.starts_with?(entry["payload"]["arguments"]["path"] || "", "evidence/lessons/")
      end)
    end)
  end

  defp asset_experience?(record) do
    path = Path.join([record.dir, "asset-search", "source.json"])

    case File.read(path) do
      {:ok, bytes} -> JSON.decode!(bytes)["prior_experience"] != []
      _missing -> false
    end
  end

  defp procedure?(record),
    do: Enum.any?(results(record), &(&1["name"] == "skill" and is_nil(&1["arguments"]["file"])))

  defp helper?(record) do
    helpers =
      Enum.filter(
        results(record),
        &(&1["name"] == "skill" and String.ends_with?(&1["arguments"]["file"] || "", ".py"))
      )

    Enum.any?(helpers, fn helper ->
      file = helper["arguments"]["file"] |> Path.basename()

      Enum.any?(
        results(record),
        &(&1["name"] == "bash" and String.contains?(&1["arguments"]["command"] || "", file) and
            get_in(&1, ["structured_content", "exit_status"]) == 0)
      )
    end)
  end

  defp setting?(record) do
    candidates = get_in(record.evidence, ["asset_search", "candidates"]) || []
    selected = get_in(record.evidence, ["asset_application", "asset_sha256"]) || []

    settings =
      Enum.filter(
        candidates,
        &(get_in(&1, ["asset", "content", "kind"]) == "configuration" and
            &1["asset"]["sha256"] in selected)
      )

    Enum.any?(settings, fn setting ->
      count = get_in(setting, ["asset", "content", "payload", "glob_after_requests"])
      catalog = glob_catalog(record.evidence["selected"])

      catalog != [] and catalog != glob_catalog(record.evidence["original"]) and
        Enum.with_index(catalog)
        |> Enum.all?(fn {visible, index} -> visible == index >= count end)
    end) and
      record.row["asset_application_count"] == record.row["asset_restoration_count"] and
      record.row["asset_application_count"] > 0
  end

  defp glob_catalog(observation),
    do:
      observation["transcript"]
      |> Enum.filter(&(&1["type"] == "request"))
      |> Enum.map(fn entry ->
        Enum.any?(entry["payload"]["catalog"]["per_tool"], &(&1["name"] == "glob"))
      end)

  defp snapshots(observation),
    do:
      observation["transcript"]
      |> Enum.filter(&(&1["type"] == "harness_snapshot"))
      |> Enum.map(& &1["payload"])

  defp results(record),
    do:
      record.evidence["selected"]["transcript"]
      |> Enum.filter(&(&1["type"] == "tool_result" and &1["payload"]["error"] == false))
      |> Enum.map(& &1["payload"])

  defp actions(observation),
    do:
      observation["transcript"]
      |> Enum.filter(&(&1["type"] == "tool_result"))
      |> Enum.map(&Map.take(&1["payload"], ~w(name arguments)))
end
