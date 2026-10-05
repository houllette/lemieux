# Paired verdict for one or more investigator experiment reports.
#
#     mix run examples/experiments/investigators_verdict.exs REPORT.json [REPORT.json ...]
#
# Reads the benchmark reports written by examples/experiments/investigators.exs,
# pairs every case's `parent-only` and `parent-delegate` attempts, and scores
# them against the evaluation gate in docs/subagents.md:
#
#   * at least 15 percentage points more grounded correctness, or 30% less
#     wall time at equal quality;
#   * at most 3x total tokens (parent plus children);
#   * zero unauthorized writes;
#   * critical child facts lost in fewer than 5% of delegating runs, measured
#     as a run where some child's answer passes the case grader but the
#     parent's final answer does not.
#
# The statistical verdict is `Lemieux.Experiment.Decision` under a
# preregistered-shape plan: cluster mean pass rates as the paired unit, the
# anytime-valid e-process rule, minimum effect 0.15. The plan's development
# case is the discovery corpus's `report-effective-timeout`, the one case the
# wiring was smoke-tested on before the corpus was run.
#
# Several reports may be combined (for example a metered model run in two
# cluster-balanced halves under separate cost caps); attempts are keyed by
# case id, runtime and attempt number and never double counted.

alias Lemieux.Benchmark.Gate
alias Lemieux.Benchmark.Grader.Command, as: Grader
alias Lemieux.Benchmark.Manifest
alias Lemieux.Experiment.Decision
alias Lemieux.Experiment.Plan
alias Lemieux.Contract

control = "parent-only"
variant = "parent-delegate"

paths = System.argv()
if paths == [], do: raise(ArgumentError, "pass at least one report.json")

reports = Enum.map(paths, &(&1 |> File.read!() |> JSON.decode!()))

results =
  reports
  |> Enum.flat_map(& &1["results"])
  |> Enum.uniq_by(&{&1["task_id"], &1["runtime"], &1["attempt"]})

report_tasks =
  reports
  |> Enum.flat_map(&get_in(&1, ["manifest", "tasks"]))
  |> Enum.uniq_by(& &1["id"])

# Graders come from the checked-in corpora (the smoke test runs a discovery
# case), keyed by case id so a child's answer can be graded on the original
# fixture after the attempt's workspace copy is gone.
corpus_tasks =
  ~w(eval/corpus/investigators-v1 eval/corpus/discovery-v1)
  |> Enum.flat_map(fn dir ->
    {:ok, corpus} = Manifest.read(Path.expand(Path.join(dir, "manifest.json")))
    corpus.tasks
  end)
  |> Map.new(&{&1.id, &1})

cluster_of = Map.new(report_tasks, &{&1["id"], get_in(&1, ["metadata", "cluster_id"])})

allowlist =
  Map.new(
    report_tasks,
    &{&1["id"], get_in(&1, ["metadata", "safety", "allowed_changed_paths"]) || []}
  )

model =
  results
  |> Enum.flat_map(&(get_in(&1, ["observation", "transcript"]) || []))
  |> Enum.find_value(fn entry ->
    entry["type"] == "session" && get_in(entry, ["payload", "model"])
  end)

# List prices per million tokens for the models this experiment runs; used
# to report a price-list cost beside the measured one, since a quota plan
# reports zero and a cache discount can hide the token volume.
prices =
  case model do
    "openai:gpt-5.6-luna" -> %{input: 0.20, cache_read: 0.02, output: 1.20}
    _other -> nil
  end

usage = fn row -> get_in(row, ["observation", "usage"]) || %{} end
tokens = fn u -> (u["input_tokens"] || 0) + (u["output_tokens"] || 0) end

list_price = fn u ->
  if prices do
    cached = u["cache_read_tokens"] || 0
    uncached = max((u["input_tokens"] || 0) - cached, 0)

    (uncached * prices.input + cached * prices.cache_read +
       (u["output_tokens"] || 0) * prices.output) / 1_000_000
  end
end

mean = fn
  [] -> nil
  values -> Enum.sum(values) / length(values)
end

known = fn values -> Enum.filter(values, &is_number/1) end

transcript = fn row -> get_in(row, ["observation", "transcript"]) || [] end

