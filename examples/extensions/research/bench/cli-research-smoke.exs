# Qualify the ordinary lmx host's credential-backed research default once.
unless System.argv() == ["--execute"], do: raise("pass --execute to run live research")

{:ok, _apps} = Application.ensure_all_started(:req_llm)

Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.CLI.Options
alias Lemieux.CLI.Runtime
alias Lemieux.Session
alias Lemieux.Store.JSONL
alias ResearchBench.LiveSetup

config = LiveSetup.config()
brave_key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")
unless is_binary(brave_key) and brave_key != "", do: raise("missing Brave key")

# RESEARCH_MODEL and RESEARCH_EFFORT; see live_setup.exs.
%{model: model, effort: effort, provider: provider, secrets: secrets} =
  LiveSetup.model(config, receive_timeout: :infinity)

{:ok, options} = Options.parse(["--model", model])
true = options.web_search == "brave" and options.web_fetch
# The source checkout does not include the optional Jev-compaction release
# package supplied by dist/lmx. Keep this smoke focused on web research.
options = %{
  options
  | config: %{options.config | settings: Map.delete(options.config.settings, "jev_compaction")}
}

workspace = Path.expand("tmp/cli-smoke-workspace")
File.mkdir_p!(workspace)
supervisor = :"research_cli_smoke_#{System.unique_integer([:positive])}"
store = JSONL.new(Path.expand("tmp/cli-smoke-sessions"))

{:ok, prepared} =
  Runtime.prepare(options,
    provider: provider,
    store: store,
    supervisor: supervisor,
    cwd: workspace,
    max_requests: 6,
    max_turns: 6,
    reasoning_effort: effort
  )

catalog = Enum.map(prepared.harness.tools, &Lemieux.Tool.name/1)
true = Enum.all?(~w(web_search web_fetch research_check), &(&1 in catalog))
true = String.contains?(prepared.harness.system, "research_check")

{:ok, session} = Runtime.start(prepared, subscriber: self())
corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()
task = Enum.find(corpus["tasks"], &(&1["id"] == "node-header-removal"))

{micros, finish} =
  :timer.tc(fn ->
    :ok = Session.prompt(session, task["prompt"])

    receive do
      {:lemieux, _, {:finished, reason}} -> reason
    after
      240_000 -> :timeout
    end
  end)

snapshot = Session.snapshot(session)

tool_results =
  for entry <- snapshot.entries, entry.type == :tool_result do
    payload = entry.payload

    %{
      name: payload["name"],
      error: payload["error"],
      outcome: payload["outcome"],
      check: if(payload["name"] == "research_check", do: payload["structured_content"])
    }
  end

answer =
  snapshot.entries
  |> Enum.filter(&(&1.type == :assistant))
  |> List.last()
  |> case do
    nil ->
      nil

    entry ->
      entry.payload
      |> Map.get("content", [])
      |> Enum.map_join("", &(&1["text"] || ""))
  end

report = %{
  task_id: task["id"],
  model: model,
  reasoning_effort: effort,
  elapsed_ms: div(micros, 1_000),
  finish: inspect(finish),
  catalog: catalog,
  tool_results: tool_results,
  answer: answer,
  request_cap: 6
}

encoded = JSON.encode!(report)
true = Enum.all?([brave_key | secrets], &(not String.contains?(encoded, &1)))
File.write!("tmp/cli-smoke-report.json", encoded <> "\n")

IO.puts(
  "finish #{inspect(finish)}; tool calls: " <>
    Enum.join(Enum.map(tool_results, & &1.name), ", ")
)
