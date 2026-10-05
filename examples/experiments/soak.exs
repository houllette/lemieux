# The sustained provider soak from docs/providers.md: one session, one model,
# a hundred requests of tool continuation, watching what the provider says
# about caching, thinking and cost on every request.
#
#     set -a; . ./.env; set +a
#     LMX_SOAK_MODEL=openai:gpt-5.6 LMX_SOAK_EFFORT=medium \
#       mix run examples/experiments/soak.exs
#     LMX_SOAK_MODEL=zai_coding_plan:glm-5.3 mix run examples/experiments/soak.exs
#     LMX_SOAK_MODEL=ollama:qwen3.8:27b-nvfp4 LMX_SOAK_REQUESTS=30 \
#       mix run examples/experiments/soak.exs
#
# Every prompt asks the model to read one small file with the read tool and
# answer with the integer on its first line, so each prompt is a tool call
# plus an answer: two requests, one of them a tool continuation. The prefix
# grows by a few hundred tokens a prompt, which is what a cache-retention
# benchmark wants: a provider that keeps its cache reports rising
# `cache_read_tokens`, one that drops it reports zero. Thinking is whatever
# the model does at `LMX_SOAK_EFFORT`; the report records what the provider
# billed as output so a reasoning model's spend is visible.
#
# Environment:
#   LMX_SOAK_MODEL      provider:model (required)
#   LMX_SOAK_REQUESTS   how many requests to make at least; default 100
#   LMX_SOAK_EFFORT     reasoning effort string, or unset for the default
#   LMX_SOAK_COST_CAP   metered only: session dollar cap; default 5.0
#   LMX_SOAK_OUT        report directory; default tmp/experiments/soak
#
# Nothing here reads ~/.lmx/config.json: the provider is a direct ReqLLM
# connection keyed from the environment.

alias Lemieux.Session
alias Lemieux.Store.JSONL
alias Lemieux.Tools

model = System.fetch_env!("LMX_SOAK_MODEL")
wanted = String.to_integer(System.get_env("LMX_SOAK_REQUESTS", "100"))
effort = System.get_env("LMX_SOAK_EFFORT")
cost_cap = String.to_float(System.get_env("LMX_SOAK_COST_CAP", "5.0"))
quota? = String.starts_with?(model, ["zai_coding_plan:", "ollama:"])
slug = String.replace(model, ~r/[^A-Za-z0-9.-]/, "_")
out = Path.join(System.get_env("LMX_SOAK_OUT", "tmp/experiments/soak"), slug)
File.rm_rf!(out)
File.mkdir_p!(Path.join(out, "notes"))

{:ok, _apps} = Application.ensure_all_started(:req_llm)
{:ok, _sup} = Lemieux.Supervisor.start_link(name: :lemieux_soak)

# Distinct, non-guessable numbers so a wrong answer is visible.
seed = :rand.seed_s(:exsss, {7, 11, 13})

{numbers, _seed} =
  Enum.map_reduce(1..wanted, seed, fn index, seed ->
    {n, seed} = :rand.uniform_s(900_000, seed)
    number = 100_000 + n

    File.write!(
      Path.join(out, "notes/#{String.pad_leading(Integer.to_string(index), 3, "0")}.txt"),
      "#{number}\nnote #{index} of #{wanted}: the number above is the only fact in this file.\n"
    )

    {number, seed}
  end)

budget = if quota?, do: [max_requests: wanted * 3], else: [max_cost_usd: cost_cap]

options =
  [
    supervisor: :lemieux_soak,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: JSONL.new(Path.join(out, "sessions")),
    model: model,
    subscriber: self(),
    cwd: out,
    tools: Tools.default(),
    params: [max_tokens: 2048],
    max_turns: 6,
    system:
      "You are a careful assistant. When asked about a file, read it with the read tool " <>
        "and answer with exactly what was asked, nothing else."
  ] ++ budget ++ if(effort, do: [reasoning_effort: effort], else: [])

{:ok, session} = Lemieux.start_session(options)
id = Session.id(session)
started = System.monotonic_time(:millisecond)

# Everything a request tells us, in order, plus the events that say what the
# session had to do to get it.
collect = fn collect, acc ->
  receive do
    {:lemieux, ^id, {:finished, reason}} ->
      Map.update!(acc, :finished, &[reason | &1])

    {:lemieux, ^id, {:usage, payload}} ->
      collect.(collect, Map.update!(acc, :usage, &[payload | &1]))

    {:lemieux, ^id, {:tool_call, call}} ->
      collect.(collect, Map.update!(acc, :tool_calls, &[call | &1]))

    {:lemieux, ^id, {:entry, %{type: :assistant} = entry}} ->
      collect.(collect, Map.update!(acc, :answers, &[entry | &1]))

    {:lemieux, ^id, {:entry, %{type: :error} = entry}} ->
      collect.(collect, Map.update!(acc, :errors, &[entry | &1]))

    {:lemieux, ^id, {:provider_retry, info}} ->
      collect.(collect, Map.update!(acc, :retries, &[info | &1]))

    {:lemieux, ^id, {:compacted, _}} ->
      collect.(collect, Map.update!(acc, :compactions, &(&1 + 1)))

    {:lemieux, ^id, _other} ->
      collect.(collect, acc)
  after
    :timer.minutes(6) -> Map.put(acc, :finished, [:soak_timeout | acc.finished])
  end