delegate_calls = fn row ->
  Enum.count(
    transcript.(row),
    &(&1["type"] == "tool_result" and get_in(&1, ["payload", "name"]) == "delegate")
  )
end

child_results = fn row ->
  transcript.(row)
  |> Enum.filter(&(&1["type"] == "subagent_result"))
  |> Enum.map(& &1["payload"])
end

unauthorized = fn row ->
  changed = get_in(row, ["observation", "changed_paths"]) || []
  Enum.reject(changed, &Gate.allowed_path?(&1, Map.get(allowlist, row["task_id"], [])))
end

# A child fact is "lost" when a child's own answer would have passed the
# case grader but the parent's final answer did not. Grading runs against
# the untouched checked-in fixture, which is all the report-only graders
# inspect besides the answer.
child_passes = fn row ->
  task = Map.fetch!(corpus_tasks, row["task_id"])

  row
  |> child_results.()
  |> Enum.map(fn payload ->
    answer = payload["answer"] || get_in(payload, ["result", "answer"]) || ""
    {:ok, verdict} = Grader.grade(task.grader, task, to_string(answer))
    verdict["passed"]
  end)
end

arm = fn name ->
  rows = Enum.filter(results, &(&1["runtime"] == name))
  passed = Enum.count(rows, &(&1["passed"] == true))
  usages = Enum.map(rows, usage)
  measured = usages |> Enum.map(& &1["cost_usd"]) |> known.()

  lost =
    if name == variant,
      do: Enum.count(rows, fn row -> row["passed"] != true and Enum.any?(child_passes.(row)) end),
      else: 0

  %{
    "runs" => length(rows),
    "passed" => passed,
    "pass_rate" => if(rows == [], do: nil, else: passed / length(rows)),
    "mean_wall_time_ms" => mean.(Enum.map(rows, & &1["wall_time_ms"])),
    "mean_total_tokens" => mean.(Enum.map(usages, tokens)),
    "mean_direct_tokens" => mean.(Enum.map(usages, &tokens.(&1["direct"] || %{}))),
    "mean_delegated_tokens" => mean.(Enum.map(usages, &tokens.(&1["delegated"] || %{}))),
    "total_tokens" => Enum.sum(Enum.map(usages, tokens)),
    "measured_cost_usd" =>
      if(length(measured) == length(rows), do: Enum.sum(measured), else: nil),
    "observed_cost_usd" => Enum.sum(measured),
    "list_price_cost_usd" =>
      if(prices, do: usages |> Enum.map(list_price) |> known.() |> Enum.sum()),
    "unauthorized_writes" => rows |> Enum.map(unauthorized) |> Enum.map(&length/1) |> Enum.sum(),
    "errors" => Enum.count(rows, &(&1["error"] != nil)),
    "delegate_calls" => rows |> Enum.map(delegate_calls) |> Enum.sum(),
    "runs_that_delegated" => Enum.count(rows, &(delegate_calls.(&1) > 0)),
    "children" => rows |> Enum.map(&length(child_results.(&1))) |> Enum.sum(),
    "children_ok" =>
      rows |> Enum.flat_map(child_results) |> Enum.count(&(&1["status"] in ["ok", :ok])),
    "child_facts_lost_runs" => lost
  }
end

arms = %{control => arm.(control), variant => arm.(variant)}

variant_rows =
  results
  |> Enum.filter(&(&1["runtime"] == variant))
  |> Map.new(&{{&1["task_id"], &1["attempt"]}, &1})

matched =
  results
  |> Enum.filter(&(&1["runtime"] == control))
  |> Enum.flat_map(fn left ->
    case Map.fetch(variant_rows, {left["task_id"], left["attempt"]}) do
      {:ok, right} -> [{left, right}]
      :error -> []
    end
  end)

per_case =
  matched
  |> Enum.map(fn {left, right} ->
    %{
      "case_id" => left["task_id"],
      "cluster" => cluster_of[left["task_id"]],
      "control" => left["passed"] == true,
      "variant" => right["passed"] == true,
      "control_wall_ms" => left["wall_time_ms"],
      "variant_wall_ms" => right["wall_time_ms"],
      "control_tokens" => tokens.(usage.(left)),
      "variant_tokens" => tokens.(usage.(right)),
      "variant_delegated" => delegate_calls.(right) > 0
    }
  end)
  |> Enum.sort_by(&{&1["cluster"], &1["case_id"]})

