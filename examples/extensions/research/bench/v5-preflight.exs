# Read-only corpus retrieval preflight. Run before the first model attempt.
Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.Extensions.Web.Brave
alias ResearchExtension.Pipeline

config = ResearchBench.LiveSetup.config()
key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")
backend = Brave.new(api_key: key)
corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()

rows =
  Enum.map(corpus["tasks"], fn task ->
    query = Pipeline.query(task["prompt"], :leading)

    case Brave.search(backend, query, max_results: 6) do
      {:ok, hits, _usage} ->
        urls = Enum.map(hits, & &1.url)
        gold = task["claims"] |> Enum.map(& &1["source"]) |> Enum.uniq()
        %{"id" => task["id"], "query" => query, "top_six" => urls, "gold_missing" => gold -- urls}

      {:error, reason} ->
        %{"id" => task["id"], "query" => query, "error" => reason}
    end
  end)

File.mkdir_p!("tmp")

File.write!(
  "tmp/research-v5-preflight.json",
  JSON.encode!(%{"rows" => rows, "brave_calls" => length(rows)})
)

Enum.each(rows, fn row ->
  IO.puts(
    "#{row["id"]}: #{length(row["gold_missing"] || [])} gold URLs absent; error=#{inspect(row["error"])}"
  )
end)
