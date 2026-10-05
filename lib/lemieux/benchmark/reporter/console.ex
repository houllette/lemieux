defmodule Lemieux.Benchmark.Reporter.Console do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Human-readable terminal reporting for an evaluated benchmark artifact.
  """

  @doc "Formats a complete evaluation summary without ANSI control sequences."
  @spec format(report :: map()) :: String.t()
  def format(report) when is_map(report) do
    status = if get_in(report, ["gate", "passed"]), do: "PASS", else: "FAIL"

    runtimes =
      report
      |> get_in(["evaluation", "runtimes"])
      |> Kernel.||(%{})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("\n", fn {name, metrics} -> runtime(name, metrics, report) end)

    failures =
      report
      |> get_in(["gate", "failures"])
      |> List.wrap()
      |> Enum.map_join("\n", fn failure ->
        level = if failure["hard"], do: "HARD", else: "threshold"
        "  - #{level} #{failure["metric"]} (#{failure["runtime"] || "all runtimes"})"
      end)

    failure_section = if failures == "", do: "", else: "\nFailures:\n#{failures}\n"

    """
    LEMIEUX EVAL: #{status}

    Baseline: #{inspect(get_in(report, ["evaluation", "baseline"]))}
    #{runtimes}

    Cost: #{money(get_in(report, ["budget", "actual_cost_usd"]))} / #{money(get_in(report, ["budget", "cap_usd"]))}
    #{failure_section}
    """
    |> String.trim()
  end

  defp runtime(name, metrics, report) do
    delta = get_in(report, ["evaluation", "comparisons", name, "task_success_delta"])

    """
    #{name}
      task success: #{percent(get_in(metrics, ["task_success", "rate"]))} (#{points(delta)})
      tool selection: #{percent(get_in(metrics, ["tool_selection", "rate"]))}
      prompt adherence: #{percent(get_in(metrics, ["prompt_adherence", "rate"]))}
      safety failures: #{get_in(metrics, ["destructive_operation_safety", "failed"]) || 0}
      mean turns: #{number(get_in(metrics, ["efficiency", "mean_turns"]))}
      mean cost: #{money(get_in(metrics, ["efficiency", "mean_cost_usd"]))}
    """
    |> String.trim_trailing()
  end

  defp percent(value) when is_number(value), do: "#{Float.round(value * 100, 1)}%"
  defp percent(_value), do: "n/a"

  defp points(value) when is_number(value), do: "#{signed(Float.round(value * 100, 1))} points"
  defp points(_value), do: "no comparison"

  defp signed(value) when value > 0, do: "+#{value}"
  defp signed(value), do: to_string(value)

  defp money(value) when is_number(value),
    do: "$#{:erlang.float_to_binary(value / 1, decimals: 2)}"

  defp money(_value), do: "unknown"

  defp number(value) when is_number(value), do: to_string(Float.round(value / 1, 1))
  defp number(_value), do: "n/a"
end
