# Paired retrieval-only follow-up. Leading rows come from the frozen preflight.
Code.require_file("live_setup.exs", __DIR__)

alias Lemieux.CLI.Config
alias Lemieux.Extensions.Web.Brave
alias ResearchExtension.Pipeline

config = ResearchBench.LiveSetup.config()
key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")
backend = Brave.new(api_key: key)
corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()
leading = "tmp/research-v5-preflight.json" |> File.read!() |> JSON.decode!()
leading_by_id = Map.new(leading["rows"], &{&1["id"], &1})

rows =
  Enum.map(corpus["tasks"], fn task ->
    gold = task["claims"] |> Enum.map(& &1["source"]) |> Enum.uniq()
    original = leading_by_id[task["id"]]
    query = Pipeline.query(task["prompt"], :balanced)

    case Brave.search(backend, query, max_results: 6) do
      {:ok, hits, _usage} ->
        urls = Enum.map(hits, & &1.url)

        %{
          "id" => task["id"],
          "leading_query" => original["query"],
          "balanced_query" => query,
          "leading_urls" => original["top_six"],
          "balanced_urls" => urls,
          "leading_gold_missing" => length(gold -- original["top_six"]),
          "balanced_gold_missing" => gold -- urls
        }

      {:error, reason} ->
        %{"id" => task["id"], "balanced_query" => query, "error" => reason}
    end
  end)

File.write!(
  "tmp/research-v5-query-comparison.json",
  JSON.encode!(%{"rows" => rows, "new_brave_calls" => length(rows)})
)

Enum.each(rows, fn row ->
  IO.puts(
    "#{row["id"]}: leading_missing=#{row["leading_gold_missing"]} balanced_missing=#{length(row["balanced_gold_missing"] || [])} error=#{inspect(row["error"])}"
  )
end)
