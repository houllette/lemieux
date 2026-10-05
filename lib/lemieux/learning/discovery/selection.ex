defmodule Lemieux.Learning.Discovery.Selection do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Archive selection for discovery: which candidate to expand next, which
  candidate to evaluate next, and on which cases.

  The obvious alternative is a linear loop — propose, evaluate on every
  development case, repeat until the budget runs out. That spends the same
  evaluation budget on a hopeless candidate as on a promising one, and it has
  no memory: a lineage whose root scored well but whose every child failed
  keeps being expanded because only the root's own score is consulted. This
  module instead follows the Huxley-Gödel Machine (Thompson sampling over Beta
  posteriors at node and clade level, with a widening rule deciding whether to
  expand the archive or evaluate more of it) and the Mendel Gödel Machine
  (cases some candidate already failed are sampled with extra weight, because
  a case nothing fails tells the search nothing).

  Three constraints shape the code:

  * **It is pure.** No process, no clock, no global random state. Randomness
    is an explicit `:rand` state threaded in and out, seeded by the host from
    `policy["seed"]`. Every action a host records into `State` events is then
    reproducible from the same archive and seed, which is what makes a replay
    a check rather than a re-roll. A hidden `:rand.uniform/0` would make the
    policy's seed a lie the first time anyone tried to reproduce a run.
  * **Input order never changes the answer.** Hosts rebuild the archive from
    events, files, or a database in whatever order those return it, so
    candidates are always visited sorted by id before any draw is taken.
  * **Only the archive counts.** Evaluations naming a candidate that is not in
    the candidate list are ignored everywhere (posteriors, widening counts,
    discrimination). A host that filters its candidate list gets a selection
    over exactly that list, not one skewed by evidence for candidates it chose
    not to pass.

  Two corners of the widening rule are settled here rather than left to the
  formula. When nothing is evaluable yet but a candidate is waiting to be
  evaluated, the answer is to evaluate it: expanding from the seed again would
  only add a second unevaluated sibling, and `N^alpha >= 0` would otherwise
  say "expand" forever. When the candidate budget is reached, the answer is
  never to expand, since `State.record_candidate/4` would refuse the result;
  pending candidates are evaluated instead, and `:done` follows once none
  remain.

  `policy["always_case_ids"]` are never deferred by a fidelity tier: they are
  the cases the plan author has decided every candidate must face first, so a
  tier of size one still carries all of them.
  """

  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Evaluation
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Policy

  @type rng :: :rand.state()
  @type parent :: {:seed, map()} | {:candidate, String.t()}
  @type action :: {:expand, parent()} | {:evaluate, String.t(), [String.t()]} | :done
  @type posterior :: %{required(String.t()) => number()}

  @posterior_keys [
    "successes",
    "failures",
    "alpha",
    "beta",
    "mean",
    "clade_successes",
    "clade_failures",
    "clade_alpha",
    "clade_beta",
    "clade_mean"
  ]

  @doc """
  Beta posteriors for every candidate in the archive, at node and clade level.

  Only development-split evaluations count, success is `Policy.success?/2`,
  and the prior is `policy["prior"]` as `[alpha, beta]`. A candidate's clade
  is itself plus every descendant reachable through `parents` links. A
  candidate with no evaluations is present with the bare prior.
  """
  @spec posteriors(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: %{required(String.t()) => posterior()}
  def posteriors(%Plan{} = plan, candidates, evaluations, policy)
      when is_list(candidates) and is_list(evaluations) and is_map(policy) do
    archive(plan, candidates, evaluations, policy).posteriors
  end

  @doc """
  Draws one Beta(alpha, beta) sample as the ratio of two Gamma draws.

  Gamma draws use Marsaglia and Tsang's squeeze method for shapes of at least
  one and the `U^(1/shape)` boost below one, so any positive prior works. The
  draw is a pure function of the rng state passed in.
  """
  @spec sample_beta(alpha :: number(), beta :: number(), rng :: rng()) :: {float(), rng()}
  def sample_beta(alpha, beta, rng) when alpha > 0 and beta > 0 do
    {x, rng} = gamma(alpha, rng)
    {y, rng} = gamma(beta, rng)
    {ratio(x, y), rng}
  end

  @doc """
  Per-case discrimination: the population variance of the success indicator
  across the distinct candidates evaluated on that case.

  A candidate with several evaluations on one case counts once, at its mean.
  Cases seen by fewer than two candidates score `0.0`; every development case
  in the plan appears in the result.
  """
  @spec discrimination(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: %{required(String.t()) => float()}
  def discrimination(%Plan{} = plan, candidates, evaluations, policy)
      when is_list(candidates) and is_list(evaluations) and is_map(policy) do
    plan |> archive(candidates, evaluations, policy) |> case_discrimination()
  end

  @doc "Sorted development case ids already evaluated for one candidate."
  @spec evaluated_case_ids(candidate_id :: String.t(), evaluations :: [Evaluation.t()]) ::
          [String.t()]
  def evaluated_case_ids(candidate_id, evaluations)
      when is_binary(candidate_id) and is_list(evaluations) do
    evaluations
    |> Enum.filter(&(&1.candidate_id == candidate_id and Policy.development?(&1)))
    |> case_ids()
  end

  @doc """
  Thompson-samples a parent among evaluable candidates: interface passed, not
  vetoed by the critic, and evaluated on at least one development case.

  Draws come from the clade posterior when `policy["clade"]` is true and from
  the node posterior otherwise. With nothing evaluable the first plan seed is
  the parent.
  """
  @spec select_parent(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t(),
          rng :: rng()
        ) :: {parent(), rng()}
  def select_parent(%Plan{} = plan, candidates, evaluations, policy, rng)
      when is_list(candidates) and is_list(evaluations) and is_map(policy) do
    plan |> archive(candidates, evaluations, policy) |> choose_parent(rng)
  end

  @doc """
  Decides the next step for the archive: expand from a parent, evaluate one
  pending candidate on a chosen set of cases, or stop.

  With `N` development evaluations and `V` admissible candidates (interface
  passed and not vetoed, evaluated or not), the archive is expanded when
  `N^widening_alpha >= V` and evaluated otherwise, subject to
  the corner rules in the module documentation. The evaluated candidate is
  Thompson-sampled from the pending ones on the node posterior; its cases fill
  the next fidelity tier with `always_case_ids` first and then a weighted draw
  without replacement over the remaining cases, weighted by
  `(1 + failed_case_weight * failed_anywhere) * (1 + discrimination)`.
  """
  @spec next_action(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t(),
          rng :: rng()
        ) :: {action(), rng()}
  def next_action(%Plan{} = plan, candidates, evaluations, policy, rng)
      when is_list(candidates) and is_list(evaluations) and is_map(policy) do
    archive = archive(plan, candidates, evaluations, policy)
    budget_reached? = length(candidates) >= plan.budget["maximum_candidates"]
    step(archive, budget_reached?, rng)
  end

  # The corner rules, in order: nothing pending and no budget left stops;
  # nothing pending expands; an exhausted budget or an empty evaluable set
  # evaluates what is pending; otherwise the widening rule decides.
  defp step(%{pending: []}, true, rng), do: {:done, rng}
  defp step(%{pending: []} = archive, false, rng), do: expand(archive, rng)
  defp step(archive, true, rng), do: evaluate(archive, rng)
  defp step(%{evaluable: []} = archive, false, rng), do: evaluate(archive, rng)

  defp step(archive, false, rng) do
    if widen?(archive), do: expand(archive, rng), else: evaluate(archive, rng)
  end

  @doc "JSON-shaped snapshot of the selection inputs, for state events and reports."
  @spec summary(
          plan :: Plan.t(),
          candidates :: [Candidate.t()],
          evaluations :: [Evaluation.t()],
          policy :: Policy.t()
        ) :: map()
  def summary(%Plan{} = plan, candidates, evaluations, policy)
      when is_list(candidates) and is_list(evaluations) and is_map(policy) do
    archive = archive(plan, candidates, evaluations, policy)

    %{
      "posteriors" => archive.posteriors,
      "discrimination" => case_discrimination(archive),
      "development_evaluations" => length(archive.development),
      "evaluable_candidates" => length(archive.evaluable),
      "pending_candidates" => length(archive.pending)
    }
  end

  # The archive is the one derived view every public function reads: sorted
  # candidates, archive-scoped development evaluations, and the eligibility
  # partitions. Building it once keeps the eligibility rules in one place.
  defp archive(plan, candidates, evaluations, policy) do
    candidates = Enum.sort_by(candidates, & &1.id)
    ids = MapSet.new(candidates, & &1.id)

    development =
      Enum.filter(
        evaluations,
        &(Policy.development?(&1) and MapSet.member?(ids, &1.candidate_id))
      )

    grouped = Enum.group_by(development, & &1.candidate_id)
    counts = Map.new(candidates, &{&1.id, outcome_counts(Map.get(grouped, &1.id, []), policy)})
    evaluated = Map.new(candidates, &{&1.id, case_ids(Map.get(grouped, &1.id, []))})
    admissible = Enum.filter(candidates, &admissible?/1)

    %{
      plan: plan,
      policy: policy,
      development: development,
      posteriors: posteriors_from(candidates, counts, prior(policy)),
      evaluated: evaluated,
      admissible: admissible,
      evaluable: Enum.filter(admissible, &Map.has_key?(grouped, &1.id)),
      pending: Enum.filter(admissible, &(plan.development_case_ids -- evaluated[&1.id] != []))
    }
  end

  defp admissible?(%Candidate{interface_validation: %{"status" => "passed"}} = candidate),
    do: not vetoed?(candidate)

  defp admissible?(%Candidate{}), do: false

  defp vetoed?(%Candidate{extensions: %{"critic" => %{"verdict" => "veto"}}}), do: true
  defp vetoed?(%Candidate{}), do: false

  # Every attempt is one Bernoulli trial of the candidate on a case, so a repeated
  # case contributes each of its runs to the posterior: two draws of the same
  # behaviour are more evidence about it, not a heavier case. The frontier scores
  # per case instead, because it compares candidates across the split rather than
  # estimating one success rate.
  defp outcome_counts(evaluations, policy) do
    successes = Enum.count(evaluations, &Policy.success?(&1, policy))
    {successes, length(evaluations) - successes}
  end

  defp case_ids(evaluations),
    do: evaluations |> Enum.map(& &1.case_id) |> Enum.uniq() |> Enum.sort()

  defp posteriors_from(candidates, counts, {prior_alpha, prior_beta}) do
    children = children_index(candidates)

    Map.new(candidates, fn candidate ->
      {successes, failures} = counts[candidate.id]
      {clade_successes, clade_failures} = clade_counts(candidate.id, children, counts)

      values = [
        successes,
        failures,
        prior_alpha + successes,
        prior_beta + failures,
        mean(prior_alpha + successes, prior_beta + failures),
        clade_successes,
        clade_failures,
        prior_alpha + clade_successes,
        prior_beta + clade_failures,
        mean(prior_alpha + clade_successes, prior_beta + clade_failures)
      ]

      {candidate.id, @posterior_keys |> Enum.zip(values) |> Map.new()}
    end)
  end

  defp mean(alpha, beta), do: alpha / (alpha + beta)

  defp children_index(candidates) do
    Enum.reduce(candidates, %{}, fn candidate, index ->
      Enum.reduce(candidate.parents, index, fn parent, index ->
        Map.update(index, parent["id"], [candidate.id], &[candidate.id | &1])
      end)
    end)
  end

  defp clade_counts(id, children, counts) do
    id
    |> clade_ids(children)
    |> Enum.reduce({0, 0}, fn member, {successes, failures} ->
      {member_successes, member_failures} = Map.get(counts, member, {0, 0})
      {successes + member_successes, failures + member_failures}
    end)
  end

  # Breadth-first over the children index with a visited set: lineage is
  # verified acyclic elsewhere, but selection must not hang on bad input.
  # The set is a plain map because a `MapSet` threaded through this
  # recursion loses its opaqueness under Dialyzer.
  defp clade_ids(id, children), do: [id] |> descend(children, %{}) |> Map.keys()

  defp descend([], _children, seen), do: seen

  defp descend([id | rest], children, seen) do
    if Map.has_key?(seen, id),
      do: descend(rest, children, seen),
      else: descend(Map.get(children, id, []) ++ rest, children, Map.put(seen, id, true))
  end

  # An improper or malformed prior would put zero into a Gamma shape and
  # divide by zero in the mean, so anything but two positive numbers falls
  # back to the flat Beta(1, 1).
  defp prior(%{"prior" => [alpha, beta]})
       when is_number(alpha) and is_number(beta) and alpha > 0 and beta > 0,
       do: {alpha, beta}

  defp prior(_policy), do: {1, 1}

  defp always_case_ids(%{"always_case_ids" => ids}) when is_list(ids), do: Enum.uniq(ids)
  defp always_case_ids(_policy), do: []

  defp choose_parent(%{evaluable: []} = archive, rng), do: {{:seed, hd(archive.plan.seeds)}, rng}

  defp choose_parent(archive, rng) do
    {id, rng} = thompson(archive.evaluable, archive.posteriors, parent_shape(archive.policy), rng)
    {{:candidate, id}, rng}
  end

  defp parent_shape(%{"clade" => true}), do: {"clade_alpha", "clade_beta"}
  defp parent_shape(_policy), do: {"alpha", "beta"}

  defp thompson(candidates, posteriors, {alpha_key, beta_key}, rng) do
    {draws, rng} =
      Enum.map_reduce(candidates, rng, fn candidate, rng ->
        posterior = posteriors[candidate.id]
        {draw, rng} = sample_beta(posterior[alpha_key], posterior[beta_key], rng)
        {{draw, candidate.id}, rng}
      end)

    {_draw, id} = Enum.max_by(draws, &elem(&1, 0))
    {id, rng}
  end

  # V is the admissible archive, evaluated or not. Counting only evaluated
  # candidates let the first live campaign expand five times in a row: each
  # new, unevaluated sibling left V unchanged while N stayed put, so the rule
  # kept saying "expand" until the candidate budget forced an evaluation.
  defp widen?(archive) do
    :math.pow(length(archive.development), archive.policy["widening_alpha"]) >=
      length(archive.admissible)
  end

  defp expand(archive, rng) do
    {parent, rng} = choose_parent(archive, rng)
    {{:expand, parent}, rng}
  end

  defp evaluate(archive, rng) do
    {id, rng} = thompson(archive.pending, archive.posteriors, {"alpha", "beta"}, rng)
    {case_ids, rng} = next_cases(archive, id, rng)
    {{:evaluate, id, case_ids}, rng}
  end

  defp next_cases(archive, id, rng) do
    development_case_ids = archive.plan.development_case_ids
    evaluated = archive.evaluated[id]
    remaining = development_case_ids -- evaluated
    always = Enum.filter(always_case_ids(archive.policy), &(&1 in remaining))
    sampled_from = remaining -- always

    target =
      tier_target(
        archive.policy["fidelity_tiers"],
        length(evaluated),
        length(development_case_ids)
      )

    slots = max(target - length(evaluated) - length(always), 0)

    {sampled, rng} =
      weighted_sample(sampled_from, case_weights(archive, sampled_from), slots, rng)

    {Enum.sort(always ++ sampled), rng}
  end

  # Tiers are cumulative sizes already normalized by `Policy.read/2`; the
  # target is the first tier strictly above what has been evaluated, or every
  # development case once the tiers are exhausted.
  defp tier_target(tiers, evaluated, total) when is_list(tiers),
    do: Enum.find(tiers, total, &(is_integer(&1) and &1 > evaluated))

  defp tier_target(_tiers, _evaluated, total), do: total

  defp case_weights(archive, case_ids) do
    discrimination = case_discrimination(archive)
    failed = failed_cases(archive)
    weight = archive.policy["failed_case_weight"]

    Map.new(case_ids, fn case_id ->
      failed_anywhere = if MapSet.member?(failed, case_id), do: 1, else: 0
      {case_id, (1 + weight * failed_anywhere) * (1 + Map.get(discrimination, case_id, 0.0))}
    end)
  end

  defp failed_cases(archive) do
    archive.development
    |> Enum.reject(&Policy.success?(&1, archive.policy))
    |> MapSet.new(& &1.case_id)
  end

  defp case_discrimination(archive) do
    by_case = Enum.group_by(archive.development, & &1.case_id)

    Map.new(archive.plan.development_case_ids, fn case_id ->
      {case_id, variance(Map.get(by_case, case_id, []), archive.policy)}
    end)
  end

  defp variance(evaluations, policy) do
    evaluations
    |> Enum.group_by(& &1.candidate_id)
    |> Enum.map(fn {_id, group} -> success_rate(group, policy) end)
    |> population_variance()
  end

  defp success_rate(evaluations, policy),
    do: Enum.count(evaluations, &Policy.success?(&1, policy)) / length(evaluations)

  defp population_variance([_first, _second | _rest] = values) do
    count = length(values)
    mean = Enum.sum(values) / count
    Enum.sum_by(values, &((&1 - mean) * (&1 - mean))) / count
  end

  defp population_variance(_values), do: 0.0

  # Weighted sampling without replacement: each pick lands where a uniform
  # draw scaled to the remaining total falls in the cumulative weights. Items
  # arrive sorted, so the walk order (and therefore the result for one rng
  # state) does not depend on how the host ordered its evaluations.
  defp weighted_sample(items, _weights, slots, rng) when items == [] or slots == 0, do: {[], rng}

  defp weighted_sample(items, weights, slots, rng) do
    total = Enum.sum_by(items, &weights[&1])
    {uniform, rng} = :rand.uniform_real_s(rng)
    chosen = pick(items, weights, uniform * total)
    {rest, rng} = weighted_sample(List.delete(items, chosen), weights, slots - 1, rng)
    {[chosen | rest], rng}
  end

  defp pick([item], _weights, _target), do: item

  defp pick([item | rest], weights, target) do
    weight = weights[item]
    if target < weight, do: item, else: pick(rest, weights, target - weight)
  end

  defp ratio(x, y) when x + y > 0, do: x / (x + y)
  defp ratio(_x, _y), do: 0.5

  # Marsaglia and Tsang (2000). Shapes below one are boosted to shape + 1 and
  # scaled by U^(1/shape), which is exact.
  defp gamma(shape, rng) when shape < 1 do
    {boosted, rng} = gamma(shape + 1, rng)
    {uniform, rng} = :rand.uniform_real_s(rng)
    {boosted * :math.pow(uniform, 1 / shape), rng}
  end

  defp gamma(shape, rng) do
    d = shape - 1 / 3
    c = 1 / :math.sqrt(9 * d)
    gamma_squeeze(d, c, rng)
  end

  defp gamma_squeeze(d, c, rng) do
    {x, rng} = :rand.normal_s(rng)
    {uniform, rng} = :rand.uniform_real_s(rng)
    v = 1 + c * x
    cube = v * v * v

    if v > 0 and accept?(uniform, x, cube, d),
      do: {d * cube, rng},
      else: gamma_squeeze(d, c, rng)
  end

  defp accept?(uniform, x, cube, d) do
    uniform < 1 - 0.0331 * x * x * x * x or
      :math.log(uniform) < 0.5 * x * x + d * (1 - cube + :math.log(cube))
  end
end
