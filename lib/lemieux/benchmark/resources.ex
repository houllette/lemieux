defmodule Lemieux.Benchmark.Resources do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Native, request-linked resource accounting for evaluation.

  Full input includes cache reads and writes exactly once, regardless of the
  provider's convention. Missing reports or counters stay unknown. Observed
  totals are lower bounds and cannot qualify an efficiency improvement.
  Stage elapsed time runs from the recorded request to its durable response;
  it includes provider admission and is not an estimate of server compute time.
  """

  alias Lemieux.Entry

  @counters ~w(full_input_tokens uncached_input_tokens cache_read_tokens cache_write_tokens output_tokens cost_usd wall_time_ms)

  @doc "Accounts for every direct request, grouped by its recorded purpose."
  @spec from_entries(entries :: [Entry.t()]) :: map()
  def from_entries(entries) do
    responses =
      entries
      |> Enum.filter(&(&1.type in [:assistant, :compaction, :guidance]))
      |> Enum.group_by(& &1.payload["request_id"])

    requests = Enum.filter(entries, &(&1.type == :request))
    rows = Enum.map(requests, &row(&1, Map.get(responses, &1.payload["id"], [])))

    rows
    |> aggregate()
    |> Map.put(
      "stages",
      Map.new(Enum.group_by(rows, & &1["kind"]), fn {kind, values} ->
        {kind, aggregate(values)}
      end)
    )
  end

  @doc "All-attempt resources per success, including failed attempts in the numerator."
  @spec summarize(runs :: [map()]) :: map()
  def summarize(runs) do
    successes = Enum.count(runs, &(&1["passed"] == true))
    resources = Enum.flat_map(runs, &execution_resources/1)

    wall_times =
      Enum.flat_map(runs, fn run ->
        Enum.map(run["retries"] || [], & &1["wall_time_ms"]) ++ [run["wall_time_ms"]]
      end)

    complete =
      resources != [] and Enum.all?(resources, &(is_map(&1) and &1["tokens_complete"] == true))

    totals =
      Map.new(@counters, fn counter ->
        {counter, strict_sum(Enum.map(resources, &value(&1, counter)))}
      end)

    observed =
      Map.new(@counters, fn counter ->
        {counter,
         resources
         |> Enum.map(&observed_value(&1, counter))
         |> Enum.filter(&is_number/1)
         |> Enum.sum()}
      end)

    %{
      "attempts" => length(runs),
      "executions" => length(resources),
      "successes" => successes,
      "tokens_complete" => complete,
      "end_to_end_total_ms" => strict_sum(wall_times),
      "total" => totals,
      "observed" => observed,
      "per_success" => Map.new(totals, fn {key, total} -> {key, divide(total, successes)} end),
      "end_to_end_ms_per_success" => divide(strict_sum(wall_times), successes)
    }
  end

  @doc "Resource records for the retained execution and every discarded infrastructure retry."
  @spec execution_resources(run :: map()) :: [map() | nil]
  def execution_resources(run) do
    Enum.map(run["retries"] || [], & &1["resources"]) ++
      [get_in(run, ["observation", "resources"])]
  end

  defp row(request, [response]) do
    usage = response.usage || %{}
    input = number(usage["input_tokens"])
    read = number(usage["cache_read_tokens"] || usage["cached_tokens"] || 0)
    write = number(usage["cache_write_tokens"] || usage["cache_creation_tokens"] || 0)
    full = full_input(input, read, write, usage["input_includes_cached"])

    %{
      "kind" => request.payload["kind"] || "unknown",
      "reported" => is_map(response.usage),
      "full_input_tokens" => full,
      "uncached_input_tokens" => subtract(full, read, write),
      "cache_read_tokens" => read,
      "cache_write_tokens" => write,
      "output_tokens" => number(usage["output_tokens"]),
      "cost_usd" => number(usage["cost_usd"]),
      "wall_time_ms" => max(DateTime.diff(response.at, request.at, :millisecond), 0)
    }
  end

  defp row(request, _missing_or_duplicate),
    do: %{"kind" => request.payload["kind"] || "unknown", "reported" => false}

  defp aggregate(rows) do
    totals = Map.new(@counters, &{&1, strict_sum(Enum.map(rows, fn row -> row[&1] end))})
    reported = Enum.count(rows, & &1["reported"])

    Map.merge(totals, %{
      "requests" => length(rows),
      "reported_requests" => reported,
      "usage_complete" => reported == length(rows),
      "tokens_complete" =>
        reported == length(rows) and is_number(totals["full_input_tokens"]) and
          is_number(totals["output_tokens"]),
      "observed" =>
        Map.new(@counters, fn key ->
          {key, rows |> Enum.map(& &1[key]) |> Enum.filter(&is_number/1) |> Enum.sum()}
        end)
    })
  end

  defp full_input(input, read, write, flag)
       when is_number(input) and is_number(read) and is_number(write) do
    if flag in [true, "true"], do: input, else: input + read + write
  end

  defp full_input(_input, _read, _write, _flag), do: nil

  defp subtract(full, read, write) when is_number(full) and is_number(read) and is_number(write),
    do: max(full - read - write, 0)

  defp subtract(_full, _read, _write), do: nil
  defp value(map, key) when is_map(map), do: map[key]
  defp value(_map, _key), do: nil
  defp observed_value(map, key) when is_map(map), do: get_in(map, ["observed", key]) || map[key]
  defp observed_value(_map, _key), do: nil
  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_value), do: nil

  defp strict_sum(values) do
    if Enum.all?(values, &is_number/1), do: Enum.sum(values), else: nil
  end

  defp divide(value, count) when is_number(value) and count > 0, do: value / count
  defp divide(_value, _count), do: nil
end
