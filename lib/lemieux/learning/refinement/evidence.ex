defmodule Lemieux.Learning.Refinement.Evidence do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Evidence.Run
  alias Lemieux.Harness.Snapshot

  @spec record(
          observation :: map(),
          assessment :: term(),
          verifier? :: boolean(),
          runtime :: map()
        ) ::
          {:ok, map()} | {:error, term()}
  def record(observation, assessment, verifier?, runtime)
      when is_map(observation) and is_map(assessment) do
    qualification = observation["runtime_qualification"]
    entries = observation["transcript"] || []
    snapshot = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "harness_snapshot"))
    run = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "run_evidence"))
    score = assessment["score"]

    with true <- is_number(score) and score >= 0 and score <= 1,
         true <- is_boolean(assessment["regression"]),
         true <- observation["status"] == "completed",
         %{"lane" => "effective_lmx"} <- qualification,
         :ok <- Contract.verify_digest(qualification, "sha256"),
         :ok <- Contract.verify_digest(qualification["control"], "sha256"),
         :ok <- Contract.verify_digest(qualification["effective"], "sha256"),
         true <- qualification["control"]["sha256"] == runtime["control_sha256"],
         true <- is_nil(observation["provider_error"]),
         %{"payload" => harness} <- snapshot,
         :ok <- Snapshot.verify(harness),
         %{"payload" => evidence} <- run,
         :ok <- Run.verify(evidence),
         true <- evidence["harness_snapshot"]["semantic_sha256"] == harness["semantic_sha256"],
         true <- get_in(harness, ["workflow", "evaluation", "sha256"]) == qualification["sha256"],
         true <- not verifier? or is_boolean(assessment["verified_success"]) do
      {:ok,
       %{
         "score" => score,
         "regression" => assessment["regression"],
         "verified_success" => if(verifier?, do: assessment["verified_success"]),
         "observation_sha256" => Contract.digest(observation),
         "session_id" => observation["session_id"],
         "run_sha256" => evidence["sha256"],
         "harness_sha256" => harness["semantic_sha256"],
         "runtime_sha256" => qualification["sha256"]
       }}
    else
      _invalid -> {:error, :incomplete_probe_evidence}
    end
  end

  def record(_observation, _assessment, _verifier?, _runtime), do: {:error, :invalid_assessment}

  @spec supported?(
          control :: list(),
          candidate :: list(),
          verifier? :: boolean()
        ) :: boolean()
  def supported?(control, candidate, verifier?) do
    control != [] and length(control) == length(candidate) and
      Enum.min(Enum.map(candidate, & &1["score"])) > Enum.max(Enum.map(control, & &1["score"])) and
      Enum.all?(
        candidate,
        &(not &1["regression"] and (not verifier? or &1["verified_success"] == true))
      )
  end
end
