# Prints per-case result tables for a `bench/compare.exs` report:
#
#     mix run bench/summarize.exs tmp/verifier-report.json
#
# Per case and arm: attempts passed, retries the verifier took, mean direct
# requests, mean input/output tokens and mean wall time. Then the benchmark's
# own paired summary. Quota-billed runs carry no dollar cost, so none is shown.
[path] = System.argv()
report = path |> File.read!() |> JSON.decode!()

mean = fn runs, fun ->
  values = runs |> Enum.map(fun) |> Enum.filter(&is_number/1)
  if values == [], do: "?", else: round(Enum.sum(values) / length(values))
end

IO.puts("| Case | Arm | Passed | Retries | Requests | Input tokens | Output tokens | Wall time |")
IO.puts("| --- | --- | --- | --- | --- | --- | --- | --- |")

report["results"]
|> Enum.group_by(&{&1["task_id"], &1["runtime"]})
|> Enum.sort()
|> Enum.each(fn {{task, runtime}, runs} ->
  passed = Enum.count(runs, & &1["passed"])
  retries = Enum.count(runs, &(get_in(&1, ["observation", "verification", "retry?"]) == true))
  requests = mean.(runs, &get_in(&1, ["observation", "usage", "requests"]))
  input = mean.(runs, &get_in(&1, ["observation", "usage", "input_tokens"]))
  output = mean.(runs, &get_in(&1, ["observation", "usage", "output_tokens"]))
  wall = mean.(runs, &(&1["wall_time_ms"] / 1000))
  retries = if runtime == "verifier", do: retries, else: "n/a"

  IO.puts(
    "| `#{task}` | #{runtime} | #{passed}/#{length(runs)} | #{retries} | #{requests} | " <>
      "#{input} | #{output} | #{wall}s |"
  )
end)

IO.puts("")

for {name, summary} <- Enum.sort(report["summary"]["runtimes"]) do
  IO.puts(
    "#{name}: #{summary["passed"]}/#{summary["runs"]} passed, mean #{round(summary["mean_wall_time_ms"] / 1000)}s, " <>
      "mean tokens #{round(summary["mean_input_tokens"] || 0)} in / #{round(summary["mean_output_tokens"] || 0)} out"
  )
end

for pair <- report["summary"]["pairs"] do
  IO.puts(
    "#{pair["left"]} vs #{pair["right"]}: #{pair["right_wins"]} #{pair["right"]} wins, " <>
      "#{pair["left_wins"]} #{pair["left"]} wins, #{pair["ties"]} ties over #{pair["matched_attempts"]} pairs"
  )
end

execution = report["execution"]

IO.puts(
  "attempts #{execution["scheduled"]}/#{execution["planned"]}, aborted: #{execution["aborted"]}"
)
