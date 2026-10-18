defmodule Lemieux.Learning.Qualification do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  A preregistered, host-executed five-arm learning protocol.

  Plans freeze model/effort, runtime, task order and clusters, initial experience,
  equal outer allowances, repetition count and stopping rules before dispatch.
  The host supplies execution, isolation, graders and synchronous checkpoints.
  No provider, scheduler or process is created here. Updating experience is
  causal and isolated by arm and repetition; frozen arms never inherit it.

  Safety, accounting and complete execution are mechanical gates. Quality uses
  paired cluster means and a conservative fixed-sample Hoeffding interval.
  Tokens, cost and latency are reported as secondary evidence; greater usage
  does not disqualify an accurate result. A small or ceiling-limited experiment
  is inconclusive, even when every task passes. Re-running exposed cases cannot
  manufacture independent confirmation or a cross-model claim.
  """
  alias Lemieux.Contract

  @arms ~w(disabled retrieval retry frozen updating)
  @required ~w(id model effort runtime tasks seed_case_ids initial_library_sha256 repetitions allowance alpha claim)

  @spec arms() :: [String.t()]
  def arms, do: @arms

  @spec plan(attrs :: map()) :: {:ok, map()} | {:error, term()}
  def plan(attrs) when is_map(attrs) do
    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@required),
         true <- text?(attrs["id"]) and text?(attrs["model"]) and text?(attrs["effort"]),
         true <- is_map(attrs["runtime"]) and digest?(attrs["runtime"]["sha256"]),
         true <- attrs["repetitions"] in 2..10,
         true <- is_number(attrs["alpha"]) and attrs["alpha"] > 0 and attrs["alpha"] < 1,
         true <- attrs["claim"] in ~w(development_qualification independent_confirmation),
         true <- digest?(attrs["initial_library_sha256"]),
         true <- ids?(attrs["seed_case_ids"]),
         true <- tasks?(attrs["tasks"]),
         true <- Enum.all?(attrs["tasks"], &(&1["id"] not in attrs["seed_case_ids"])),
         true <- allowance?(attrs["allowance"]) do
      {:ok,
       seal(
         Map.merge(attrs, %{
           "schema_version" => 1,
           "arms" => @arms,
           "stopping" => "fixed_complete_sample",
           "resource_gate" => "outer_allowance_only"
         })
       )}
    else
      _invalid -> {:error, :invalid_qualification_plan}
    end
  rescue
    _invalid -> {:error, :invalid_qualification_plan}
  end

  def plan(_invalid), do: {:error, :invalid_qualification_plan}

  @spec verify(plan :: map()) :: :ok | {:error, term()}
  def verify(plan) do
    with :ok <- Contract.verify_digest(plan, "sha256"),
         {:ok, ^plan} <- plan(Map.take(plan, @required)) do
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

  @spec report(plan :: map(), rows :: [map()]) :: {:ok, map()} | {:error, term()}
  def report(plan, rows) do
    if verify(plan) == :ok and complete?(plan, rows) do
      summaries =
        Map.new(@arms, fn arm ->
          chosen = Enum.filter(rows, &(&1["arm"] == arm))

          {arm,
           %{
             "passed" => Enum.count(chosen, & &1["passed"]),
             "attempts" => length(chosen),
             "requests" => sum(chosen, "requests"),
             "tokens" => sum(chosen, "tokens"),
             "cost_usd" => sum(chosen, "cost_usd"),
             "latency_ms" => percentiles(chosen),
             "safety_failures" => Enum.flat_map(chosen, & &1["safety_failures"])
           }}
        end)

      comparisons = Map.new(@arms -- ["disabled"], &{&1, comparison(plan, rows, &1)})
      safe = Enum.all?(rows, &(&1["safety_failures"] == []))
      accounted = Enum.all?(rows, &is_integer(&1["tokens"]))

      {:ok,
       seal(%{
         "schema_version" => 1,
         "plan_sha256" => plan["sha256"],
         "claim" => plan["claim"],
         "model" => plan["model"],
         "effort" => plan["effort"],
         "mechanics" => mechanics(safe, accounted),
         "rows" => rows,
         "arms" => summaries,
         "comparisons" => comparisons,
         "benefit" => benefit(safe, accounted, comparisons),
         "resource_policy" =>
           "Quality and safety first; usage and latency are secondary, not automatic disqualifiers."
       })}
    else
      {:error, :incomplete_qualification_report}
    end
  rescue
    _invalid -> {:error, :incomplete_qualification_report}
  end

  defp mechanics(false, _accounted), do: "safety_failure"
  defp mechanics(true, false), do: "incomplete_accounting"
  defp mechanics(true, true), do: "passed"

  defp benefit(true, true, comparisons) do
    if Enum.any?(comparisons, fn {_arm, c} -> c["regressions"] == 0 and hd(c["interval"]) > 0 end),
       do: "supported_in_this_scope",
       else: "inconclusive"
  end

  defp benefit(_safe, _accounted, _comparisons), do: "inconclusive"

  defp schedule(plan),
    do:
      for(
        repetition <- 1..plan["repetitions"],
        task <- plan["tasks"],
        arm <- rotate(@arms, repetition - 1),
        do: {repetition, task, arm}
      )

  defp context(plan, {repetition, task, arm}, rows) do
    previous = Enum.filter(rows, &(&1["arm"] == arm and &1["repetition"] == repetition))
    available = if arm == "updating", do: Enum.map(previous, & &1["task_id"]), else: []

    %{
      "plan_sha256" => plan["sha256"],
      "arm" => arm,
      "task" => task,
      "repetition" => repetition,
      "allowance" => plan["allowance"],
      "initial_library_sha256" => plan["initial_library_sha256"],
      "available_case_ids" => plan["seed_case_ids"] ++ available,
      "prior_lesson_ids" =>
        if(arm == "updating", do: Enum.flat_map(previous, & &1["created_lesson_ids"]), else: [])
    }
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

  defp comparison(plan, rows, arm) do
    index = Map.new(rows, &{{&1["repetition"], &1["task_id"], &1["arm"]}, &1})

    pairs =
      for r <- 1..plan["repetitions"], task <- plan["tasks"] do
        control = index[{r, task["id"], "disabled"}]["passed"]
        variant = index[{r, task["id"], arm}]["passed"]
        {task["cluster"], if(variant, do: 1, else: 0) - if(control, do: 1, else: 0)}
      end

    clustered =
      pairs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.values()
      |> Enum.map(&(Enum.sum(&1) / length(&1)))

    effect = Enum.sum(clustered) / length(clustered)
    alpha = plan["alpha"] / (length(@arms) - 1)
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

  defp tasks?(tasks) when is_list(tasks) and length(tasks) in 2..100 do
    ids?(Enum.map(tasks, & &1["id"])) and
      Enum.all?(tasks, fn task ->
        Enum.sort(Map.keys(task)) == ~w(cluster id source_sha256) and text?(task["cluster"]) and
          digest?(task["source_sha256"])
      end)
  end

  defp tasks?(_invalid), do: false

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
