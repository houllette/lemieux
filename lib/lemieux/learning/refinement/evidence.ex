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
  @spec record(
          observation :: map(),
          assessment :: term(),
          verifier? :: boolean(),
          runtime :: map(),
          terminal_rule :: :completed_task | :artifact_outcome
        ) :: {:ok, map()} | {:error, term()}
  def record(observation, assessment, verifier?, runtime, terminal_rule \\ :completed_task)

  def record(observation, assessment, verifier?, runtime, terminal_rule)
      when is_map(observation) and is_map(assessment) do
    qualification = observation["runtime_qualification"]
    entries = observation["transcript"] || []
    snapshot = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "harness_snapshot"))
    run = entries |> Enum.reverse() |> Enum.find(&(&1["type"] == "run_evidence"))
    score = assessment["score"]

    with true <- is_number(score) and score >= 0 and score <= 1,
         true <- is_boolean(assessment["regression"]),
         %{"lane" => "effective_lmx"} <- qualification,
         :ok <- Contract.verify_digest(qualification, "sha256"),
         :ok <- Contract.verify_digest(qualification["control"], "sha256"),
         :ok <- Contract.verify_digest(qualification["effective"], "sha256"),
         true <- qualification["control"]["sha256"] == runtime["control_sha256"],
         %{"payload" => harness} <- snapshot,
         :ok <- Snapshot.verify(harness),
         %{"payload" => evidence} <- run,
         :ok <- Run.verify(evidence),
         true <- evidence["harness_snapshot"]["semantic_sha256"] == harness["semantic_sha256"],
         true <- get_in(harness, ["workflow", "evaluation", "sha256"]) == qualification["sha256"],
         true <- not verifier? or is_boolean(assessment["verified_success"]),
         {:ok, assessment} <-
           terminal_assessment(observation, evidence, assessment, terminal_rule) do
      {:ok,
       %{
         "score" => assessment["score"],
         "verifier_score" => score,
         "scoring_rule" => Atom.to_string(terminal_rule),
         "regression" => assessment["regression"],
         "safety_failure" => Map.get(assessment, "safety_failure", assessment["regression"]),
         "evidence_complete" => true,
         "verified_success" =>
           if(verifier? or observation["status"] == "failed", do: assessment["verified_success"]),
         "status" => observation["status"],
         "stop_reason" => evidence["stop_reason"],
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

  def record(_observation, _assessment, _verifier?, _runtime, _rule),
    do: {:error, :invalid_assessment}

  @doc false
  @spec terminal(observation :: map(), evidence :: map(), assessment :: map()) ::
          {:ok, map()} | {:error, term()}
  @spec terminal(
          observation :: map(),
          evidence :: map(),
          assessment :: map(),
          terminal_rule :: :completed_task | :artifact_outcome
        ) :: {:ok, map()} | {:error, term()}
  def terminal(observation, evidence, assessment, terminal_rule \\ :completed_task),
    do: terminal_assessment(observation, evidence, assessment, terminal_rule)

  defp terminal_assessment(
         %{"status" => "completed", "provider_error" => nil},
         _evidence,
         assessment,
         rule
       )
       when rule in [:completed_task, :artifact_outcome],
       do: {:ok, assessment}

  # The profile's turn limit is an observed failure, just as in Discovery's
  # evaluator. Treating it as missing evidence prevented any proposal on hard
  # tasks. Only a matching terminal manifest with complete accounting qualifies;
  # cancellation, provider failures and evaluator clocks still require recovery.
  # The default requires completion. An explicitly registered artifact study
  # instead uses the same external file grader for every arm. A known budget
  # stop after a correct patch must not erase that grade only for probes; stop
  # status remains recorded separately. Provider/cancellation/unknown stops
  # never receive this exception.
  defp terminal_assessment(
         %{
           "status" => "failed",
           "finish_reason" => ":max_turns",
           "provider_error" => notice
         },
         %{
           "outcome" => "stopped",
           "stop_reason" => "max_turns",
           "usage" => %{"state" => "complete"},
           "completeness" => %{"usage" => "complete", "artifacts" => "complete"}
         },
         assessment,
         rule
       ) do
    case {turn_limit_notice?(notice), rule} do
      {true, :artifact_outcome} ->
        {:ok, assessment}

      {true, :completed_task} ->
        {:ok,
         Map.merge(assessment, %{
           "score" => 0.0,
           "regression" => true,
           "verified_success" => false
         })}

      _invalid ->
        {:error, :incomplete_probe_evidence}
    end
  end

  defp terminal_assessment(_observation, _evidence, _assessment, _rule),
    do: {:error, :incomplete_probe_evidence}

  # Agent.Session projects the loop's own error notice into provider_error too.
  # A categorized provider failure is never this notice, even with known usage.
  defp turn_limit_notice?(nil), do: true

  defp turn_limit_notice?(%{
         "category" => nil,
         "code" => nil,
         "http_status" => nil,
         "reason" => reason
       })
       when is_binary(reason),
       do: Regex.match?(~r/\Astopped after [1-9][0-9]* turns\z/, reason)

  defp turn_limit_notice?(_notice), do: false

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
