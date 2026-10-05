# One attended qualification of the current claim-led default, not a campaign.
unless System.argv() == ["--execute"], do: raise("pass --execute to run live research")

{:ok, _apps} = Application.ensure_all_started(:req_llm)

Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.Extensions.Web.Brave
alias Lemieux.Tools.WebFetch
alias ResearchBench.LiveSetup

config = LiveSetup.config()
brave_key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")
unless is_binary(brave_key) and brave_key != "", do: raise("missing Brave key")

# RESEARCH_MODEL and RESEARCH_EFFORT; see live_setup.exs.
%{model: model, effort: effort, provider: provider, secrets: secrets} =
  LiveSetup.model(config, receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5))

corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()
task = Enum.find(corpus["tasks"], &(&1["id"] == "node-header-removal"))
workspace = Path.expand("tmp/deep-smoke-workspace")
File.mkdir_p!(workspace)

input = %{prompt: task["prompt"], cwd: workspace, timeout_ms: 240_000}

opts = [
  provider: provider,
  model: model,
  sessions_dir: Path.expand("tmp/deep-smoke-sessions"),
  session_options: [reasoning_effort: effort],
  search: {Brave, Brave.new(api_key: brave_key)},
  fetch: WebFetch.new(max_body_bytes: 524_288, max_text_chars: 30_000),
  top_k: 4,
  max_total_bytes: 2_097_152
]

{micros, result} = :timer.tc(fn -> Lemieux.Agent.run(ResearchExtension, input, opts) end)

report = %{
  task_id: task["id"],
  model: model,
  reasoning_effort: effort,
  elapsed_ms: div(micros, 1_000),
  result:
    case result do
      {:ok, observation} ->
        %{status: "completed", observation: observation}

      {:error, reason, observation} ->
        %{status: "incomplete", reason: inspect(reason), observation: observation}

      {:error, reason} ->
        %{status: "failed", reason: inspect(reason)}
    end
}

encoded = JSON.encode!(report)
true = Enum.all?([brave_key | secrets], &(not String.contains?(encoded, &1)))
File.write!("tmp/deep-smoke-report.json", encoded <> "\n")

case result do
  {:ok, observation} ->
    IO.puts(
      "completed: #{length(observation["claims"] || [])} claims, " <>
        "#{length(observation["fetched"] || [])} pages, " <>
        "#{observation["discovery"]["searches"]} searches"
    )

  {:error, reason, observation} ->
    IO.puts(
      "incomplete: #{inspect(reason)}, #{length(observation["fetched"] || [])} pages, " <>
        "#{inspect(observation["discovery"])}"
    )

  {:error, reason} ->
    IO.puts("failed before fetch: #{inspect(reason)}")
end
