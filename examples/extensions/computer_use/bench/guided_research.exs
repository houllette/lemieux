# Run from this example to reuse its explicit env-file loader with research.
# Discovery selects its default hosted classifier from the configured key.
{options, rest, invalid} =
  OptionParser.parse(System.argv(),
    strict: [execute: :boolean, env_file: :string, question: :string]
  )

if rest != [] or invalid != [] or options[:execute] != true,
  do:
    Mix.raise(
      "Explicit --execute is required: one Brave search, at most three Jev calls, three HTTP fetches and one configured synthesis request"
    )

:ok = Mix.Tasks.Lmx.Browser.load_env(options[:env_file])

for file <- ["jev.ex", "discovery.ex", "pipeline.ex"],
    do: Code.require_file("../research/lib/research_extension/" <> file)

alias Lemieux.CLI.{Config, Options, Runtime}
alias Lemieux.Extensions.Web.Brave
alias ResearchExtension.Pipeline

{:ok, host_options} =
  Options.parse(["--config", Config.default_path(), "--no-project-mcp", "--no-delegate"])

host_options = %{
  host_options
  | config: %{
      host_options.config
      | settings: Map.delete(host_options.config.settings, "jev_compaction")
    }
}

{:ok, prepared} = Runtime.prepare(host_options, tools: [])
{:ok, _} = Runtime.mount([])

question =
  options[:question] ||
    "Which transport does ReqLLM streaming use, why don't prepare_request/attach hooks cover streaming, and which native telemetry covers both streaming and ordinary requests?"

backend = Brave.new(api_key: System.fetch_env!("BRAVE_SEARCH_API_KEY"))
File.mkdir_p!("/tmp/lemieux-guided-research")

{micros, result} =
  :timer.tc(fn ->
    Pipeline.run(question,
      search: {Brave, backend},
      fetch: Lemieux.Tools.WebFetch.new(max_body_bytes: 131_072, max_text_chars: 30_000),
      top_k: 3,
      research_mode: :simple,
      max_total_bytes: 393_216,
      timeout_ms: 60_000,
      cwd: "/tmp/lemieux-guided-research",
      discovery: [candidate_limit: 5, max_depth: 1],
      session: [
        provider: prepared.options[:provider],
        model: prepared.model,
        supervisor: Lemieux.Supervisor,
        sessions_dir: "/tmp/lemieux-guided-research-sessions",
        session_options: [max_requests: 1]
      ]
    )
  end)

summary =
  case result do
    {:ok, value} ->
      %{
        status: "completed",
        question: question,
        answer: value.answer,
        citations: value.citations,
        fetched: value.fetched,
        skipped: value.skipped,
        discovery: value.discovery,
        model: prepared.model,
        synthesis_usage: value.session["usage"]
      }

    {:error, reason, partial} ->
      %{
        status: "failed",
        reason: inspect(reason),
        question: question,
        fetched: partial.fetched,
        skipped: partial.skipped,
        discovery: partial.discovery
      }

    {:error, reason} ->
      %{status: "failed", reason: inspect(reason), question: question}
  end

IO.puts(JSON.encode!(Map.put(summary, :elapsed_ms, div(micros, 1000))))
