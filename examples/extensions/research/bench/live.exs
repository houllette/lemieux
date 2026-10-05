# Paired real-web research comparison. The offline bench in compare.exs uses a
# scripted responder. This run spends Brave quota and model tokens: four
# tasks, two arms, one model request per attempt, serial execution. The model
# comes from live_setup.exs (RESEARCH_MODEL; by default an Ixway route). An
# Ixway route cannot price a request before routing it, so dollar
# caps would reject the run instead of limiting it; the bound is the request
# count, and the provider's or gateway's own budget remains authoritative.

{:ok, _apps} = Application.ensure_all_started(:req_llm)

Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.Extensions.Web.Brave
alias Lemieux.Tools.WebFetch
alias ResearchBench.LiveSetup

config = LiveSetup.config()
brave_key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")

unless is_binary(brave_key) and brave_key != "", do: raise("bench/live.exs needs a Brave key")

%{model: model, effort: effort, provider: provider} =
  LiveSetup.model(config, receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5))

brave = Brave.new(api_key: brave_key)
sessions_dir = Path.join(System.tmp_dir!(), "research-extension-live-sessions")

base = fn ->
  [
    provider: provider,
    model: model,
    sessions_dir: sessions_dir,
    session_options: [max_turns: 1, max_requests: 1, reasoning_effort: effort]
  ]
end

[
  suite: "bench/live-manifest.json",
  execution: :live,
  agents: [
    {"model-alone", ResearchExtension.Baseline, base},
    {"grounded-fetch", ResearchExtension,
     fn ->
       base.() ++
         [
           search: {Brave, brave},
           fetch: WebFetch.new(),
           top_k: 4,
           research_mode: :simple,
           discovery: false
         ]
     end}
  ],
  benchmark_options: [
    repetitions: 1,
    max_concurrency: 1,
    output: "tmp/research-live-report.json"
  ]
]
