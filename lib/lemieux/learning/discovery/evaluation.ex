defmodule Lemieux.Learning.Discovery.Evaluation do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A terminal development or validation observation for one candidate.

  Safety, completeness, and budget status remain separate from objective
  scores so a frontier cannot trade missing evidence or a hard failure for
  quality. Holdout is intentionally not an accepted split.
  """

  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Plan

  @version 1
  @splits ~w(development validation)
  @complete_states ~w(complete not_applicable)

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          created_at: DateTime.t(),
          plan_id: String.t(),
          plan_sha256: String.t(),
          candidate_id: String.t(),
          candidate_content_sha256: String.t(),
          scope: map(),
          case_id: String.t(),
          split: String.t(),
          objectives: map(),
          safety: map(),
          completeness: map(),
          usage: map(),
          cost: map(),
          latency: map(),
          artifacts: [ArtifactReference.t()],
          within_budget: boolean(),
          terminal: boolean(),
          observations: map(),
          extensions: map()
        }

  @enforce_keys [
    :id,
    :sha256,
    :created_at,
    :plan_id,
    :plan_sha256,
    :candidate_id,
    :candidate_content_sha256,
    :scope,
    :case_id,
    :split,
    :objectives,
    :safety,
    :completeness,
    :usage,
    :cost,
    :latency,
    :artifacts,
    :within_budget,
    :terminal,
    :observations,
    :extensions
  ]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            created_at: nil,
            plan_id: nil,
            plan_sha256: nil,
            candidate_id: nil,
            candidate_content_sha256: nil,
            scope: %{},
            case_id: nil,
            split: nil,
            objectives: %{},
            safety: %{},
            completeness: %{},
            usage: %{},
            cost: %{},
            latency: %{},
            artifacts: [],
            within_budget: false,
            terminal: false,
            observations: %{},
            extensions: %{}

  @doc "Builds a terminal candidate evaluation under its exact discovery plan."
  @spec new(plan :: Plan.t(), candidate :: Candidate.t(), attrs :: map()) ::
          {:ok, t()} | {:error, term()}
  def new(%Plan{} = plan, %Candidate{} = candidate, attrs) when is_map(attrs) do
    attrs = Contract.json(attrs)
    scope = plan.scope

    with true <- candidate.plan_id == plan.id and candidate.plan_sha256 == plan.sha256,
         :ok <- nonempty(attrs["id"], "id"),
         ^scope <- attrs["scope"],
         :ok <- nonempty(attrs["case_id"], "case_id"),
         :ok <- split(attrs["split"], attrs["case_id"], plan),
         :ok <- objective_values(attrs["objectives"], plan),
         :ok <- safety(attrs["safety"]),
         :ok <- completeness(attrs["completeness"]),
         :ok <- fact_maps(attrs),
         {:ok, artifacts} <- artifacts(attrs["artifacts"], plan.scope),
         true <- is_boolean(attrs["within_budget"]),
         true <- is_boolean(attrs["terminal"]),
         {:ok, created_at} <- parse_time(Map.get(attrs, "created_at", now())) do
      base = %{
        "schema_version" => @version,
        "id" => attrs["id"],
        "created_at" => DateTime.to_iso8601(created_at),
        "plan_id" => plan.id,
        "plan_sha256" => plan.sha256,
        "candidate_id" => candidate.id,
        "candidate_content_sha256" => Candidate.content_sha256(candidate),
        "scope" => plan.scope,
        "case_id" => attrs["case_id"],
        "split" => attrs["split"],
        "objectives" => attrs["objectives"],
        "safety" => attrs["safety"],
        "completeness" => attrs["completeness"],
        "usage" => attrs["usage"],
        "cost" => attrs["cost"],
        "latency" => attrs["latency"],
        "artifacts" => Enum.map(artifacts, &ArtifactReference.to_map/1),
        "within_budget" => attrs["within_budget"],
        "terminal" => attrs["terminal"],
        "observations" => attrs["observations"],
        "extensions" => Map.get(attrs, "extensions", %{})
      }

      sha256 = Contract.digest(base)

      if Map.get(attrs, "sha256", sha256) == sha256 do
        {:ok, from_verified_map(Map.put(base, "sha256", sha256), artifacts, created_at)}
      else
        {:error, :digest_mismatch}
      end
    else
      false -> {:error, :evaluation_identity_mismatch}
      mismatch when is_map(mismatch) -> {:error, :evaluation_scope_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns true only when all hard eligibility evidence is terminal and complete."
  @spec eligible?(evaluation :: t()) :: boolean()
  def eligible?(%__MODULE__{} = evaluation) do
    evaluation.terminal and evaluation.within_budget and evaluation.safety["passed"] == true and
      Enum.all?(evaluation.completeness, fn {_name, state} -> state in @complete_states end)
  end

  @doc "Returns the JSON-shaped evaluation."
  @spec to_map(evaluation :: t()) :: map()
  def to_map(%__MODULE__{} = evaluation) do
    %{
      "schema_version" => evaluation.schema_version,
      "id" => evaluation.id,
      "sha256" => evaluation.sha256,
      "created_at" => DateTime.to_iso8601(evaluation.created_at),
      "plan_id" => evaluation.plan_id,
      "plan_sha256" => evaluation.plan_sha256,
      "candidate_id" => evaluation.candidate_id,
      "candidate_content_sha256" => evaluation.candidate_content_sha256,
      "scope" => evaluation.scope,
      "case_id" => evaluation.case_id,
      "split" => evaluation.split,
      "objectives" => evaluation.objectives,
      "safety" => evaluation.safety,
      "completeness" => evaluation.completeness,
      "usage" => evaluation.usage,
      "cost" => evaluation.cost,
      "latency" => evaluation.latency,
      "artifacts" => Enum.map(evaluation.artifacts, &ArtifactReference.to_map/1),
      "within_budget" => evaluation.within_budget,
      "terminal" => evaluation.terminal,
      "observations" => evaluation.observations,
      "extensions" => evaluation.extensions
    }
  end

  @doc "Encodes a canonical evaluation."
  @spec encode!(evaluation :: t()) :: String.t()
  def encode!(%__MODULE__{} = evaluation), do: evaluation |> to_map() |> Contract.encode!()

  @doc "Decodes an evaluation only with the exact plan and candidate it names."
  @spec decode(plan :: Plan.t(), candidate :: Candidate.t(), json :: String.t()) ::
          {:ok, t()} | {:error, term()}
  def decode(%Plan{} = plan, %Candidate{} = candidate, json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         true <- identities_match?(map, plan, candidate),
         :ok <- verify(map),
         {:ok, evaluation} <- new(plan, candidate, map) do
      {:ok, evaluation}
    else
      false -> {:error, :evaluation_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Verifies version and manifest digest."
  @spec verify(evaluation_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = evaluation), do: evaluation |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_evaluation}

  defp identities_match?(map, plan, candidate) do
    map["plan_id"] == plan.id and map["plan_sha256"] == plan.sha256 and
      map["candidate_id"] == candidate.id and
      map["candidate_content_sha256"] == Candidate.content_sha256(candidate)
  end

  defp split(value, case_id, plan) when value in @splits do
    expected =
      if value == "development", do: plan.development_case_ids, else: plan.validation_case_ids

    if case_id in expected, do: :ok, else: {:error, {:case_not_in_split, case_id, value}}
  end

  defp split("holdout", _case_id, _plan), do: {:error, :holdout_not_discovery_visible}
  defp split(value, _case_id, _plan), do: {:error, {:invalid_discovery_split, value}}

  defp objective_values(values, plan) when is_map(values) do
    required = Enum.map(plan.objectives, & &1["name"])

    if Enum.sort(Map.keys(values)) == Enum.sort(required) and
         Enum.all?(values, fn {_name, value} -> is_number(value) end),
       do: :ok,
       else: {:error, :invalid_objective_values}
  end

  defp objective_values(_values, _plan), do: {:error, :invalid_objective_values}

  defp safety(%{"passed" => passed, "failures" => failures})
       when is_boolean(passed) and is_list(failures) do
    if passed == (failures == []), do: :ok, else: {:error, :inconsistent_safety_evidence}
  end

  defp safety(_value), do: {:error, :invalid_safety_evidence}

  defp completeness(value) when is_map(value) and map_size(value) > 0 do
    if Enum.all?(value, fn {_name, state} -> is_binary(state) end),
      do: :ok,
      else: {:error, :invalid_completeness}
  end

  defp completeness(_value), do: {:error, :invalid_completeness}

  defp fact_maps(attrs) do
    case Enum.find(~w(usage cost latency observations), &(not is_map(attrs[&1]))) do
      nil -> :ok
      field -> {:error, {:invalid_evaluation_field, field}}
    end
  end

  defp artifacts(value, scope) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn map, {:ok, built} ->
      case ArtifactReference.from_map(map) do
        {:ok, %ArtifactReference{scope: ^scope} = reference} ->
          {:cont, {:ok, [reference | built]}}

        {:ok, _reference} ->
          {:halt, {:error, :evaluation_artifact_scope_mismatch}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_evaluation_artifact, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp artifacts(_value, _scope), do: {:error, :invalid_evaluation_artifacts}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_evaluation_field, field}}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, 0} -> {:ok, time}
      _invalid -> {:error, :invalid_created_at}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_created_at}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())

  defp from_verified_map(map, artifacts, created_at) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      created_at: created_at,
      plan_id: map["plan_id"],
      plan_sha256: map["plan_sha256"],
      candidate_id: map["candidate_id"],
      candidate_content_sha256: map["candidate_content_sha256"],
      scope: map["scope"],
      case_id: map["case_id"],
      split: map["split"],
      objectives: map["objectives"],
      safety: map["safety"],
      completeness: map["completeness"],
      usage: map["usage"],
      cost: map["cost"],
      latency: map["latency"],
      artifacts: artifacts,
      within_budget: map["within_budget"],
      terminal: map["terminal"],
      observations: map["observations"],
      extensions: map["extensions"]
    }
  end
end
