defmodule Lemieux.Benchmark.Summary do
  @moduledoc false

  alias Lemieux.Benchmark.Resources

  @spec build(results :: [map()], runtime_names :: [String.t()]) :: map()
  def build(results, runtime_names) do
    by_runtime = Map.new(runtime_names, &{&1, runtime(results, &1)})

    %{
      "runtimes" => by_runtime,
      "pairs" => pairs(results, runtime_names)
    }
  end

  defp runtime(results, name) do
    runs = Enum.filter(results, &(&1["runtime"] == name))
    run_count = length(runs)
    passed = Enum.count(runs, &(&1["passed"] == true))

    %{
      "runs" => run_count,
      "passed" => passed,
      "resources" => Resources.summarize(runs),
      "completion_rate" => ratio(passed, run_count),
      "mean_wall_time_ms" => mean(runs, & &1["wall_time_ms"]),
      "mean_cost_usd" => mean(runs, &get_in(&1, ["observation", "usage", "cost_usd"])),
      "mean_input_tokens" => mean(runs, &get_in(&1, ["observation", "usage", "input_tokens"])),
      "mean_output_tokens" => mean(runs, &get_in(&1, ["observation", "usage", "output_tokens"])),
      "mean_tool_catalog_bytes" =>
        mean(runs, &get_in(&1, ["observation", "tool_metrics", "catalog_bytes"])),
      "mean_tool_catalog_tokens" =>
        mean(runs, &get_in(&1, ["observation", "tool_metrics", "catalog_tokens"])),
      "mean_tool_calls" => mean(runs, &get_in(&1, ["observation", "tool_metrics", "calls"])),
      "mean_tool_errors" => mean(runs, &get_in(&1, ["observation", "tool_metrics", "errors"]))
    }
  end

  defp pairs(results, runtime_names) do
    runtime_names
    |> Enum.with_index()
    |> Enum.flat_map(fn {left, index} ->
      runtime_names
      |> Enum.drop(index + 1)
      |> Enum.map(&pair(results, left, &1))
    end)
  end

  defp pair(results, left, right) do
    left_results = indexed(results, left)
    right_results = indexed(results, right)

    matched =
      left_results
      |> Map.keys()
      |> Enum.filter(&Map.has_key?(right_results, &1))
      |> Enum.map(&{Map.fetch!(left_results, &1), Map.fetch!(right_results, &1)})

    %{
      "left" => left,
      "right" => right,
      "matched_attempts" => length(matched),
      "right_wins" =>
        Enum.count(matched, &match?({%{"passed" => false}, %{"passed" => true}}, &1)),
      "left_wins" =>
        Enum.count(matched, &match?({%{"passed" => true}, %{"passed" => false}}, &1)),
      "ties" =>
        Enum.count(matched, fn {left_run, right_run} ->
          left_run["passed"] == right_run["passed"]
        end),
      "completion_rate_delta" => mean_difference(matched, &score/1),
      "mean_wall_time_ms_delta" => mean_difference(matched, & &1["wall_time_ms"]),
      "mean_cost_usd_delta" =>
        mean_difference(matched, &get_in(&1, ["observation", "usage", "cost_usd"])),
      "mean_input_tokens_delta" =>
        mean_difference(matched, &get_in(&1, ["observation", "usage", "input_tokens"])),
      "mean_tool_calls_delta" =>
        mean_difference(matched, &get_in(&1, ["observation", "tool_metrics", "calls"])),
      "mean_tool_errors_delta" =>
        mean_difference(matched, &get_in(&1, ["observation", "tool_metrics", "errors"]))
    }
  end

  defp indexed(results, runtime) do
    results
    |> Enum.filter(&(&1["runtime"] == runtime))
    |> Map.new(&{{&1["task_id"], &1["attempt"]}, &1})
  end

  defp score(%{"passed" => true}), do: 1
  defp score(_result), do: 0

  defp mean_difference(pairs, mapper) do
    differences =
      Enum.flat_map(pairs, fn {left, right} ->
        case {mapper.(left), mapper.(right)} do
          {left_value, right_value} when is_number(left_value) and is_number(right_value) ->
            [right_value - left_value]

          _unknown ->
            []
        end
      end)

    if differences == [], do: nil, else: Enum.sum(differences) / length(differences)
  end

  defp ratio(_part, 0), do: nil
  defp ratio(part, whole), do: part / whole

  defp mean(values, mapper) do
    numbers = values |> Enum.map(mapper) |> Enum.filter(&is_number/1)
    if numbers == [], do: nil, else: Enum.sum(numbers) / length(numbers)
  end
end
