# Frozen answer-completeness proxy. A blinded claim-support audit follows live runs.
[task_id, raw_answer] = System.argv()
corpus = System.fetch_env!("RESEARCH_V5_CORPUS") |> File.read!() |> JSON.decode!()
task = Enum.find(corpus["tasks"], &(&1["id"] == task_id)) || raise "unknown task"

answer =
  case JSON.decode(String.trim(raw_answer)) do
    {:ok, %{"answer" => text}} when is_binary(text) -> text
    _ -> raw_answer
  end

missing =
  Enum.reject(task["claims"], fn claim ->
    Regex.match?(Regex.compile!(claim["pattern"]), answer)
  end)

if missing == [] do
  IO.puts("pass")
else
  raise "missing #{Enum.map_join(missing, ", ", & &1["id"])}"
end
