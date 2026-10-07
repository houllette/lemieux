# Frozen four-arm live benchmark. Model and effort match across all arms.
System.put_env("RESEARCH_V5_CORPUS", Path.expand("bench/v5-corpus.json"))
{:ok, _apps} = Application.ensure_all_started(:req_llm)

Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.Extensions.Web.Brave
alias Lemieux.Tools.WebFetch
alias Lemieux.Tools.WebSearch
alias ResearchBench.LiveSetup

config = LiveSetup.config()
brave_key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")

jev_key =
  System.get_env("JEV_API_KEY") ||
    get_in(Config.get(config, "systemone_compaction_providers", %{}), ["typesafe", "api_key"])

for {name, value} <- [{"Brave", brave_key}, {"Jev", jev_key}] do
  unless is_binary(value) and value != "", do: raise("v5 benchmark needs a #{name} key")
end

# RESEARCH_MODEL and RESEARCH_EFFORT; see live_setup.exs.
%{model: model, effort: effort, provider: provider} =
  LiveSetup.model(config, receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5))

brave = Brave.new(api_key: brave_key)
fetch = WebFetch.new(max_body_bytes: 524_288, max_text_chars: 30_000)

base = fn ->
  [
    provider: provider,
    model: model,
    sessions_dir: Path.join(System.tmp_dir!(), "research-extension-v5-sessions"),
    session_options: [max_turns: 1, max_requests: 1, reasoning_effort: effort]
  ]
end

pipeline = fn discovery ->
  base.() ++
    [
      search: {Brave, brave},
      fetch: fetch,
      top_k: 6,
      research_mode: :simple,
      max_total_bytes: 2_097_152,
      discovery: discovery
    ]
end

[
  suite: "bench/v5-balanced-manifest.json",
  execution: :live,
  agents: [
    {"one-search-balanced", ResearchExtension,
     fn -> Keyword.put(pipeline.(false), :query_strategy, :balanced) end}
  ],
  benchmark_options: [
    repetitions: 1,
    max_concurrency: 1,
    output: "tmp/research-v5-balanced-report.json"
  ]
]
