# Answer checker for the research bench, in the style of the discovery
# corpus's report-only cases: the answer passes when it contains every
# expected phrase for the task. Invoked as `elixir check.exs TASK_ID ANSWER`.
[task_id, answer] = System.argv()

expected = %{
  # Offline fixture questions (bench/manifest.json).
  "default-port" => ["7433"],
  "retention" => ["72 hours"],
  "reef-version" => ["3.4.0"],
  "drain-flag" => ["--confirm"],
  "message-limit" => ["4 MiB"],
  # Live questions (bench/live-manifest.json); pending a search key.
  "postgres-port" => ["5432"],
  "teapot-status" => ["418"],
  "elixir-package-manager" => ["hex"],
  "too-many-requests" => ["429"]
}

needles = Map.fetch!(expected, task_id)
haystack = String.downcase(answer)

missing = Enum.reject(needles, &String.contains?(haystack, String.downcase(&1)))

if missing == [] do
  IO.puts("pass")
else
  raise "answer for #{task_id} lacks #{inspect(missing)}: #{inspect(answer)}"
end