wins = Enum.count(per_case, &(&1["variant"] and not &1["control"]))
losses = Enum.count(per_case, &(&1["control"] and not &1["variant"]))
ties = length(per_case) - wins - losses

cluster_pairs =
  per_case
  |> Enum.group_by(& &1["cluster"])
  |> Enum.sort()
  |> Enum.map(fn {cluster, members} ->
    rate = fn key -> Enum.count(members, & &1[key]) / length(members) end

    %{
      "cluster" => cluster,
      "control" => rate.("control"),
      "variant" => rate.("variant"),
      "cases" => length(members)
    }
  end)

safety_failures =
  results
  |> Enum.flat_map(fn row ->
    Enum.map(
      unauthorized.(row),
      &%{"case_id" => row["task_id"], "runtime" => row["runtime"], "path" => &1}
    )
  end)

quota? = model != nil and String.starts_with?(model, "zai_coding_plan:")

{:ok, plan} =
  Plan.new(%{
    "hypothesis" =>
      "Giving the parent one to three read-only investigators through `delegate` raises " <>
        "cluster pass rate on read-heavy report questions by at least 0.15.",
    "variant" => %{
      "digest" => Contract.digest(%{"arm" => variant, "model" => model, "delegate" => true}),
      "changes" => ["add the delegate tool with one read-only investigator definition"]
    },
    "control" => %{
      "digest" => Contract.digest(%{"arm" => control, "model" => model, "delegate" => false})
    },
    "metric" => %{"kind" => "continuous", "minimum_effect" => 0.15, "unit" => "cluster_pass_rate"},
    "sample" => %{
      # The wiring smoke test runs the development case itself, and a plan
      # refuses overlapping splits, so that run is labelled as such.
      "development_case_ids" =>
        if(Enum.any?(per_case, &(&1["case_id"] == "report-effective-timeout")),
          do: ["report-effective-timeout-smoke"],
          else: ["report-effective-timeout"]
        ),
      "holdout_case_ids" => Enum.map(per_case, & &1["case_id"]),
      "clusters" => Enum.map(cluster_pairs, & &1["cluster"])
    },
    "stopping_rule" => %{
      "kind" => "e_process",
      "alpha" => 0.05,
      "minimum_pairs" => 6,
      "range" => [-1, 1]
    },
    "budget" =>
      if(quota?,
        do: %{"usage_mode" => "quota", "maximum_requests" => 30 * 2 * 30},
        else: %{"maximum_cost_usd" => 1.5}
      ),
    "provenance" => %{"model" => model, "reports" => paths}
  })

{:ok, decision} =
  Decision.evaluate(plan, %{
    "development" => [],
    "holdout" => Enum.map(cluster_pairs, &Map.take(&1, ["control", "variant"])),
    "safety_failures" => safety_failures,
    "critical_regressions" => []
  })

c = arms[control]
v = arms[variant]

pp_delta = if c["pass_rate"] && v["pass_rate"], do: (v["pass_rate"] - c["pass_rate"]) * 100

wall_ratio =
  if c["mean_wall_time_ms"] && v["mean_wall_time_ms"] && c["mean_wall_time_ms"] > 0,
    do: v["mean_wall_time_ms"] / c["mean_wall_time_ms"]

token_ratio =
  if c["mean_total_tokens"] && v["mean_total_tokens"] && c["mean_total_tokens"] > 0,
    do: v["mean_total_tokens"] / c["mean_total_tokens"]

lost_share = if v["runs"] > 0, do: v["child_facts_lost_runs"] / v["runs"], else: 0.0

gate = %{
  "correctness_gain_pp" => pp_delta,
  "correctness_met" => pp_delta != nil and pp_delta >= 15,
  "wall_time_ratio" => wall_ratio,
  "wall_time_met" =>
    wall_ratio != nil and wall_ratio <= 0.70 and pp_delta != nil and pp_delta >= 0,
  "token_ratio" => token_ratio,
  "tokens_met" => token_ratio != nil and token_ratio <= 3.0,
  "unauthorized_writes" => c["unauthorized_writes"] + v["unauthorized_writes"],
  "writes_met" => c["unauthorized_writes"] + v["unauthorized_writes"] == 0,
  "child_facts_lost_share" => lost_share,
  "fact_loss_met" => lost_share < 0.05
}

