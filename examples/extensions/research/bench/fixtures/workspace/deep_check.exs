# Frozen factual grader for deep-live-manifest.json. The model never receives
# this file: both arms have no local read tool. Citations and source support are
# audited from the report, not used to award an automatic win to a web arm.
[task_id, raw_answer] = System.argv()

answer =
  case JSON.decode(String.trim(raw_answer)) do
    {:ok, %{"answer" => text}} when is_binary(text) -> text
    _ -> raw_answer
  end

rubrics = %{
  "beam-maintenance" => [
    {"Elixir function", ~r/\bTask\.yield_many(?:\/2)?\b/i},
    {"OTP library", ~r/\bbeam_lib\b/i},
    {"old type", ~r/\batom\b/i},
    {"new type", ~r/\b(?:list of characters|character list|charlist)\b/i}
  ],
  "postgres-logical-upgrade" => [
    {"default plugin one", ~r/\bpgoutput\b/i},
    {"default plugin two", ~r/\btest_decoding\b/i},
    {"parameter", ~r/\boutput_plugin_libraries\b/i},
    {"upgrade check condition",
     ~r/(?:not (?:permitted|allowed|included)|must (?:permit|allow)|absent from|add .{0,80}plugin)/i},
    {"skipped version", ~r/\b18\.5\b/i},
    {"skip reason", ~r/\bregression\b/i}
  ],
  "kubernetes-136-upgrade" => [
    {"proxy gate", ~r/\bUnknownVersionInteroperabilityProxy\b/i},
    {"proxy maturity", ~r/\bbeta\b/i},
    {"proxy default", ~r/(?:enabled|on) by default|default(?:s|ed)? to (?:enabled|on)/i},
    {"field", ~r/\bexternalIPs\b/i},
    {"current deprecation", ~r/\bdeprecat\w*\b/i},
    {"current warning", ~r/\bwarn(?:s|ing|ings|ed)?\b/i},
    {"earliest opt-out", ~r/\bv?1\.40\b/i},
    {"earliest removal", ~r/\bv?1\.43\b/i}
  ],
  "python-315-rc2" => [
    {"candidate release date", ~r/(?:2026-09-01|sep(?:t(?:ember)?)?\.?\s+1,?\s+2026)/i},
    {"scheduled final date", ~r/(?:2026-10-01|oct(?:ober)?\.?\s+1,?\s+2026)/i},
    {"ABI promise",
     ~r/(?:no|without|zero)\s+(?:further\s+)?ABI\s+changes|ABI\s+(?:stable|unchanged)/i},
    {"RC wheels", ~r/\bwheel\w*.{0,100}(?:future|final|compatible|work with)/i},
    {"production status",
     ~r/(?:not recommended|avoid|not suitable|do not use|don't use).{0,35}production/i}
  ]
}

missing =
  rubrics
  |> Map.fetch!(task_id)
  |> Enum.reject(fn {_label, pattern} -> Regex.match?(pattern, answer) end)
  |> Enum.map(&elem(&1, 0))

if missing == [] do
  IO.puts("pass")
else
  raise "missing #{Enum.join(missing, ", ")}"
end
