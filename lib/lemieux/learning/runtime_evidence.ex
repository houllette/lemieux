defmodule Lemieux.Learning.RuntimeEvidence do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot
  alias Lemieux.RequestSnapshot

  @invariants ~w(model provider_identity disabled_extensions retry_policy verification host_config_sha256 code strategy_code)

  @spec invariants(freeze :: map()) :: map()
  def invariants(freeze), do: Map.take(freeze, @invariants)

  @spec verify(observation :: map(), identity :: map(), changes :: map() | nil) ::
          :ok | {:error, term()}
  def verify(observation, identity, changes \\ nil) do
    qualification = observation["runtime_qualification"]

    with %{"schema_version" => 1, "lane" => "effective_lmx"} <- qualification,
         :ok <- Contract.verify_digest(qualification, "sha256"),
         :ok <- Contract.verify_digest(qualification["control"], "sha256"),
         :ok <- Contract.verify_digest(qualification["effective"], "sha256"),
         true <- qualification["surface"] == identity["surface"],
         true <- is_map(identity["invariants"]) and map_size(identity["invariants"]) > 0,
         true <- invariants(qualification["control"]) == identity["invariants"],
         true <- is_nil(changes) or qualification["intentional_changes"] == changes,
         true <- authority(qualification["control"]) == authority(qualification["effective"]),
         :ok <- transcript(observation, qualification) do
      :ok
    else
      _invalid -> {:error, :invalid_runtime_evidence}
    end
  rescue
    _invalid -> {:error, :invalid_runtime_evidence}
  end

  # Workspace paths intentionally differ between fresh leases. The immutable
  # code/configuration invariants above must not differ; each request still
  # binds its own full workspace qualification below.
  defp authority(freeze) do
    freeze
    |> Map.drop(~w(sha256 system catalog generation))
    |> Map.update!("session_configuration", &Map.drop(&1, ~w(params reasoning_effort)))
    |> Map.update!("catalog_policy", fn policy ->
      Map.update!(policy, "tools", &Enum.map(&1, fn tool -> Map.take(tool, ~w(name enabled)) end))
    end)
  end

  defp transcript(observation, qualification) do
    entries = observation["transcript"]
    run = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "run_evidence"))

    with %{"payload" => evidence} <- run,
         :ok <- Run.verify(evidence),
         true <- evidence["model"] == qualification["effective"]["model"],
         true <- evidence["requests"] != [],
         :ok <- transcript_bytes(entries, evidence),
         :ok <- terminal_snapshot(entries, evidence, qualification) do
      Enum.reduce_while(evidence["requests"], :ok, fn ref, :ok ->
        continued(request(entries, ref, qualification))
      end)
    end
  end

  defp continued(:ok), do: {:cont, :ok}
  defp continued(error), do: {:halt, error}

  defp transcript_bytes(entries, evidence) do
    ids = evidence["transcript"]["entry_ids"]
    selected = Enum.filter(entries, &(&1["id"] in ids))

    artifact =
      Enum.find(evidence["artifacts"], &(&1["id"] == evidence["transcript"]["artifact_id"]))

    with true <- Enum.map(selected, & &1["id"]) == ids,
         {:ok, reference} <- ArtifactReference.from_map(artifact),
         {:ok, decoded} <- decode(selected) do
      ArtifactReference.verify_bytes(reference, Enum.map_join(decoded, "\n", &Entry.encode!/1))
    end
  end

  defp decode(entries) do
    {:ok, Enum.map(entries, &Entry.decode!(JSON.encode!(&1)))}
  end

  defp terminal_snapshot(entries, evidence, qualification) do
    snapshot = evidence["harness_snapshot"]
    harness(entries, snapshot["id"], snapshot["semantic_sha256"], qualification)
  end

  defp request(entries, reference, qualification) do
    entry =
      Enum.find(entries, &(&1["type"] == "request" and &1["payload"]["id"] == reference["id"]))

    with %{"payload" => request} <- entry,
         :ok <- RequestSnapshot.verify(request),
         true <- request["sha256"] == reference["sha256"],
         true <- request["model"] == qualification["effective"]["model"],
         true <- request["harness_snapshot_sha256"] == reference["harness_snapshot_sha256"] do
      harness(
        entries,
        request["harness_snapshot_id"],
        request["harness_snapshot_sha256"],
        qualification
      )
    end
  end

  defp harness(entries, id, digest, qualification) do
    entry = Enum.find(entries, &(&1["type"] == "harness_snapshot" and &1["payload"]["id"] == id))

    with %{"payload" => snapshot} <- entry,
         :ok <- Snapshot.verify(snapshot),
         true <- snapshot["semantic_sha256"] == digest,
         true <- snapshot["model"] == qualification["effective"]["model"],
         %{"evaluation" => reference} <- snapshot["workflow"],
         true <- reference["sha256"] == qualification["sha256"],
         true <- reference["control_sha256"] == qualification["control"]["sha256"],
         true <- reference["effective_sha256"] == qualification["effective"]["sha256"],
         true <- reference["intentional_changes"] == qualification["intentional_changes"] do
      :ok
    end
  end
end