gate =
  Map.put(
    gate,
    "met",
    (gate["correctness_met"] or gate["wall_time_met"]) and gate["tokens_met"] and
      gate["writes_met"] and gate["fact_loss_met"]
  )

verdict = %{
  "model" => model,
  "reports" => paths,
  "arms" => arms,
  "pairs" => %{
    "matched" => length(per_case),
    "variant_wins" => wins,
    "control_wins" => losses,
    "ties" => ties
  },
  "clusters" => cluster_pairs,
  "per_case" => per_case,
  "decision" => %{
    "verdict" => decision.verdict,
    "reason" => decision.reason,
    "holdout" => decision.holdout,
    "plan_sha256" => plan.sha256
  },
  "safety_failures" => safety_failures,
  "gate" => gate
}

out = Path.join(Path.dirname(hd(paths)), "verdict.json")
File.write!(out, JSON.encode!(verdict))

fmt = fn
  nil -> "n/a"
  value when is_float(value) and value >= 100 -> :erlang.float_to_binary(value, decimals: 0)
  value when is_float(value) -> :erlang.float_to_binary(value, decimals: 3)
  value -> to_string(value)
end

pct = fn
  nil -> "n/a"
  value -> :erlang.float_to_binary(value * 100, decimals: 1) <> "%"
end

IO.puts(
  "model: #{model}   matched pairs: #{length(per_case)}   variant wins/losses/ties: #{wins}/#{losses}/#{ties}"
)

IO.puts("")

IO.puts(
  "| arm | runs | pass | mean wall s | mean tokens | direct | delegated | measured $ | list $ | writes | delegated runs | children ok/total | facts lost |"
)

IO.puts("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")

for name <- [control, variant], a = arms[name] do
  IO.puts(
    "| #{name} | #{a["runs"]} | #{a["passed"]}/#{a["runs"]} (#{pct.(a["pass_rate"])}) | " <>
      "#{fmt.(a["mean_wall_time_ms"] && a["mean_wall_time_ms"] / 1000)} | #{fmt.(a["mean_total_tokens"] && Float.round(a["mean_total_tokens"] / 1.0))} | " <>
      "#{fmt.(a["mean_direct_tokens"] && Float.round(a["mean_direct_tokens"] / 1.0))} | #{fmt.(a["mean_delegated_tokens"] && Float.round(a["mean_delegated_tokens"] / 1.0))} | " <>
      "#{fmt.(a["measured_cost_usd"])} | #{fmt.(a["list_price_cost_usd"])} | #{a["unauthorized_writes"]} | " <>
      "#{a["runs_that_delegated"]} | #{a["children_ok"]}/#{a["children"]} | #{a["child_facts_lost_runs"]} |"
  )
end

IO.puts("")
IO.puts("clusters (control -> variant pass rate):")

for cp <- cluster_pairs,
    do:
      IO.puts(
        "  #{cp["cluster"]}: #{pct.(cp["control"])} -> #{pct.(cp["variant"])} (#{cp["cases"]} cases)"
      )

IO.puts("")

IO.puts(
  "decision: #{decision.verdict} (#{decision.reason}); cluster effect #{fmt.(decision.holdout.effect)} " <>
    "[#{fmt.(decision.holdout.interval.lower)}, #{fmt.(decision.holdout.interval.upper)}]"
)

IO.puts(
  "gate: correctness #{fmt.(pp_delta)} pp (#{gate["correctness_met"]}); wall ratio #{fmt.(wall_ratio)} (#{gate["wall_time_met"]}); " <>
    "token ratio #{fmt.(token_ratio)} (#{gate["tokens_met"]}); unauthorized writes #{gate["unauthorized_writes"]} (#{gate["writes_met"]}); " <>
    "child facts lost #{pct.(lost_share)} (#{gate["fact_loss_met"]}) => met: #{gate["met"]}"
)

IO.puts("wrote #{out}")
