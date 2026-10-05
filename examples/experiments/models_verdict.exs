# Reads a models.exs report and puts success next to what it cost.
#
#     mix run examples/experiments/models_verdict.exs tmp/experiments/models/<run>/report.json
#
# `mix lemieux.extension.eval` prints pass counts per arm. The comparison a
# model portfolio is for also needs spend, and spend is the half that is often
# unknown: a quota subscription and every gateway route report no price, so
# `Lemieux.Benchmark.Budget` counts those runs rather than treating an unknown
# as zero. A table that silently printed $0.00 for an unpriced arm would make
# the cheapest-looking model the one nobody can price.

[path] = System.argv()
report = path |> File.read!() |> JSON.decode!()

runtimes = report["summary"]["runtimes"]
unknown_cost_runs = get_in(report, ["execution", "unknown_cost_runs"]) || 0

money = fn
  nil -> "unpriced"
  value -> "$" <> :erlang.float_to_binary(value * 1.0, decimals: 4)
end

count = fn
  nil -> "—"
  value -> value |> round() |> Integer.to_string()
end

rows =
  runtimes
  |> Enum.sort_by(fn {_name, s} -> {-s["completion_rate"], s["mean_wall_time_ms"]} end)
  |> Enum.map(fn {name, s} ->
    [
      name,
      "#{s["passed"]}/#{s["runs"]}",
      :erlang.float_to_binary(s["completion_rate"] * 100, decimals: 0) <> "%",
      money.(s["mean_cost_usd"]),
      money.(get_in(s, ["resources", "per_success", "cost_usd"])),
      count.(s["mean_input_tokens"]),
      count.(s["mean_output_tokens"]),
      count.(s["mean_tool_calls"]),
      :erlang.float_to_binary(s["mean_wall_time_ms"] / 1000, decimals: 1) <> "s"
    ]
  end)

header = ~w(model passed rate mean_cost cost_per_win in_tok out_tok calls wall)

widths =
  [header | rows]
  |> Enum.zip_with(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)

line = fn cells ->
  cells
  |> Enum.zip(widths)
  |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)
  |> String.trim_trailing()
  |> IO.puts()
end

line.(header)
line.(Enum.map(widths, &String.duplicate("-", &1)))
Enum.each(rows, line)

if unknown_cost_runs > 0 do
  IO.puts(
    "\n#{unknown_cost_runs} of #{Enum.sum(Enum.map(runtimes, fn {_n, s} -> s["runs"] end))} " <>
      "runs reported no price. An arm shown as `unpriced` was not free; its cost is unknown, " <>
      "and it cannot be compared on spend with one that has a number."
  )
end

IO.puts("\nDevelopment comparison; no qualification or activation.")
