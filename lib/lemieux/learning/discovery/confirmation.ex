defmodule Lemieux.Learning.Discovery.Confirmation do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  The narrow, one-way bridge from discovery to independent confirmation.

  The host selects one candidate and supplies every confirmatory fact. Search
  observations are retained only as provenance and never populate hidden
  measurements. The result is an ordinary immutable
  `Lemieux.Experiment.Plan`; discovery gains no activation or decision API.
  Harness-code candidates additionally need complete `CodeGate` evidence and
  remain marked for human release.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Experiment.CodeGate
  alias Lemieux.Experiment.Plan, as: ExperimentPlan
  alias Lemieux.Learning.Discovery.Candidate

  @required ~w(hypothesis control metric sample stopping_rule budget)
  @forbidden ~w(holdout_observations hidden_outcomes confirmation_results)

  @doc "Freezes candidate bytes into a normal preregistered experiment plan."
  @spec to_experiment(candidate :: Candidate.t(), bytes :: iodata(), attrs :: map()) ::
          {:ok, ExperimentPlan.t()} | {:error, term()}
  def to_experiment(%Candidate{} = candidate, bytes, attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)
    bytes = IO.iodata_to_binary(bytes)

    with :ok <- required(attrs),
         :ok <- forbidden(attrs),
         :ok <- Candidate.verify(candidate),
         :ok <- ArtifactReference.verify_bytes(candidate.content, bytes),
         {:ok, code_policy} <- code_policy(candidate, attrs) do
      experiment_attrs = %{
        "hypothesis" => attrs["hypothesis"],
        "variant" => %{
          "digest" => candidate.content.sha256,
          "changes" => [
            %{
              "field" => Map.get(attrs, "target", candidate.mutation_kind),
              "to" => candidate.id
            }
          ]
        },
        "control" => attrs["control"],
        "metric" => attrs["metric"],
        "sample" => attrs["sample"],
        "stopping_rule" => attrs["stopping_rule"],
        "budget" => attrs["budget"],
        "provenance" => %{
          "discovery" => %{
            "plan_id" => candidate.plan_id,
            "plan_sha256" => candidate.plan_sha256,
            "candidate_id" => candidate.id,
            "candidate_sha256" => candidate.sha256,
            "content_sha256" => candidate.content.sha256,
            "parents" => candidate.parents,
            "exposures" => candidate.exposures
          },
          "development_validation_evaluations" =>
            Map.get(attrs, "development_validation_evaluations", []),
          "confirmation_evidence_prepopulated" => false,
          "release_policy" => code_policy
        }
      }

      ExperimentPlan.new(experiment_attrs)
    end
  end

  def to_experiment(%Candidate{}, _bytes, _attrs), do: {:error, :invalid_confirmation_attrs}

  defp required(attrs) do
    case Enum.find(@required, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_confirmation_field, field}}
    end
  end

  defp forbidden(attrs) do
    case Enum.find(@forbidden, &Map.has_key?(attrs, &1)) do
      nil -> :ok
      field -> {:error, {:prepopulated_confirmation_evidence, field}}
    end
  end

  defp code_policy(%Candidate{mutation_kind: "harness_code"}, attrs) do
    case CodeGate.evaluate(Map.get(attrs, "code_gate", %{})) do
      {:ok, evidence} ->
        {:ok,
         %{
           "human_release_only" => true,
           "code_gate" => Contract.json(evidence)
         }}

      {:error, reason} ->
        {:error, {:code_gate_required, reason}}
    end
  end

  defp code_policy(%Candidate{}, _attrs),
    do: {:ok, %{"human_release_only" => false, "code_gate" => nil}}
end
