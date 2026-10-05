# WARNING: this script reads YOUR real lmx sessions (~/.lmx/sessions) and,
# with --allow-live, uploads anonymized digests of them (your prompts, a
# one-line summary of every tool call, and the final answers, truncated) to
# two model providers, Z.AI and OpenAI, at their usual billing. Without
# --allow-live it refuses before reading anything. LMX_LABELS_DIGEST_ONLY=1
# writes the digests locally for inspection and calls no provider.
#
# Blinded labelling of anonymized task transcripts for independent
# read-only investigation branches.
#
#     LMX_LABELS_DIGEST_ONLY=1 mix run examples/experiments/transcript_labels.exs
#     mix run examples/experiments/transcript_labels.exs --allow-live
#
# docs/subagents.md ("Evaluation gate") asks, before the A/B, for
# 100 anonymized task transcripts labelled with blinded agreement on whether
# they contain at least two independent read-only investigation branches;
# the original assumption was that at least 25% do. This script is that
# labelling.
#
# Three stages, all deterministic apart from the model calls:
#
#   1. Selection. Real interactive `lmx` sessions from ~/.lmx/sessions are
#      preferred: a session qualifies when it has at least one user message,
#      at least three tool calls, and is not a delegated child (a child is
#      named by a `subagent_spawn` or `subagent_result` entry in a sibling
#      transcript, or names itself in its own result envelope). When fewer
#      than 100 qualify, the rest come from the benchmark session
#      directories under tmp/experiments and tmp/discovery, most recent
#      first by the timestamp of their first entry.
#
#   2. Anonymization. Each selected transcript becomes a compact digest: the
#      user prompts, the ordered tool calls as {tool, one-line argument
#      summary}, and the final assistant answer truncated to 400 characters.
#      Every absolute path is rewritten to <path-N> (numbered per session in
#      order of first appearance, so the same file keeps the same label);
#      emails, URLs and key-looking tokens become <redacted>; file contents
#      and tool outputs are omitted entirely. Sessions get opaque ids t001…;
#      the id map back to source paths is written separately and never
#      shown to a labeller.
#
#   3. Labelling. Two labellers answer the same question over the same
#      digest, each in a fresh tool-less one-turn session at temperature 0,
#      never seeing the other's answer. A malformed answer is retried once;
#      every raw reply is kept.
#
# Outputs, under tmp/experiments/transcript-labels/:
#
#   digests.jsonl   one anonymized digest per line
#   id-map.json     opaque id -> source path and source kind (not for labellers)
#   labels.json     per session: both labellers' parsed answers and raw text
#   REPORT.md       selection rule, source split, rates, agreement, kappa,
#                   cost and tokens per labeller, and the 25% verdict
#
# Flags and environment:
#
#   --allow-live               required to send digests to the labellers
#   LMX_LABELS_DIGEST_ONLY=1   write digests and the id map, then stop
#   LMX_LABELS_LIMIT=N         label only the first N selected sessions
#   LMX_LABELS_COST_CAP=USD    stop the metered labeller past this measured
#                              spend (default 2.00)
#   LMX_LABELS_REUSE=1         reuse a labeller's replies from a previous run
#                              (raw-<model>.json) instead of calling it again
#   LMX_LABELS_CONCURRENCY=N   concurrent calls per labeller (default 4)
#
# The labellers are a quota model and a metered one; both are named below.

alias Lemieux.Agent.Session, as: AgentSession
alias Lemieux.Entry
alias Lemieux.Store
alias Lemieux.Store.JSONL
alias Lemieux.Transcript

