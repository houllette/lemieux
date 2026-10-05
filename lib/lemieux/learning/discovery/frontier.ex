defmodule Lemieux.Learning.Discovery.Frontier do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Deterministic Pareto membership after hard-invalid candidates are removed.

  Interface, safety, completeness, terminality, and budget are eligibility
  gates. Objective values are compared only after those gates pass, so a hard
  failure can never be compensated by quality, speed, or cost.

  ## Plan-declared constraint gates

  `plan.hard_constraints` entries are applied as further gates, in plan
  order, after the built-in ones. Entries the frontier does not understand
  (the legacy `%{"kind" => "mechanical"}` marker, host-specific kinds) are
  ignored here because they are enforced elsewhere; an entry of a known kind
  with a malformed value fails `compute/3` instead, because a constraint the
  plan declares but the frontier silently skips would pass every candidate
  while looking enforced.

    * `%{"kind" => "no_solved_regression"}` excludes a candidate with reason
      `"solved_regression"` when its parent solved a development case that
      the candidate then failed. Pareto over mean objectives cannot see this:
      a child that gains two cases and loses one improves the mean and
      dominates its parent, and a lineage of such steps walks the archive in
      circles — the seesaw HarnessX guards against and the non-regression rule
      Self-Harness applies. "Solved" means every one of the parent's
      evaluations on that case reached the search policy's success threshold
      (`Lemieux.Learning.Discovery.Policy.success?/2`), or the constraint's own
      `"threshold"` when it declares one. The parent is the first entry of
      `candidate.parents` that names another candidate in the list; a seed
      parent, or a parent never evaluated on a case, solved nothing there, so
      no regression is possible against it.
    * `%{"kind" => "max_content_bytes", "value" => n}` excludes a candidate
      with reason `"content_too_large"` when `candidate.content.size_bytes`
      exceeds `n`. Without it a proposer can grow an instruction file until it
      memorizes the development cases, and the mean objective rewards it.

  The wire shape does not change: excluded entries carry the same
  `candidate_id`/`reason` pair as the built-in gates, so a host that displays
  reasons needs no new branch for these.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  @version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          sha256: String.t(),
          plan_id: String.t(),
          plan_sha256: String.t(),
          objectives: [map()],
          members: [map()],
          excluded: [map()]
        }

  @enforce_keys [:id, :sha256, :plan_id, :plan_sha256, :objectives, :members, :excluded]
  defstruct schema_version: @version,
            id: nil,
            sha256: nil,
            plan_id: nil,
            plan_sha256: nil,
            objectives: [],
            members: [],
            excluded: []

  @doc "Computes deterministic frontier membership for one frozen plan."
  @spec compute(plan :: Plan.t(), candidates :: [Candidate.t()], evaluations :: [Evaluation.t()]) ::
          {:ok, t()} | {:error, term()}
  def compute(%Plan{} = plan, candidates, evaluations)
      when is_list(candidates) and is_list(evaluations) do
    with :ok <- verify_all(candidates, &Candidate.verify/1),
         :ok <- verify_all(evaluations, &Evaluation.verify/1),
         :ok <- Candidate.verify_lineage(candidates, plan.seeds),
         :ok <- evaluation_identity(plan, candidates, evaluations),
         :ok <- verify_constraints(plan.hard_constraints) do
      {eligible, excluded} = eligible_candidates(plan, candidates, evaluations)

      members =
        eligible
        |> Enum.reject(&dominated?(&1, eligible, plan))
        |> Enum.map(&frontier_entry/1)
        |> Enum.sort_by(& &1["candidate_id"])

      base = %{
        "schema_version" => @version,
        "plan_id" => plan.id,
        "plan_sha256" => plan.sha256,
        "objectives" => plan.objectives,
        "members" => members,
        "excluded" => Enum.sort_by(excluded, & &1["candidate_id"])
      }

      sha256 = Contract.digest(base)
      id = "frontier_" <> binary_part(sha256, 0, 24)
      wire = base |> Map.put("id", id) |> then(&Map.put(&1, "sha256", Contract.digest(&1)))
      {:ok, from_verified_map(wire)}
    end
  end

  @doc "Returns the JSON-shaped frontier."
  @spec to_map(frontier :: t()) :: map()
  def to_map(%__MODULE__{} = frontier) do
    %{
      "schema_version" => frontier.schema_version,
      "id" => frontier.id,
      "sha256" => frontier.sha256,
      "plan_id" => frontier.plan_id,
      "plan_sha256" => frontier.plan_sha256,
      "objectives" => frontier.objectives,
      "members" => frontier.members,
      "excluded" => frontier.excluded
    }
  end

  @doc "Encodes a canonical frontier."
  @spec encode!(frontier :: t()) :: String.t()
  def encode!(%__MODULE__{} = frontier), do: frontier |> to_map() |> Contract.encode!()

  @doc "Decodes a frontier only for the exact plan it summarizes."
  @spec decode(plan :: Plan.t(), json :: String.t()) :: {:ok, t()} | {:error, term()}
  def decode(%Plan{} = plan, json) when is_binary(json) do
    with {:ok, map} <- Contract.decode(json),
         :ok <- Contract.verify_version(map, "schema_version", @version),
         true <- map["plan_id"] == plan.id and map["plan_sha256"] == plan.sha256,
         :ok <- verify(map) do
      {:ok, from_verified_map(map)}
    else
      false -> {:error, :frontier_plan_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Verifies version and digest."
  @spec verify(frontier_or_map :: t() | map()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = frontier), do: frontier |> to_map() |> verify()

  def verify(map) when is_map(map) do
    with :ok <- Contract.verify_version(map, "schema_version", @version) do
      Contract.verify_digest(map, "sha256")
    end
  end

  def verify(_other), do: {:error, :invalid_frontier}

  defp verify_all(values, verifier) do
    Enum.reduce_while(values, :ok, fn value, :ok ->
      case verifier.(value) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp evaluation_identity(plan, candidates, evaluations) do
    index = Map.new(candidates, &{&1.id, &1})

    case Enum.find(evaluations, fn evaluation ->
           candidate = Map.get(index, evaluation.candidate_id)

           is_nil(candidate) or evaluation.plan_id != plan.id or
             evaluation.plan_sha256 != plan.sha256 or
             evaluation.candidate_content_sha256 != Candidate.content_sha256(candidate)
         end) do
      nil -> :ok
      evaluation -> {:error, {:evaluation_identity_mismatch, evaluation.id}}
    end
  end

  defp verify_constraints(constraints) do
    case Enum.find(constraints, &(not well_formed_constraint?(&1))) do
      nil -> :ok
      constraint -> {:error, {:invalid_hard_constraint, constraint["id"]}}
    end
  end

  defp well_formed_constraint?(%{"kind" => "max_content_bytes"} = constraint),
    do: is_number(constraint["value"]) and constraint["value"] >= 0

  defp well_formed_constraint?(%{"kind" => "no_solved_regression"} = constraint),
    do: is_nil(constraint["threshold"]) or is_number(constraint["threshold"])

  defp well_formed_constraint?(_constraint), do: true

  defp eligible_candidates(plan, candidates, evaluations) do
    grouped = Enum.group_by(evaluations, & &1.candidate_id)
    gates = constraint_gates(plan, candidates, grouped)

    candidates
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce({[], []}, fn candidate, {eligible, excluded} ->
      observations = Map.get(grouped, candidate.id, [])

      case eligibility(candidate, observations, gates) do
        :ok ->
          scores = scores(plan, observations)

          {[
             %{
               id: candidate.id,
               content_sha256: Candidate.content_sha256(candidate),
               scores: scores
             }
             | eligible
           ], excluded}

        {:error, reason} ->
          {eligible,
           [%{"candidate_id" => candidate.id, "reason" => Atom.to_string(reason)} | excluded]}
      end
    end)
  end

  # Built-in gates run first so a candidate with no evidence at all is
  # reported as such rather than as a regression it could not have committed.
  defp eligibility(candidate, observations, gates) do
    with :ok <- eligibility(candidate, observations),
         do: constrained_by_all(gates, candidate, observations)
  end

  defp eligibility(%Candidate{interface_validation: %{"status" => status}}, _evaluations)
       when status != "passed",
       do: {:error, :interface_invalid}

  defp eligibility(_candidate, []), do: {:error, :no_evaluations}

  # A safety failure and incomplete evidence are both disqualifying, but a
  # report that cannot tell them apart sends the reader to the wrong place:
  # the first is a fact about the candidate, the second about the run.
  defp eligibility(_candidate, evaluations) do
    cond do
      Enum.any?(evaluations, &(&1.safety["passed"] != true)) -> {:error, :safety_failed}
      Enum.all?(evaluations, &Evaluation.eligible?/1) -> :ok
      true -> {:error, :evidence_incomplete}
    end
  end

  # Gates run in plan order; the first one that rejects names the reason.
  defp constrained_by_all(gates, candidate, observations) do
    Enum.reduce_while(gates, :ok, fn gate, :ok ->
      case constrained(gate, candidate, observations) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp constraint_gates(plan, candidates, grouped) do
    policy = Policy.read(plan)
    index = Map.new(candidates, &{&1.id, &1})

    Enum.flat_map(plan.hard_constraints, fn
      %{"kind" => "max_content_bytes", "value" => limit} ->
        [{:max_content_bytes, limit}]

      %{"kind" => "no_solved_regression"} = constraint ->
        threshold = Map.get(constraint, "threshold") || policy["success_threshold"]
        scoped = Map.put(policy, "success_threshold", threshold)
        [{:no_solved_regression, %{policy: scoped, index: index, grouped: grouped}}]

      _other ->
        []
    end)
  end

  defp constrained({:max_content_bytes, limit}, candidate, _observations) do
    if candidate.content.size_bytes > limit, do: {:error, :content_too_large}, else: :ok
  end

  defp constrained({:no_solved_regression, context}, candidate, observations) do
    solved = solved_cases(candidate, context)

    regressed? =
      Enum.any?(observations, fn evaluation ->
        Map.has_key?(solved, evaluation.case_id) and
          not Policy.success?(evaluation, context.policy)
      end)

    if regressed?, do: {:error, :solved_regression}, else: :ok
  end

  # The solved set is a plain map keyed by case id: a `MapSet` built in one
  # branch and empty in the other loses its opaqueness under Dialyzer.
  defp solved_cases(candidate, %{index: index, grouped: grouped, policy: policy}) do
    case Enum.find(candidate.parents, &Map.has_key?(index, &1["id"])) do
      nil ->
        %{}

      parent ->
        grouped
        |> Map.get(parent["id"], [])
        |> Enum.filter(&Policy.development?/1)
        |> Enum.group_by(& &1.case_id)
        |> Enum.filter(fn {_case_id, runs} -> Enum.all?(runs, &Policy.success?(&1, policy)) end)
        |> Map.new(fn {case_id, _runs} -> {case_id, true} end)
    end
  end

  # Scores are means over cases, each case first averaged over its own evaluations.
  # A plain mean over evaluations would weigh a case run three times three times as
  # much, and the cases a policy repeats are the safety-critical ones — so the
  # score meant to compare candidates across the split would be dominated by them.
  # Cases and runs are visited sorted, so the floating-point sums do not depend on
  # the order a host returned its evaluations.
  defp scores(plan, evaluations) do
    by_case =
      evaluations
      |> Enum.group_by(& &1.case_id)
      |> Enum.sort_by(fn {case_id, _runs} -> case_id end)
      |> Enum.map(fn {_case_id, runs} -> Enum.sort_by(runs, & &1.id) end)

    Map.new(plan.objectives, fn objective ->
      name = objective["name"]

      case_means =
        Enum.map(by_case, fn runs -> mean(Enum.map(runs, &Map.fetch!(&1.objectives, name))) end)

      {name, mean(case_means)}
    end)
  end

  defp mean(values), do: Enum.sum(values) / length(values)

  defp dominates?(left, right, plan) do
    comparisons =
      Enum.map(plan.objectives, fn objective ->
        left_value = left.scores[objective["name"]]
        right_value = right.scores[objective["name"]]
        compare(left_value, right_value, objective["direction"])
      end)

    Enum.all?(comparisons, &(&1 in [:better, :equal])) and
      Enum.any?(comparisons, &(&1 == :better))
  end

  defp dominated?(candidate, eligible, plan) do
    Enum.any?(eligible, fn other ->
      other.id != candidate.id and dominates?(other, candidate, plan)
    end)
  end

  defp compare(left, right, "maximize") when left > right, do: :better
  defp compare(left, right, "maximize") when left < right, do: :worse
  defp compare(left, right, "minimize") when left < right, do: :better
  defp compare(left, right, "minimize") when left > right, do: :worse
  defp compare(_left, _right, _direction), do: :equal

  defp frontier_entry(candidate) do
    %{
      "candidate_id" => candidate.id,
      "content_sha256" => candidate.content_sha256,
      "scores" => candidate.scores
    }
  end

  defp from_verified_map(map) do
    %__MODULE__{
      id: map["id"],
      sha256: map["sha256"],
      plan_id: map["plan_id"],
      plan_sha256: map["plan_sha256"],
      objectives: map["objectives"],
      members: map["members"],
      excluded: map["excluded"]
    }
  end
end
