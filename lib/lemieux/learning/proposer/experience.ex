defmodule Lemieux.Learning.Proposer.Experience do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Experience.Retrieval
  alias Lemieux.Learning.Experience.Retrieval.Evidence

  @spec prepare(plan :: Plan.t(), context :: map()) :: {:ok, map()} | {:error, term()}
  def prepare(plan, %{experience: configure} = context) when is_function(configure, 1) do
    case configure.(context) do
      {:ok, config} when is_map(config) -> prepare(plan, Map.put(context, :experience, config))
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_experience_configuration}
    end
  end

  def prepare(plan, %{experience: config} = context) when is_map(config) do
    scope = plan.scope

    with true <-
           Enum.all?(~w(store library query binding consumer commit)a, &Map.has_key?(config, &1)),
         true <- is_map(config.library) and is_function(config.commit, 2),
         ^scope <- get_in(config, [:library, "scope"]),
         {:ok, result} <-
           Retrieval.retrieve(
             config.store,
             config.library,
             config.query,
             config.binding,
             config.consumer,
             config.commit,
             Map.get(config, :options, [])
           ) do
      {:ok, Map.put(context, :retrieved_experience, result)}
    else
      scope when is_map(scope) -> {:error, :experience_scope_mismatch}
      nil -> {:error, :experience_scope_mismatch}
      false -> {:error, :invalid_experience_configuration}
      error -> error
    end
  end

  def prepare(_plan, %{experience: config}) when not is_nil(config),
    do: {:error, :invalid_experience_configuration}

  def prepare(_plan, context), do: {:ok, context}

  @spec validate(
          context :: map(),
          parent :: map(),
          profile :: map(),
          manifest :: map(),
          validation :: term()
        ) :: term()
  def validate(
        %{retrieved_experience: result} = context,
        parent,
        profile,
        manifest,
        {:ok, _detail} = validation
      ) do
    repeated = Enum.filter(result.guards, &repeat?(&1, parent, profile))
    missing = Enum.reject(repeated, &reconsidered?(&1, manifest, context))

    if missing == [],
      do: validation,
      else:
        {:error,
         {:rejected_edit_requires_new_evidence,
          Enum.map(missing, & &1["lesson_id"]) |> Enum.uniq()}}
  end

  def validate(_context, _parent, _profile, _manifest, validation), do: validation

  @spec facts(context :: map()) :: map() | nil
  def facts(%{retrieved_experience: result}), do: result.receipt
  def facts(_context), do: nil

  @spec cases(context :: map()) :: [String.t()]
  def cases(%{retrieved_experience: %{exposure: %{source_case_ids: cases}}}), do: cases
  def cases(_context), do: []

  defp repeat?(guard, parent, profile) do
    changed = Surface.changed_paths(parent, profile)

    guard["profile_sha256"] == Contract.digest(profile) or
      (guard["changes"] != [] and
         Enum.all?(guard["changes"], fn change ->
           change["path"] in changed and
             Evidence.value_digest(profile, change["path"]) == change["after_sha256"]
         end))
  end

  defp reconsidered?(guard, manifest, context) do
    proposals = manifest["reconsiderations"]
    is_list(proposals) and Enum.any?(proposals, &valid_reconsideration?(&1, guard, context))
  end

  defp valid_reconsideration?(
         %{"lesson_id" => id, "rationale" => rationale, "evaluation_refs" => refs},
         guard,
         context
       )
       when is_binary(rationale) and is_list(refs) do
    id == guard["lesson_id"] and String.trim(rationale) != "" and byte_size(rationale) <= 2048 and
      refs != [] and
      Enum.all?(refs, &new_evaluation?(&1, guard, context))
  end

  defp valid_reconsideration?(_value, _guard, _context), do: false

  defp new_evaluation?(%{"id" => id, "sha256" => sha}, guard, context) do
    Enum.any?(Map.get(context, :evaluations, []), fn evaluation ->
      evaluation.id == id and evaluation.sha256 == sha and sha not in guard["source_digests"] and
        id not in guard["source_evaluation_ids"] and
        new_development_evidence?(evaluation, context)
    end)
  end

  defp new_evaluation?(_value, _guard, _context), do: false

  defp new_development_evidence?(%Evaluation{} = evaluation, context) do
    plan = Map.fetch!(context, :experience_plan)

    Evaluation.verify(evaluation) == :ok and evaluation.scope == plan.scope and
      evaluation.plan_sha256 == plan.sha256 and evaluation.split == "development" and
      evaluation.case_id in plan.development_case_ids and evaluation.terminal and
      evaluation.within_budget and complete_evidence?(evaluation)
  end

  defp complete_evidence?(evaluation) do
    evaluation.safety["passed"] == true and evaluation.observations["finish_reason"] != ":error" and
      Enum.all?(evaluation.completeness, fn {_key, state} ->
        state in ~w(complete not_applicable)
      end)
  end
end
