defmodule Lemieux.Learning.Extension.Workbench.View do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Plain terminal views of development comparisons.

  Normal completion and mechanical acceptance are separate facts. Missing
  counters stay unknown; scheduler reservations are never presented as measured
  spend. Stage counters are shown as supplied by the extension, not inferred
  from its answer. Terminal controls are removed from model and grader output.
  """

  alias Lemieux.Benchmark.Resources
  alias Lemieux.Learning.Extension.Workbench

  @doc "Displays selected cases, variants and the next run's declared budget."
  @spec project(state :: Lemieux.Learning.Extension.Workbench.t()) :: String.t()
  def project(state) do
    plan = Workbench.plan(state)

    clean("""
    Extension workbench — #{plan["execution"]}
    Cases: #{Enum.join(state.project["selected_cases"], ", ")}
    Variants: #{Enum.join(state.project["selected_variants"], ", ")}
    #{budget(plan)}
    Development cases; no qualification or automatic activation.
    """)
  end

  defp budget(%{"usage_mode" => "quota"} = plan),
    do:
      "#{plan["planned_attempts"]}/#{plan["max_attempts"]} attempts; #{plan["max_requests_per_attempt"]} direct requests per attempt. Quota-backed; provider quota remaining is unknown."

  defp budget(plan),
    do:
      "#{plan["planned_attempts"]} planned attempts; cap USD #{value(plan["cost_cap_usd"])}; reservation per attempt USD #{value(plan["max_cost_per_attempt_usd"])}"

  @doc "Renders completion, grading, all-attempt resources and paired outcomes."
  @spec summary(report :: map()) :: String.t()
  def summary(report) do
    execution = report["execution"] || %{}
    results = report["results"] || []
    runtimes = results |> Enum.group_by(& &1["runtime"]) |> Enum.sort()
    pairs = get_in(report, ["summary", "pairs"]) || []

    lines = [
      "Development cases; no qualification or automatic activation.",
      "#{execution["scheduled"]}/#{execution["planned"]} attempts scheduled" <> stopped(execution),
      Enum.map(runtimes, fn {name, runs} -> runtime(name, runs) end),
      Enum.map(pairs, &pair/1),
      "Attempts (use inspect with a run ID and attempt number):",
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, index} ->
        "#{index}. #{result["runtime"]} / #{result["task_id"]} / repetition #{result["attempt"]}: #{outcome(result)}"
      end)
    ]

    lines |> List.flatten() |> Enum.join("\n") |> clean()
  end

  @doc "Renders an individual attempt, including errors, grader output and resource stages."
  @spec attempt(report :: map(), number :: pos_integer()) :: String.t()
  def attempt(report, number) when is_integer(number) and number > 0 do
    case Enum.at(report["results"] || [], number - 1) do
      nil -> "No such attempt."
      result -> detail(result)
    end
  end

  def attempt(_report, _number), do: "No such attempt."

  @doc "Removes terminal control characters and limits displayed text; artifacts retain originals."
  @spec clean(text :: String.t()) :: String.t()
  def clean(text) do
    text
    |> String.replace(~r/\e\][^\a\e]*(?:\a|\e\\)/u, "")
    |> String.replace(~r/\e\[[0-?]*[ -\/]*[@-~]/u, "")
    |> String.replace(~r/[\x00-\x08\x0B-\x1F\x7F-\x9F]/u, "")
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) > 16_000,
      do:
        String.slice(text, 0, 16_000) <> "\n[Display truncated; full content is in report.json.]",
      else: text
  end

  defp runtime(name, runs) do
    completed = Enum.count(runs, &(get_in(&1, ["observation", "status"]) == "completed"))
    passed = Enum.count(runs, &(get_in(&1, ["grader", "passed"]) == true))
    failed = Enum.count(runs, &(get_in(&1, ["grader", "passed"]) == false))
    resources = Resources.summarize(runs)
    costs = Enum.map(runs, &get_in(&1, ["observation", "usage", "cost_usd"]))
    cost = if Enum.all?(costs, &is_number/1), do: Enum.sum(costs), else: nil
    requests = Enum.map(runs, &get_in(&1, ["observation", "tool_metrics", "requests"]))

    request_total =
      if Enum.all?(requests, &(is_integer(&1) and &1 >= 0)), do: Enum.sum(requests), else: nil

    """
    #{name}: #{completed}/#{length(runs)} completed; #{passed} passed; #{failed} failed; #{length(runs) - passed - failed} ungraded
      All attempts: #{value(resources["end_to_end_total_ms"])} ms; cost USD #{value(cost)}; full input tokens #{value(resources["total"]["full_input_tokens"])}; output tokens #{value(resources["total"]["output_tokens"])}
      Direct model requests: #{value(request_total)}
      Resource scope: as reported by the extension; missing counters are unknown.
    """
    |> String.trim_trailing()
  end

  defp pair(pair) do
    "#{pair["right"]} vs #{pair["left"]}: #{pair["right_wins"]} wins, #{pair["left_wins"]} regressions, #{pair["ties"]} ties (#{pair["matched_attempts"]} matched attempts)."
  end

  defp detail(result) do
    observation = result["observation"] || %{}
    grader = result["grader"] || %{}

    clean("""
    #{result["runtime"]} / #{result["task_id"]} / repetition #{result["attempt"]}: #{outcome(result)}
    Completion: #{observation["status"] || "unknown"}; finish reason: #{value(observation["finish_reason"])}
    Error: #{result["error"] || "none"}
    Answer:
    #{observation["answer"] || "(none)"}
    Grader exit: #{value(grader["exit_status"])}; timed out: #{value(grader["timed_out"])}
    Grader output:
    #{grader["output"] || "(none)"}
    Reported cost USD: #{value(get_in(observation, ["usage", "cost_usd"]))}
    Observed cost lower bound USD: #{value(get_in(observation, ["usage", "observed_cost_usd"]))}
    Reported model stages:
    #{stages(observation["resources"])}
    Stages reflect the extension's accounting; absent counters are unknown.
    Full observations and transcripts references remain in report.json.
    """)
  end

  defp stages(%{"stages" => stages}) when is_map(stages) and map_size(stages) > 0 do
    stages
    |> Enum.sort()
    |> Enum.map_join("\n", fn {name, counters} ->
      "#{name}: #{value(counters["requests"])} requests; #{value(counters["reported_requests"])} usage reports; full input tokens #{value(counters["full_input_tokens"])}; output tokens #{value(counters["output_tokens"])}; cost USD #{value(counters["cost_usd"])}"
    end)
  end

  defp stages(_resources), do: "unknown (extension supplied no stage breakdown)"

  defp outcome(%{"passed" => true}), do: "passed"
  defp outcome(%{"grader" => %{"passed" => false}}), do: "grader failed"
  defp outcome(_result), do: "not accepted; inspect error/completion"

  defp stopped(%{"aborted" => true, "reason" => reason}),
    do: "; stopped: #{reason}. Unmatched work is not a tie."

  defp stopped(_execution), do: ""
  defp value(nil), do: "unknown"
  defp value(value), do: to_string(value)
end