end

answer_text = fn payload ->
  case payload["content"] do
    blocks when is_list(blocks) ->
      blocks
      |> Enum.map(fn
        %{"text" => t} when is_binary(t) -> t
        _other -> ""
      end)
      |> Enum.join(" ")

    _other ->
      payload["text"] || ""
  end
end

empty = %{
  finished: [],
  usage: [],
  tool_calls: [],
  answers: [],
  errors: [],
  retries: [],
  compactions: 0
}

{rows, requests} =
  Enum.reduce_while(Enum.with_index(numbers, 1), {[], 0}, fn {number, index}, {rows, requests} ->
    if requests >= wanted do
      {:halt, {rows, requests}}
    else
      file = "notes/#{String.pad_leading(Integer.to_string(index), 3, "0")}.txt"
      t0 = System.monotonic_time(:millisecond)

      :ok =
        Session.prompt(
          session,
          "Read #{file} with the read tool and reply with only the integer on its first line."
        )

      acc = collect.(collect, empty)
      elapsed = System.monotonic_time(:millisecond) - t0

      # The assistant answer is a list of content blocks under "content", not a
      # flat "text" field; a tool-calling turn has no text block at all.
      text =
        acc.answers
        |> Enum.map(fn entry -> answer_text.(entry.payload) end)
        |> Enum.join(" ")

      correct? = String.contains?(text, Integer.to_string(number))
      reason = List.first(acc.finished)

      row = %{
        "prompt" => index,
        "file" => file,
        "correct" => correct?,
        "stop" => inspect(reason),
        "requests" => length(acc.usage),
        "tool_calls" => length(acc.tool_calls),
        "errors" => length(acc.errors),
        "retries" => length(acc.retries),
        "compactions" => acc.compactions,
        "elapsed_ms" => elapsed,
        "usage" => Enum.reverse(acc.usage)
      }

      IO.puts(
        "#{String.pad_leading(Integer.to_string(index), 3)} #{if correct?, do: "ok ", else: "BAD"} " <>
          "#{inspect(reason)} requests=#{length(acc.usage)} tools=#{length(acc.tool_calls)} " <>
          "#{elapsed}ms cache_read=#{Enum.map(acc.usage, & &1["cache_read_tokens"]) |> inspect()}"
      )

      halt? = reason in [:soak_timeout] or match?({:error, _}, reason) or reason == :budget

      if halt?,
        do: {:halt, {[row | rows], requests + length(acc.usage)}},
        else: {:cont, {[row | rows], requests + length(acc.usage)}}
    end
  end)

rows = Enum.reverse(rows)
usages = Enum.flat_map(rows, & &1["usage"])
wall_ms = System.monotonic_time(:millisecond) - started

sum = fn key -> usages |> Enum.map(&(&1[key] || 0)) |> Enum.sum() end

cache_ratio = fn slice ->
  input = slice |> Enum.map(&(&1["input_tokens"] || 0)) |> Enum.sum()
  read = slice |> Enum.map(&(&1["cache_read_tokens"] || 0)) |> Enum.sum()
  if input + read > 0, do: Float.round(read / (input + read), 3), else: 0.0
end

cost =
  if Enum.any?(usages, &is_nil(&1["cost_usd"])),
    do: nil,
    else: usages |> Enum.map(& &1["cost_usd"]) |> Enum.sum() |> Float.round(4)

summary = %{
  "model" => model,
  "reasoning_effort" => effort,
  "prompts" => length(rows),
  "requests" => length(usages),
  "correct" => Enum.count(rows, & &1["correct"]),
  "tool_calls" => rows |> Enum.map(& &1["tool_calls"]) |> Enum.sum(),
  "errors" => rows |> Enum.map(& &1["errors"]) |> Enum.sum(),
  "provider_retries" => rows |> Enum.map(& &1["retries"]) |> Enum.sum(),
  "compactions" => rows |> Enum.map(& &1["compactions"]) |> Enum.sum(),
  "stops" => rows |> Enum.map(& &1["stop"]) |> Enum.frequencies(),
  "input_tokens" => sum.("input_tokens"),
  "output_tokens" => sum.("output_tokens"),
  "cache_read_tokens" => sum.("cache_read_tokens"),
  "cache_write_tokens" => sum.("cache_write_tokens"),
  "cache_read_share_first_10" => cache_ratio.(Enum.take(usages, 10)),
  "cache_read_share_last_10" => cache_ratio.(Enum.take(usages, -10)),
  "cost_usd" => cost,
  "wall_ms" => wall_ms,
  "mean_request_ms" => if(length(usages) > 0, do: div(wall_ms, length(usages)), else: nil),
  "req_llm" => to_string(Application.spec(:req_llm, :vsn)),
  "lemieux" => Lemieux.version(),
  "session_id" => id,
  "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601()
}

File.write!(
  Path.join(out, "report.json"),
  JSON.encode!(%{"summary" => summary, "prompts" => rows})
)

IO.puts(JSON.encode!(summary))
IO.puts("report: #{Path.join(out, "report.json")}")
