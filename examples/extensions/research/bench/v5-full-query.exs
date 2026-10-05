# Diagnostic only: compare full 600-char/75-word queries against adapter-capped
# leading/balanced queries. The runtime backend/tool caps are unchanged.
Code.require_file("live_setup.exs", __DIR__)
alias Lemieux.CLI.Config
config = ResearchBench.LiveSetup.config()
key = System.get_env("BRAVE_SEARCH_API_KEY") || Config.web_search_api_key(config, "brave")
corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()

rows =
  Enum.map(corpus["tasks"], fn task ->
    query = task["prompt"]
    true = String.length(query) <= 600 and length(String.split(query)) <= 75

    response =
      Req.get(
        url: "https://api.search.brave.com/res/v1/web/search",
        headers: [{"accept", "application/json"}, {"x-subscription-token", key}],
        params: [
          q: query,
          count: 6,
          result_filter: "web",
          text_decorations: false,
          safesearch: "moderate"
        ],
        receive_timeout: 20_000,
        retry: false,
        redirect: false
      )

    case response do
      {:ok, %Req.Response{status: 200, body: body}} ->
        results = get_in(body, ["web", "results"]) || []
        urls = Enum.map(results, & &1["url"])
        gold = task["claims"] |> Enum.map(& &1["source"]) |> Enum.uniq()
        %{"id" => task["id"], "query" => query, "top_six" => urls, "gold_missing" => gold -- urls}

      {:ok, %Req.Response{status: status}} ->
        %{"id" => task["id"], "error" => "HTTP #{status}"}

      {:error, _} ->
        %{"id" => task["id"], "error" => "transport error"}
    end
  end)

File.write!(
  "tmp/research-v5-full-query.json",
  JSON.encode!(%{"rows" => rows, "brave_calls" => length(rows)})
)

Enum.each(rows, fn row ->
  IO.puts(
    "#{row["id"]}: missing=#{length(row["gold_missing"] || [])} error=#{inspect(row["error"])}"
  )
end)