target = 100
output_dir = Path.expand("tmp/experiments/transcript-labels")
real_dir = Path.expand("~/.lmx/sessions")
benchmark_globs = ~w(tmp/experiments/**/sessions/*.jsonl tmp/discovery/**/sessions/*.jsonl)

labellers = ["zai_coding_plan:glm-5.3-flash", "openai:gpt-5-mini"]

digest_only? = System.get_env("LMX_LABELS_DIGEST_ONLY") in ["1", "true"]
reuse? = System.get_env("LMX_LABELS_REUSE") in ["1", "true"]

# Consent comes first: what this sends is drawn from a person's own sessions,
# to providers they may never have chosen, so an unflagged run stops here,
# before a single session is read.
unless digest_only? or "--allow-live" in System.argv() do
  Mix.raise(
    "transcript_labels sends anonymized digests of your ~/.lmx/sessions to " <>
      Enum.join(labellers, " and ") <>
      ". Pass --allow-live to do that, or set LMX_LABELS_DIGEST_ONLY=1 to write " <>
      "the digests locally without calling any provider."
  )
end

limit =
  System.get_env("LMX_LABELS_LIMIT") && String.to_integer(System.get_env("LMX_LABELS_LIMIT"))

cost_cap = String.to_float(System.get_env("LMX_LABELS_COST_CAP", "2.00"))
concurrency = String.to_integer(System.get_env("LMX_LABELS_CONCURRENCY", "4"))

File.mkdir_p!(output_dir)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

read_transcript = fn path ->
  store = JSONL.new(Path.dirname(path))

  case Store.read(store, Path.basename(path, ".jsonl")) do
    {:ok, entries} -> {:ok, entries}
    {:error, reason} -> {:error, reason}
  end
end

tool_calls_of = fn entries ->
  Enum.flat_map(entries, fn
    %Entry{type: :assistant, payload: %{"tool_calls" => calls}} when is_list(calls) -> calls
    _entry -> []
  end)
end

# Every child id a directory's transcripts name, in either direction: the
# parent's spawn and result envelopes, and the child's own copy of its
# envelope. A child that died before taking its envelope is still named by
# the parent's spawn, which is what `Transcript.delegated?/2` alone misses.
children_named = fn transcripts ->
  transcripts
  |> Enum.flat_map(fn {_path, entries} ->
    Enum.flat_map(entries, fn
      %Entry{type: :subagent_spawn, payload: payload} ->
        [payload["child_id"]]

      %Entry{type: :subagent_result, payload: payload} ->
        [payload["child_id"], payload["transcript_id"]]

      _entry ->
        []
    end)
  end)
  |> Enum.reject(&is_nil/1)
  |> MapSet.new()
end

load_dir = fn paths ->
  {loaded, unreadable} =
    paths
    |> Enum.sort()
    |> Enum.map(fn path -> {path, read_transcript.(path)} end)
    |> Enum.split_with(fn {_path, result} -> match?({:ok, _}, result) end)

  transcripts = Enum.map(loaded, fn {path, {:ok, entries}} -> {path, entries} end)
  {transcripts, Enum.map(unreadable, fn {path, _err} -> path end)}
end

qualifies? = fn {path, entries}, children ->
  id = Path.basename(path, ".jsonl")

  Enum.any?(entries, &(&1.type == :user)) and
    length(tool_calls_of.(entries)) >= 3 and
    not MapSet.member?(children, id) and
    not Transcript.delegated?(entries, id)
end

first_at = fn entries -> entries |> List.first() |> Map.fetch!(:at) end

{real_transcripts, real_unreadable} =
  real_dir |> Path.join("*.jsonl") |> Path.wildcard() |> load_dir.()

real_children = children_named.(real_transcripts)

real_selected =
  real_transcripts
  |> Enum.filter(&qualifies?.(&1, real_children))
  |> Enum.sort_by(fn {path, entries} -> {first_at.(entries), path} end, :desc)
  |> Enum.take(target)

# Benchmark sessions are grouped by directory so a child is matched against
# its own parent's transcript, not against every benchmark ever run. The
# labellers' own sessions land under the output directory and are excluded
# by name so a rerun cannot select what the previous run produced.
benchmark_paths =
  benchmark_globs
  |> Enum.flat_map(&Path.wildcard/1)
  |> Enum.map(&Path.expand/1)
  |> Enum.reject(&String.starts_with?(&1, output_dir <> "/"))
  |> Enum.uniq()
  |> Enum.sort()

{benchmark_transcripts, benchmark_unreadable} = load_dir.(benchmark_paths)

benchmark_qualifying =
  benchmark_transcripts
  |> Enum.group_by(fn {path, _entries} -> Path.dirname(path) end)
  |> Enum.flat_map(fn {_dir, transcripts} ->
    children = children_named.(transcripts)
    Enum.filter(transcripts, &qualifies?.(&1, children))
  end)

benchmark_selected =
  benchmark_qualifying
  |> Enum.sort_by(fn {path, entries} -> {first_at.(entries), path} end, :desc)
  |> Enum.take(max(target - length(real_selected), 0))

selected =
  (Enum.map(real_selected, &{"real", &1}) ++ Enum.map(benchmark_selected, &{"benchmark", &1}))
  |> Enum.with_index(1)
  |> Enum.map(fn {{source, {path, entries}}, index} ->
    id = "t" <> String.pad_leading(Integer.to_string(index), 3, "0")
    %{id: id, source: source, path: path, entries: entries}
  end)

IO.puts(
  "selected #{length(selected)}: #{length(real_selected)} real of " <>
    "#{length(real_transcripts)} readable (#{length(real_unreadable)} unreadable), " <>
    "#{length(benchmark_selected)} benchmark of #{length(benchmark_qualifying)} qualifying " <>
    "(#{length(benchmark_transcripts)} readable, #{length(benchmark_unreadable)} unreadable)"
)

# ---------------------------------------------------------------------------
# Anonymization
# ---------------------------------------------------------------------------

# Order matters: URLs and emails are redacted before paths so the path rule
# never sees the inside of a URL, and key-shaped tokens go last so a token
# that also looked like a path segment has already been replaced. The last
# pattern is deliberately broad — any 32+ character opaque token — because
# a labeller gains nothing from a digest, ULID or hash, and a missed key is
# the failure that matters.
redactions = [
  {~r{https?://[^\s"'`<>)\]]+}, "<redacted>"},
  {~r/[\w.+-]+@[\w-]+(?:\.[\w-]+)+/, "<redacted>"},
  {~r/(?i)\b(?:sk|pk|rk|xai)-[A-Za-z0-9_-]{12,}/, "<redacted>"},
  {~r/\bgh[opsu]_[A-Za-z0-9]{20,}/, "<redacted>"},
  {~r/\bxox[abprs]-[A-Za-z0-9-]{10,}/, "<redacted>"},
  {~r/\bAKIA[A-Z0-9]{16}\b/, "<redacted>"},
  {~r/\bAIza[0-9A-Za-z_-]{35}/, "<redacted>"},
  {~r/(?i)\b(api[_-]?key|secret|password|passwd|token|authorization|bearer)(?:\s*[:=]\s*|\s+)["']?[A-Za-z0-9._\-\/+=]{8,}["']?/,
   "\\1=<redacted>"},
  {~r/\b[A-Za-z0-9_-]{32,}(?:\.[A-Za-z0-9_-]{8,})?\b/, "<redacted>"}
]

redact = fn text ->
  Enum.reduce(redactions, text, fn {pattern, replacement}, acc ->
    Regex.replace(pattern, acc, replacement)
  end)
end

# An absolute path is a slash-led run of path characters not preceded by
# another path or word character (so `a/b`, `./x` and `//` are left alone).
# Each session numbers its paths in order of first appearance; the map is
# threaded through every field of the digest so the same file is the same
# label in a prompt, a tool call and the answer.
path_pattern = ~r{(?<![\w./~-])/[\w.@%+~-]+(?:/[\w.@%+~-]*)*}

anonymize = fn text, paths ->
  text = redact.(text)

  {rewritten, paths} =
    Regex.scan(path_pattern, text)
    |> List.flatten()
    |> Enum.reduce({text, paths}, fn path, {acc, paths} ->
      {label, paths} =
        case Map.fetch(paths, path) do
          {:ok, label} ->
            {label, paths}

          :error ->
            label = "<path-#{map_size(paths) + 1}>"
            {label, Map.put(paths, path, label)}
        end

      {String.replace(acc, path, label), paths}
    end)

  {rewritten, paths}
end

one_line = fn text ->
  text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
end

clip = fn text, max ->
  if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
end

range = fn args ->
  ~w(offset limit line line_start line_end depth query max_results)
  |> Enum.filter(&Map.has_key?(args, &1))
  |> Enum.map_join(" ", &"#{&1}=#{inspect(args[&1])}")
  |> case do
    "" -> ""
    tail -> " (" <> tail <> ")"
  end
end

size = fn
  text when is_binary(text) -> "#{byte_size(text)} bytes"
  _other -> "0 bytes"
end

# One line per call, omitting file contents and outputs. What survives is
# the shape of the work — which file, which command, how much was written —
# which is what a labeller needs to see two lines of inquiry.
summarize = fn name, args ->
  args = if is_map(args), do: args, else: %{}

  case name do
    "read" ->
      to_string(args["path"] || args["command"] || "") <> range.(args)

    "bash" ->
      one_line.(args["command"] || args["cmd"] || "")

    "edit" ->
      "#{args["path"]} (replace #{size.(args["old"])} with #{size.(args["new"])}" <>
        if(args["replace_all"], do: ", all occurrences)", else: ")")

    "write" ->
      "#{args["path"]} (#{size.(args["content"])})"

    "delegate" ->
      tasks = List.wrap(args["tasks"])

      "#{length(tasks)} task(s): " <>
        Enum.map_join(tasks, "; ", fn task ->
          task = if is_map(task), do: task, else: %{}
          "[#{task["definition_id"]}] " <> clip.(one_line.(task["objective"] || ""), 120)
        end)

    "elixir" ->
      one_line.(args["code"] || "")

    "ask_user" ->
      one_line.(args["question"] || "")

    "skill" ->
      one_line.("#{args["name"]} #{args["arguments"] || ""}")

    "extension_workflow" ->
      one_line.("#{args["action"]} #{args["name"] || ""} #{args["directory"] || ""}")

    _other ->
      args |> Map.keys() |> Enum.sort() |> Enum.join(", ")
  end
end

digest_of = fn %{id: id, entries: entries} ->
  results = Map.new(entries, fn entry -> {entry.payload["call_id"], entry} end)

  {prompts, paths} =
    entries
    |> Enum.filter(&(&1.type == :user))
    |> Enum.map_reduce(%{}, fn entry, paths ->
      {text, paths} = anonymize.(one_line.(entry.payload["text"] || ""), paths)
      {clip.(text, 1500), paths}
    end)

  {calls, paths} =
    entries
    |> tool_calls_of.()
    |> Enum.map_reduce(paths, fn call, paths ->
      {summary, paths} = anonymize.(summarize.(call["name"], call["arguments"]), paths)
      result = results[call["id"]]

      call = %{"tool" => call["name"], "summary" => clip.(summary, 200)}

      call =
        if match?(%Entry{type: :tool_result, payload: %{"error" => true}}, result),
          do: Map.put(call, "error", true),
          else: call

      {call, paths}
    end)

  {answer, _paths} =
    case Transcript.latest_assistant_text(entries) do
      {:ok, text} -> anonymize.(one_line.(text), paths)
      {:error, :not_found} -> {"", paths}
    end

  %{
    "id" => id,
    "prompts" => prompts,
    "tool_calls" => calls,
    "final_answer" => clip.(answer, 400),
    "turns" => Enum.count(entries, &(&1.type == :assistant))
  }
end

digests = Enum.map(selected, digest_of)

File.write!(
  Path.join(output_dir, "digests.jsonl"),
  Enum.map(digests, &[JSON.encode!(&1), ?\n])
)

File.write!(
  Path.join(output_dir, "id-map.json"),
  JSON.encode!(
    Map.new(selected, fn %{id: id, source: source, path: path} ->
      {id, %{"source" => source, "path" => path}}
    end)
  )
)

IO.puts("wrote #{Path.join(output_dir, "digests.jsonl")} and id-map.json")

# `System.stop/1` is asynchronous; without the sleep the script would start
# the labellers while the VM was shutting down.
if digest_only? do
  System.stop(0)
  Process.sleep(:infinity)
end

# ---------------------------------------------------------------------------
# Labelling
# ---------------------------------------------------------------------------

question =
  "Does this task contain at least two INDEPENDENT read-only investigation branches, " <>
    "i.e. two lines of inquiry that only read files or run non-mutating commands, that " <>
    "do not depend on each other's results, and that could have been carried out " <>
    "concurrently by separate investigators? Answer with JSON: " <>
    "{\"independent_branches\": <integer>, \"two_or_more\": true|false, " <>
    "\"branches\": [short description per branch], \"confidence\": 0-1}."

system =
  "You are labelling an anonymized digest of a coding-agent session. The digest lists " <>
    "the user's prompts, every tool call in order (tool name and a one-line summary of " <>
    "its arguments; file contents and outputs are omitted; <path-N> stands for one " <>
    "specific file or directory, the same N being the same path), and the final answer. " <>
    "Judge only from the digest. Answer with one JSON object and nothing else."

render = fn digest ->
  prompts =
    digest["prompts"]
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {text, index} -> "#{index}. #{text}" end)

  calls =
    digest["tool_calls"]
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {call, index} ->
      flag = if call["error"], do: " [failed]", else: ""
      "#{index}. #{call["tool"]}#{flag}: #{call["summary"]}"
    end)

  """
  USER PROMPTS:
  #{prompts}

  TOOL CALLS (#{length(digest["tool_calls"])}, in order, over #{digest["turns"]} model turns):
  #{calls}

  FINAL ANSWER (truncated):
  #{digest["final_answer"]}

  QUESTION:
  #{question}
  """
end

# A reply is read leniently: the first balanced JSON object in it, with or
# without a code fence. `two_or_more` is derived from the branch count when
# the model gave the count and skipped the boolean, since the count is the
# stronger claim. Anything else is malformed and earns the one retry.
parse = fn answer ->
  text = answer |> to_string() |> String.replace(~r/```(?:json)?/i, "")

  with [json | _] <- Regex.run(~r/\{.*\}/s, text),
       {:ok, %{} = map} <- JSON.decode(json) do
    count = map["independent_branches"]
    two = map["two_or_more"]

    two_or_more =
      cond do
        is_boolean(two) -> two
        is_integer(count) -> count >= 2
        true -> nil
      end

    if is_nil(two_or_more) do
      nil
    else
      %{
        "independent_branches" => if(is_integer(count), do: count, else: nil),
        "two_or_more" => two_or_more,
        "branches" => map["branches"] |> List.wrap() |> Enum.map(&to_string/1),
        "confidence" => if(is_number(map["confidence"]), do: map["confidence"] * 1.0, else: nil)
      }
    end
  else
    _other -> nil
  end
end

metered? = fn model -> not String.starts_with?(model, "zai_coding_plan:") end
slug = fn model -> String.replace(model, ~r/[^A-Za-z0-9.-]/, "_") end

provider = Lemieux.Providers.ReqLLM.new(receive_timeout: 120_000)

# Tool-less, so the working directory is never read; an empty scratch
# directory keeps the workspace snapshot the runtime takes on every run
# trivial instead of walking the repository twice per call.
scratch = Path.join(System.tmp_dir!(), "lemieux-transcript-labels-" <> Lemieux.ID.generate())
File.mkdir_p!(scratch)

# The metered labeller's running spend, checked before every call; a
# concurrent batch can overshoot by at most `concurrency` calls.
{:ok, spend} = Agent.start_link(fn -> %{} end)

usage_of = fn
  {:ok, observation} -> observation["usage"]
  {:error, _reason, observation} when is_map(observation) -> observation["usage"]
  {:error, _reason} -> %{}
end

answer_of = fn
  {:ok, observation} -> observation["answer"]
  {:error, _reason, observation} when is_map(observation) -> observation["answer"]
  {:error, reason} -> "<error: #{inspect(reason)}>"
end

call = fn model, digest ->
  budget = if metered?.(model), do: [max_cost_usd: 0.05], else: [max_requests: 1]

  session_options =
    [
      system: system,
      tools: [],
      max_turns: 1,
      params: [max_tokens: 4096, temperature: 0.0]
    ] ++ budget

  result =
    AgentSession.run(
      %{prompt: render.(digest), cwd: scratch, timeout_ms: :timer.minutes(3)},
      provider: provider,
      model: model,
      sessions_dir: Path.join(output_dir, "sessions"),
      session_options: session_options
    )

  usage = usage_of.(result) || %{}
  cost = usage["cost_usd"] || usage["observed_cost_usd"] || 0.0
  Agent.update(spend, &Map.update(&1, model, cost, fn total -> total + cost end))

  %{"answer" => answer_of.(result), "usage" => usage}
end

label_one = fn model, digest ->
  over_cap? = metered?.(model) and Agent.get(spend, &Map.get(&1, model, 0.0)) >= cost_cap

  if over_cap? do
    %{"parsed" => nil, "raw" => [], "usages" => [], "skipped" => "cost cap"}
  else
    first = call.(model, digest)

    case parse.(first["answer"]) do
      nil ->
        second = call.(model, digest)

        %{
          "parsed" => parse.(second["answer"]),
          "raw" => [first["answer"], second["answer"]],
          "usages" => [first["usage"], second["usage"]],
          "retried" => true
        }

      parsed ->
        %{"parsed" => parsed, "raw" => [first["answer"]], "usages" => [first["usage"]]}
    end
  end
end

to_label = if limit, do: Enum.take(digests, limit), else: digests

label_all = fn model ->
  raw_path = Path.join(output_dir, "raw-#{slug.(model)}.json")

  if reuse? and File.exists?(raw_path) do
    IO.puts("#{model}: reusing #{raw_path}")
    raw_path |> File.read!() |> JSON.decode!()
  else
    IO.puts("#{model}: labelling #{length(to_label)} digests")

    results =
      to_label
      |> Task.async_stream(&{&1["id"], label_one.(model, &1)},
        max_concurrency: concurrency,
        ordered: true,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, pair} -> pair end)
      |> Map.new()

    File.write!(raw_path, JSON.encode!(results))
    results
  end
end

by_labeller = Map.new(labellers, fn model -> {model, label_all.(model)} end)

labels =
  Enum.map(to_label, fn digest ->
    %{
      "id" => digest["id"],
      "labels" =>
        Map.new(labellers, fn model -> {model, Map.fetch!(by_labeller[model], digest["id"])} end)
    }
  end)

File.write!(
  Path.join(output_dir, "labels.json"),
  JSON.encode!(%{"question" => question, "labellers" => labellers, "sessions" => labels})
)

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

source_of = Map.new(selected, &{&1.id, &1.source})

verdict = fn label -> get_in(label, ["parsed", "two_or_more"]) end

[model_a, model_b] = labellers

pct = fn
  nil -> "n/a"
  value -> :erlang.float_to_binary(value * 100, decimals: 1) <> "%"
end

fmt = fn
  nil -> "n/a"
  value when is_float(value) -> :erlang.float_to_binary(value, decimals: 3)
  value -> to_string(value)
end

# Wilson 95% interval for a proportion; the sample is small enough that the
# naive interval would cross zero for a rare outcome.
wilson = fn
  _k, 0 ->
    {nil, nil}

  k, n ->
    z = 1.96
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * :math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    {centre - half, centre + half}
end

stats = fn rows ->
  n = length(rows)
  a_parsed = Enum.reject(rows, &is_nil(verdict.(&1["labels"][model_a])))
  b_parsed = Enum.reject(rows, &is_nil(verdict.(&1["labels"][model_b])))

  both =
    Enum.filter(rows, fn row ->
      not is_nil(verdict.(row["labels"][model_a])) and
        not is_nil(verdict.(row["labels"][model_b]))
    end)

  a_true = Enum.count(a_parsed, &(verdict.(&1["labels"][model_a]) == true))
  b_true = Enum.count(b_parsed, &(verdict.(&1["labels"][model_b]) == true))

  agree =
    Enum.count(both, fn row ->
      verdict.(row["labels"][model_a]) == verdict.(row["labels"][model_b])
    end)

  both_true =
    Enum.count(both, fn row ->
      verdict.(row["labels"][model_a]) == true and verdict.(row["labels"][model_b]) == true
    end)

  both_false =
    Enum.count(both, fn row ->
      verdict.(row["labels"][model_a]) == false and verdict.(row["labels"][model_b]) == false
    end)

  m = length(both)

  kappa =
    if m > 0 do
      pa_true = Enum.count(both, &(verdict.(&1["labels"][model_a]) == true)) / m
      pb_true = Enum.count(both, &(verdict.(&1["labels"][model_b]) == true)) / m
      po = agree / m
      pe = pa_true * pb_true + (1 - pa_true) * (1 - pb_true)
      if pe >= 1.0, do: 1.0, else: (po - pe) / (1 - pe)
    end

  {lower, upper} = wilson.(both_true, m)

  %{
    "sessions" => n,
    "a_parsed" => length(a_parsed),
    "b_parsed" => length(b_parsed),
    "both_parsed" => m,
    "a_true" => a_true,
    "a_true_rate" => if(a_parsed == [], do: nil, else: a_true / length(a_parsed)),
    "b_true" => b_true,
    "b_true_rate" => if(b_parsed == [], do: nil, else: b_true / length(b_parsed)),
    "agree" => agree,
    "agreement_rate" => if(m == 0, do: nil, else: agree / m),
    "kappa" => kappa,
    "both_true" => both_true,
    "both_true_rate" => if(m == 0, do: nil, else: both_true / m),
    "both_true_rate_of_all" => if(n == 0, do: nil, else: both_true / n),
    "both_true_wilson" => [lower, upper],
    "both_false" => both_false
  }
end

overall = stats.(labels)

per_source =
  labels
  |> Enum.group_by(&source_of[&1["id"]])
  |> Enum.sort()
  |> Enum.map(fn {source, rows} -> {source, stats.(rows)} end)

usage_totals =
  Map.new(labellers, fn model ->
    usages = Enum.flat_map(labels, &(&1["labels"][model]["usages"] || []))

    sum = fn key -> usages |> Enum.map(&(&1[key] || 0)) |> Enum.sum() end
    costs = Enum.map(usages, &(&1["cost_usd"] || &1["observed_cost_usd"]))

    {model,
     %{
       "calls" => length(usages),
       "retries" => Enum.count(labels, &(&1["labels"][model]["retried"] == true)),
       "skipped" => Enum.count(labels, &(&1["labels"][model]["skipped"] != nil)),
       "malformed_after_retry" =>
         Enum.count(labels, fn row ->
           row["labels"][model]["skipped"] == nil and row["labels"][model]["parsed"] == nil
         end),
       "input_tokens" => sum.("input_tokens"),
       "output_tokens" => sum.("output_tokens"),
       "cache_read_tokens" => sum.("cache_read_tokens"),
       "cost_usd" => costs |> Enum.filter(&is_number/1) |> Enum.sum(),
       "cost_known_calls" => Enum.count(costs, &is_number/1)
     }}
  end)

distinct_prompts = fn source ->
  digests
  |> Enum.filter(&(source_of[&1["id"]] == source))
  |> Enum.map(& &1["prompts"])
  |> Enum.uniq()
  |> length()
end

held? = overall["both_true_rate"] != nil and overall["both_true_rate"] >= 0.25

source_rows =
  Enum.map_join(per_source, "\n", fn {source, s} ->
    "| #{source} | #{s["sessions"]} | #{pct.(s["a_true_rate"])} | #{pct.(s["b_true_rate"])} | " <>
      "#{pct.(s["agreement_rate"])} | #{fmt.(s["kappa"])} | #{s["both_true"]}/#{s["both_parsed"]} (#{pct.(s["both_true_rate"])}) |"
  end)

usage_rows =
  Enum.map_join(labellers, "\n", fn model ->
    u = usage_totals[model]
    kind = if metered?.(model), do: "metered", else: "quota"

    "| #{model} | #{kind} | #{u["calls"]} | #{u["retries"]} | #{u["malformed_after_retry"]} | " <>
      "#{u["skipped"]} | #{u["input_tokens"]} | #{u["cache_read_tokens"]} | #{u["output_tokens"]} | " <>
      "#{fmt.(u["cost_usd"] * 1.0)} (#{u["cost_known_calls"]}/#{u["calls"]} priced) |"
  end)

[lower, upper] = overall["both_true_wilson"]

report = """
# Transcript labelling: independent read-only investigation branches

Generated by `examples/experiments/transcript_labels.exs` on #{Date.utc_today()}.
Fulfils the pre-A/B labelling step in `docs/subagents.md`
("Evaluation gate"): label 100 anonymized task transcripts with blinded
agreement on independent investigations, against the original assumption
that at least 25% contain two independent read-only branches.

## Selection

A transcript qualifies when it has at least one user message, at least three
tool calls, and is not a delegated child (named by a `subagent_spawn` or
`subagent_result` entry in a sibling transcript, or naming itself in its own
result envelope). Real interactive `lmx` sessions from `~/.lmx/sessions` are
taken first; the remainder is filled from the benchmark session directories
under `tmp/experiments` and `tmp/discovery`, most recent first by the
timestamp of each transcript's first entry.

| source | selected | qualifying | readable | unreadable | distinct prompt sets |
| --- | --- | --- | --- | --- | --- |
| real (`~/.lmx/sessions`) | #{length(real_selected)} | #{length(real_selected)} | #{length(real_transcripts)} | #{length(real_unreadable)} | #{distinct_prompts.("real")} |
| benchmark (`tmp/experiments`, `tmp/discovery`) | #{length(benchmark_selected)} | #{length(benchmark_qualifying)} | #{length(benchmark_transcripts)} | #{length(benchmark_unreadable)} | #{distinct_prompts.("benchmark")} |

Sessions labelled: #{length(labels)} (of #{length(selected)} selected#{if limit, do: ", limited by LMX_LABELS_LIMIT", else: ""}).

## Anonymization

Each digest holds the user prompts, the ordered tool calls as `{tool,
one-line argument summary}` with every absolute path rewritten to `<path-N>`
(numbered per session by first appearance), every email, URL and key-shaped
token replaced by `<redacted>`, file contents and tool outputs omitted, and
the final assistant answer truncated to 400 characters. Opaque ids `t001`…
map back to sources only in `id-map.json`, which no labeller saw.

## Labellers

Both labellers answered the identical question over the identical digest in
a fresh tool-less session (`max_turns: 1`, temperature 0, no tools), each
blind to the other. A malformed reply was retried once; every raw reply is
in `labels.json`.

Question: #{question}

## Results

| measure | value |
| --- | --- |
| `#{model_a}` marked two_or_more | #{overall["a_true"]}/#{overall["a_parsed"]} (#{pct.(overall["a_true_rate"])}) |
| `#{model_b}` marked two_or_more | #{overall["b_true"]}/#{overall["b_parsed"]} (#{pct.(overall["b_true_rate"])}) |
| both labels parsed | #{overall["both_parsed"]}/#{overall["sessions"]} |
| agreement | #{overall["agree"]}/#{overall["both_parsed"]} (#{pct.(overall["agreement_rate"])}) |
| Cohen's kappa | #{fmt.(overall["kappa"])} |
| agreed-positive (both true) | #{overall["both_true"]}/#{overall["both_parsed"]} (#{pct.(overall["both_true_rate"])}); Wilson 95% [#{pct.(lower)}, #{pct.(upper)}] |
| agreed-negative (both false) | #{overall["both_false"]}/#{overall["both_parsed"]} |
| agreed-positive over all selected | #{overall["both_true"]}/#{overall["sessions"]} (#{pct.(overall["both_true_rate_of_all"])}) |

### Per source

| source | sessions | `#{model_a}` true | `#{model_b}` true | agreement | kappa | agreed-positive |
| --- | --- | --- | --- | --- | --- | --- |
#{source_rows}

### Cost and tokens per labeller

| labeller | plan | calls | retries | malformed after retry | skipped (cap) | input tokens | cached | output tokens | measured cost USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
#{usage_rows}

The quota labeller reports no dollars by construction; the metered labeller's
cost is the provider-reported `cost_usd` summed over every call (cap
#{fmt.(cost_cap)} USD).

## Verdict on the 25% assumption

Under agreed-positive labels (both labellers true), #{overall["both_true"]} of
#{overall["both_parsed"]} labelled transcripts (#{pct.(overall["both_true_rate"])}) contain
at least two independent read-only investigation branches. The assumption
that at least 25% do **#{if held?, do: "held", else: "did not hold"}**#{if held?, do: "", else: " (the Wilson 95% upper bound is #{pct.(upper)})"}.
"""

File.write!(Path.join(output_dir, "REPORT.md"), report)

IO.puts("")
IO.puts(report)
IO.puts("wrote #{Path.join(output_dir, "REPORT.md")}")
Agent.stop(spend)
