defmodule Lemieux.Learning.Qualification do
  @moduledoc """
  **Experimental.** Not part of the stable public API.

  A preregistered, host-executed learning protocol.

  Plans freeze model/effort, runtime, task order and clusters, initial experience,
  equal outer allowances, repetition count and stopping rules before dispatch.
  The host supplies execution, isolation, graders and synchronous checkpoints.
  No provider, scheduler or process is created here. Updating experience is
  causal and isolated by arm and repetition; frozen arms never inherit it.

  Safety, accounting and complete execution are mechanical gates. Version 2
  retains its paired-cluster Hoeffding rule so historical plans cannot be
  reinterpreted after seeing their outcomes. Version 3 explicitly registers
  independent streams, a confirmation-only binary endpoint, two primary exact
  paired comparisons, practical effect/regression/resource thresholds and power.
  A stream owns its causal learning history; related tasks and repetitions do
  not become independent observations. Underpowered independent confirmation
  plans refuse before execution. See `Lemieux.Learning.Qualification.Paired` for
  the estimand, test assumptions and power model.
  Version 4 adds a matched improver with its prior experience withheld. It
  retains task execution, proposal, probe and reflection work, but can disclose
  no earlier lesson. Its quality/efficiency claims belong to the explicitly
  registered `Qualification.Endpoints` supplement; the legacy combined benefit
  field cannot claim a research effect without that additional comparison.
  Tokens, cost and latency are reported as secondary evidence; greater usage
  does not disqualify an accurate result. A small or ceiling-limited experiment
  is inconclusive, even when every task passes. Re-running exposed cases cannot
  manufacture independent confirmation or a cross-model claim.
  """
  alias Lemieux.Contract
  alias Lemieux.Learning.Qualification.Paired

  @arms ~w(disabled retrieval retry frozen updating)
  @research_arms @arms ++ ["no_experience"]
  @required ~w(id model effort runtime tasks seed_case_ids initial_library_sha256 repetitions allowance alpha claim)

  @spec arms() :: [String.t()]
  def arms, do: @arms

  @spec plan(attrs :: map()) :: {:ok, map()} | {:error, term()}
  def plan(attrs) when is_map(attrs) do
    required = plan_fields(attrs)

    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(required),
         true <- text?(attrs["id"]) and text?(attrs["model"]) and text?(attrs["effort"]),
         true <- is_map(attrs["runtime"]) and digest?(attrs["runtime"]["sha256"]),
         true <- attrs["repetitions"] in 2..10,
         true <- is_number(attrs["alpha"]) and attrs["alpha"] > 0 and attrs["alpha"] < 1,
         true <- attrs["claim"] in ~w(development_qualification independent_confirmation),
         true <- digest?(attrs["initial_library_sha256"]),
         true <- ids?(attrs["seed_case_ids"]),
         true <- tasks?(attrs["tasks"], attrs["analysis"]),
         true <- registered_analysis?(attrs),
         true <- registered_ablation?(attrs),
         true <- Enum.all?(attrs["tasks"], &(&1["id"] not in attrs["seed_case_ids"])),
         true <- allowance?(attrs["allowance"]),
         true <- powered_confirmation?(attrs) do
      {:ok,
       seal(
         Map.merge(attrs, %{
           "schema_version" => version(attrs),
           "arms" => if(attrs["ablation"], do: @research_arms, else: @arms),
           "stopping" => "fixed_complete_sample",
           "resource_gate" => "outer_allowance_only",
           "comparison_family" =>
             if(attrs["analysis"],
               do: "updating_vs_disabled_and_retry_primary_other_contrasts_diagnostic",
               else: "four_disabled_two_retry_updating_vs_frozen"
             ),
           "decision_rule" =>
             if(attrs["analysis"],
               do:
                 "paired_stream_success_with_preregistered_effect_regression_and_resource_limits",
               else: "refinement_beats_disabled_and_retry_without_regressions"
             )
         })
       )}
    else
      _invalid -> {:error, :invalid_qualification_plan}
    end
  rescue
    _invalid -> {:error, :invalid_qualification_plan}
  end

  def plan(_invalid), do: {:error, :invalid_qualification_plan}

  defp version(%{"ablation" => _}), do: 4
  defp version(%{"analysis" => _}), do: 3
  defp version(_legacy), do: 2
  defp plan_fields(%{"ablation" => _, "analysis" => _}), do: ["ablation", "analysis" | @required]
  defp plan_fields(%{"analysis" => _}), do: ["analysis" | @required]
  defp plan_fields(_legacy), do: @required

  @spec verify(plan :: map()) :: :ok | {:error, term()}
  def verify(plan) do
    with :ok <- Contract.verify_digest(plan, "sha256"),
         {:ok, ^plan} <- plan(Map.take(plan, ["ablation", "analysis" | @required])) do
      :ok
    else
      _invalid -> {:error, :invalid_qualification_plan}
    end
  rescue
    _invalid -> {:error, :invalid_qualification_plan}
  end

  @doc "Executes a complete fixed sample; the observer must checkpoint intent before host effects."
  @spec run(
          plan :: map(),
          execute :: (map() -> {:ok, map()} | {:error, term()}),
          opts :: keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def run(plan, execute, opts \\ []) do
    observer = Keyword.get(opts, :observer, fn _, _ -> :ok end)

    with :ok <- verify(plan),
         {:ok, rows} <- episodes(plan, execute, observer),
         {:ok, report} <- report(plan, rows),
         :ok <- observer.("report", report) do
      {:ok, report}
    end
  end

  defp episodes(plan, execute, observer) do
    Enum.reduce_while(schedule(plan), {:ok, []}, fn slot, {:ok, rows} ->
      context = context(plan, slot, rows)

      with :ok <- observer.("intent", context),
           {:ok, row} <- execute.(context),
           :ok <- row(row, context),
           :ok <- observer.("completed", row) do
        {:cont, {:ok, rows ++ [row]}}
      else
        error -> {:halt, {:error, {:qualification_incomplete, context, error}}}
      end
    end)
  end

  @doc """
  Verifies a complete fixed sample and derives its qualified conclusions.

  A host retaining the ordinary result after incomplete learning sets the row's
  `qualification_complete` to `false`. That result still contributes its task
  outcome and observed usage, but cannot qualify complete execution or benefit.
  Missing usage remains `nil`; retaining a baseline reconciles no checkpoint.
  """
  @spec report(plan :: map(), rows :: [map()]) :: {:ok, map()} | {:error, term()}
  def report(plan, rows) do
    if verify(plan) == :ok and complete?(plan, rows) do
      summaries =
        Map.new(plan["arms"], fn arm ->
          chosen = Enum.filter(rows, &(&1["arm"] == arm))

          {arm,
           %{
             "passed" => Enum.count(chosen, & &1["passed"]),
             "attempts" => length(chosen),
             "requests" => sum(chosen, "requests"),
             "tokens" => sum(chosen, "tokens"),
             "cost_usd" => sum(chosen, "cost_usd"),
             "latency_ms" => percentiles(chosen),
             "safety_failures" => Enum.flat_map(chosen, & &1["safety_failures"]),
             "candidate_count" => Enum.sum(Enum.map(chosen, &Map.get(&1, "candidate_count", 0))),
             "promotion_count" => Enum.sum(Enum.map(chosen, &Map.get(&1, "promotion_count", 0))),
             "rollback_count" => Enum.sum(Enum.map(chosen, &Map.get(&1, "rollback_count", 0)))
           }
           |> Map.merge(asset_metrics(plan, chosen))}
        end)

      comparisons = Map.new(plan["arms"] -- ["disabled"], &{&1, comparison(plan, rows, &1)})
      retry_comparisons = Map.new(~w(frozen updating), &{&1, comparison(plan, rows, &1, "retry")})
      safe = Enum.all?(rows, &(&1["safety_failures"] == []))
      accounted = Enum.all?(rows, &is_integer(&1["tokens"]))
      executed = Enum.all?(rows, &(Map.get(&1, "qualification_complete", true) == true))

      {:ok,
       seal(%{
         "schema_version" => 1,
         "plan_sha256" => plan["sha256"],
         "claim" => plan["claim"],
         "model" => plan["model"],
         "effort" => plan["effort"],
         "mechanics" => mechanics(safe, accounted, executed),
         "execution_complete" => executed,
         "rows" => rows,
         "arms" => summaries,
         "comparisons" => comparisons,
         "comparisons_to_retry" => retry_comparisons,
         "updating_vs_frozen" => comparison(plan, rows, "updating", "frozen"),
         "unknown_token_accounting" => Enum.count(rows, &is_nil(&1["tokens"])),
         "benefit" =>
           benefit_for(
             plan,
             safe and executed,
             accounted,
             comparisons,
             retry_comparisons,
             summaries
           ),
         "analysis" => analysis_report(plan),
         "resource_policy" => resource_policy(plan)
       })}
    else
      {:error, :incomplete_qualification_report}
    end
  rescue
    _invalid -> {:error, :incomplete_qualification_report}
  end

  defp asset_metrics(%{"schema_version" => 4}, rows),
    do:
      Map.new(~w(asset_candidate_count asset_application_count asset_restoration_count), fn key ->
        {key, Enum.sum(Enum.map(rows, &Map.get(&1, key, 0)))}
      end)

  defp asset_metrics(_legacy, _rows), do: %{}

  defp mechanics(false, _accounted, _executed), do: "safety_failure"
  defp mechanics(true, _accounted, false), do: "incomplete_execution"
  defp mechanics(true, false, true), do: "incomplete_accounting"
  defp mechanics(true, true, true), do: "passed"

  defp resource_policy(%{"schema_version" => 4}),
    do:
      "Version 4 defers benefit to registered quality and efficiency endpoints, including the matched experience-withheld improver and complete acquisition/search/reflection accounting."

  defp resource_policy(%{"analysis" => _analysis}),
    do:
      "Version 3 benefit requires the registered request and p95-latency ratios, including seed requests, as well as quality, safety, complete execution and accounting, supported promotion and rollback."

  defp resource_policy(_legacy),
    do: "Quality and safety first; usage and latency are secondary, not automatic disqualifiers."

  defp benefit(true, true, comparisons, retry_comparisons) do
    if Enum.any?(~w(frozen updating), fn arm ->
         supported?(comparisons[arm]) and supported?(retry_comparisons[arm])
       end),
       do: "supported_in_this_scope",
       else: "inconclusive"
  end

  defp benefit(_safe, _accounted, _comparisons, _retry_comparisons), do: "inconclusive"

  defp supported?(comparison),
    do: comparison["regressions"] == 0 and hd(comparison["interval"]) > 0

  defp benefit_for(%{"schema_version" => 4}, _safe, _accounted, _comparisons, _retry, _summaries),
    do: "not_assessed_use_registered_research_endpoints"

  defp benefit_for(%{"analysis" => analysis} = plan, true, true, comparisons, retry, summaries) do
    supported =
      Enum.all?([comparisons["updating"], retry["updating"]], fn comparison ->
        comparison["effect"] >= analysis["minimum_effect"] and
          comparison["regression_rate"] <= analysis["maximum_regression_rate"] and
          comparison["p_value"] <= comparison["alpha_per_comparison"]
      end)

    resources =
      Enum.all?(~w(disabled retry), fn arm ->
        summaries["updating"]["requests"] + seed_requests(plan) <=
          max(1, summaries[arm]["requests"]) * analysis["maximum_request_ratio"] and
          summaries["updating"]["latency_ms"]["p95"] <=
            max(1, summaries[arm]["latency_ms"]["p95"]) * analysis["maximum_latency_ratio"]
      end)

    mechanism =
      summaries["updating"]["candidate_count"] > 0 and
        summaries["updating"]["promotion_count"] > 0 and
        summaries["updating"]["promotion_count"] == summaries["updating"]["rollback_count"]

    if supported and resources and mechanism, do: "supported_in_this_scope", else: "inconclusive"
  end

  defp benefit_for(%{"analysis" => _}, _safe, _accounted, _comparisons, _retry, _summaries),
    do: "inconclusive"

  defp benefit_for(_plan, safe, accounted, comparisons, retry, _summaries),
    do: benefit(safe, accounted, comparisons, retry)

  defp analysis_report(%{"analysis" => analysis} = plan) do
    clusters = plan["tasks"] |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> length()
    power = Paired.power(clusters, analysis, plan["alpha"] / 2)

    result =
      Map.merge(analysis, %{
        "power" => power,
        "adequately_powered" => power["both_primary_lower_bound"] >= analysis["desired_power"],
        "primary_estimand" => "fraction_of_independent_streams_completing_all_confirmation_tasks",
        "secondary_estimand" => "all_episode_task_success_usage_and_latency",
        "interpretation" => "conditional_on_registered_tasks_models_and_independent_stream_design"
      })

    if plan["schema_version"] == 4,
      do:
        Map.put(
          result,
          "interpretation",
          "legacy_two_comparison_diagnostic_use_research_endpoints"
        ),
      else: result
  end

  defp analysis_report(_legacy), do: nil

  defp seed_requests(plan), do: get_in(plan, ["runtime", "seed_usage", "requests"]) || 0

  defp powered_confirmation?(
         %{"analysis" => analysis, "claim" => "independent_confirmation"} = attrs
       ) do
    n = attrs["tasks"] |> Enum.map(& &1["cluster"]) |> Enum.uniq() |> length()

    Paired.power(n, analysis, attrs["alpha"] / 2)["both_primary_lower_bound"] >=
      analysis["desired_power"]
  end

  defp powered_confirmation?(_development_or_legacy), do: true

  defp schedule(plan),
    do:
      for(
        repetition <- 1..plan["repetitions"],
        task <- plan["tasks"],
        arm <- rotate(plan["arms"], repetition - 1),
        do: {repetition, task, arm}
      )

  defp context(plan, {repetition, task, arm}, rows) do
    previous =
      Enum.filter(rows, fn row ->
        same = row["arm"] == arm and row["repetition"] == repetition

        same and
          (not Map.has_key?(plan, "analysis") or
             Enum.any?(
               plan["tasks"],
               &(&1["id"] == row["task_id"] and &1["cluster"] == task["cluster"])
             ))
      end)

    updates? = updates_experience?(plan, arm)
    available = if updates?, do: Enum.map(previous, & &1["task_id"]), else: []

    context = %{
      "plan_sha256" => plan["sha256"],
      "arm" => arm,
      "task" => task,
      "repetition" => repetition,
      "allowance" => plan["allowance"],
      "initial_library_sha256" => plan["initial_library_sha256"],
      "available_case_ids" =>
        if(arm == "no_experience", do: [], else: plan["seed_case_ids"] ++ available),
      "prior_lesson_ids" =>
        if(updates?, do: Enum.flat_map(previous, & &1["created_lesson_ids"]), else: [])
    }

    if plan["analysis"], do: Map.put(context, "stream_id", task["cluster"]), else: context
  end

  defp complete?(plan, rows) when is_list(rows) do
    slots = schedule(plan)

    length(rows) == length(slots) and
      Enum.reduce_while(Enum.zip(slots, rows), [], fn {slot, row}, previous ->
        if row(row, context(plan, slot, previous)) == :ok,
          do: {:cont, previous ++ [row]},
          else: {:halt, false}
      end) != false
  end

  defp complete?(_plan, _rows), do: false

  defp row(row, context) do
    cap = context["allowance"]

    valid =
      row_identity?(row, context) and row_sources?(row, context) and
        within?(row["requests"], cap["requests"]) and within?(row["latency_ms"], cap["time_ms"]) and
        tokens?(row["tokens"], cap["tokens"]) and cost?(row["cost_usd"], cap["cost_usd"])

    if valid, do: :ok, else: {:error, :invalid_qualification_episode}
  end

  defp row_identity?(row, context),
    do:
      row["arm"] == context["arm"] and row["task_id"] == context["task"]["id"] and
        row["repetition"] == context["repetition"] and is_boolean(row["passed"]) and
        is_boolean(Map.get(row, "qualification_complete", true)) and
        is_list(row["safety_failures"])

  defp row_sources?(row, context),
    do:
      ids?(row["exposed_case_ids"]) and
        Enum.all?(row["exposed_case_ids"], &(&1 in context["available_case_ids"])) and
        ids?(row["created_lesson_ids"]) and digest?(row["evidence_sha256"])

  defp within?(value, cap), do: count?(value) and value <= cap
  defp tokens?(nil, _cap), do: true
  defp tokens?(value, cap), do: within?(value, cap)
  defp cost?(value, nil), do: dollars?(value)
  defp cost?(value, cap), do: is_number(value) and value >= 0 and value <= cap

  defp comparison(plan, rows, arm, control_arm \\ "disabled") do
    if plan["analysis"],
      do: stream_comparison(plan, rows, arm, control_arm),
      else: legacy_comparison(plan, rows, arm, control_arm)
  end

  defp stream_comparison(plan, rows, arm, control_arm) do
    tasks = Enum.filter(plan["tasks"], &(&1["phase"] == "confirmation"))
    index = Map.new(rows, &{{&1["repetition"], &1["task_id"], &1["arm"]}, &1["passed"]})

    pairs =
      tasks
      |> Enum.group_by(& &1["cluster"])
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {_cluster, tasks} ->
        {stream_passed?(tasks, index, plan["repetitions"], control_arm),
         stream_passed?(tasks, index, plan["repetitions"], arm)}
      end)

    primary =
      plan["schema_version"] != 4 and arm == "updating" and control_arm in ~w(disabled retry)

    Paired.compare(pairs, plan["alpha"] / 2)
    |> Map.put("confirmatory", primary)
    |> Map.put("endpoint", "all_confirmation_tasks_and_repetitions_passed_per_stream")
  end

  defp updates_experience?(%{"schema_version" => version}, arm)
       when version in [3, 4] and arm in ~w(updating retrieval),
       do: true

  defp updates_experience?(_plan, "updating"), do: true
  defp updates_experience?(_plan, _arm), do: false

  defp legacy_comparison(plan, rows, arm, control_arm) do
    index = Map.new(rows, &{{&1["repetition"], &1["task_id"], &1["arm"]}, &1})

    pairs =
      for r <- 1..plan["repetitions"], task <- plan["tasks"] do
        control = index[{r, task["id"], control_arm}]["passed"]
        variant = index[{r, task["id"], arm}]["passed"]
        {task["cluster"], if(variant, do: 1, else: 0) - if(control, do: 1, else: 0)}
      end

    clustered =
      pairs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.values()
      |> Enum.map(&(Enum.sum(&1) / length(&1)))

    effect = Enum.sum(clustered) / length(clustered)
    # Four disabled comparisons, two retry controls and updating versus frozen
    # form one preregistered family. Extra reported contrasts cannot silently
    # expand the chance of declaring a benefit.
    alpha = plan["alpha"] / 7
    radius = :math.sqrt(2 * :math.log(2 / alpha) / length(clustered))

    %{
      "effect" => effect,
      "clusters" => length(clustered),
      "interval" => [max(-1.0, effect - radius), min(1.0, effect + radius)],
      "regressions" => Enum.count(pairs, &(elem(&1, 1) < 0)),
      "alpha_per_comparison" => alpha,
      "method" => "paired_cluster_hoeffding_fixed_n_bonferroni"
    }
  end

  defp stream_passed?(tasks, index, repetitions, arm) do
    Enum.all?(1..repetitions, fn r ->
      Enum.all?(tasks, &Map.fetch!(index, {r, &1["id"], arm}))
    end)
  end

  defp percentiles(rows) do
    values = rows |> Enum.map(& &1["latency_ms"]) |> Enum.sort()

    Map.new(
      [50, 95, 100],
      &{"p#{&1}", Enum.at(values, max(0, ceil(length(values) * &1 / 100) - 1))}
    )
  end

  defp sum(rows, key) do
    values = Enum.map(rows, & &1[key])
    if Enum.all?(values, &is_number/1), do: Enum.sum(values)
  end

  defp tasks?(tasks, nil) when is_list(tasks) and length(tasks) in 2..100 do
    ids?(Enum.map(tasks, & &1["id"])) and
      Enum.all?(tasks, fn task ->
        Enum.sort(Map.keys(task)) == ~w(cluster id source_sha256) and text?(task["cluster"]) and
          digest?(task["source_sha256"])
      end)
  end

  defp tasks?(tasks, analysis)
       when is_list(tasks) and is_map(analysis) and length(tasks) in 1..1000 do
    ids?(Enum.map(tasks, & &1["id"])) and
      Enum.all?(tasks, fn task ->
        Enum.sort(Map.keys(task)) == ~w(cluster id phase source_sha256) and text?(task["cluster"]) and
          digest?(task["source_sha256"]) and task["phase"] in ~w(learning confirmation)
      end) and
      tasks
      |> Enum.group_by(& &1["cluster"])
      |> Enum.all?(fn {_cluster, group} ->
        Enum.any?(group, &(&1["phase"] == "confirmation")) and
          Enum.map(group, & &1["phase"]) ==
            Enum.sort_by(Enum.map(group, & &1["phase"]), &(&1 == "confirmation"))
      end)
  end

  defp tasks?(_invalid, _analysis), do: false

  defp registered_analysis?(%{"analysis" => analysis}),
    do: is_map(analysis) and analysis?(analysis)

  defp registered_analysis?(_legacy), do: true

  defp registered_ablation?(%{"ablation" => ablation, "analysis" => analysis}),
    do: ablation == "withheld_proposer_experience/v1" and is_map(analysis)

  defp registered_ablation?(%{"ablation" => _invalid}), do: false
  defp registered_ablation?(_ordinary), do: true

  defp analysis?(analysis) when is_map(analysis) do
    Enum.sort(Map.keys(analysis)) ==
      ~w(desired_power loss_probability maximum_latency_ratio maximum_regression_rate maximum_request_ratio method minimum_effect win_probability) and
      analysis["method"] == "exact_paired_stream_success" and
      Enum.all?(
        ~w(desired_power minimum_effect win_probability loss_probability maximum_regression_rate),
        fn key ->
          is_number(analysis[key]) and analysis[key] > 0 and analysis[key] < 1
        end
      ) and analysis["win_probability"] + analysis["loss_probability"] < 1 and
      analysis["win_probability"] > analysis["loss_probability"] and
      Enum.all?(
        ~w(maximum_request_ratio maximum_latency_ratio),
        &(is_number(analysis[&1]) and analysis[&1] >= 1)
      )
  end

  defp allowance?(cap),
    do:
      is_map(cap) and Enum.sort(Map.keys(cap)) == ~w(cost_usd requests time_ms tokens) and
        Enum.all?(~w(requests time_ms tokens), &(is_integer(cap[&1]) and cap[&1] > 0)) and
        dollars?(cap["cost_usd"])

  defp ids?(ids), do: is_list(ids) and Enum.uniq(ids) == ids and Enum.all?(ids, &text?/1)
  defp count?(v), do: is_integer(v) and v >= 0
  defp dollars?(v), do: is_nil(v) or (is_number(v) and v >= 0)
  defp text?(v), do: is_binary(v) and byte_size(v) in 1..256 and String.trim(v) != ""
  defp digest?(v), do: is_binary(v) and Regex.match?(~r/\A[a-f0-9]{64}\z/, v)

  defp rotate(values, count),
    do:
      Enum.drop(values, rem(count, length(values))) ++
        Enum.take(values, rem(count, length(values)))

  defp seal(map), do: Map.put(map, "sha256", Contract.digest(map))
end
