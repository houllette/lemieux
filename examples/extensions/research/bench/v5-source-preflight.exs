alias Lemieux.Tools
alias Lemieux.Tools.WebFetch

corpus = "bench/v5-corpus.json" |> File.read!() |> JSON.decode!()
urls = corpus["tasks"] |> Enum.flat_map(& &1["claims"]) |> Enum.map(& &1["source"]) |> Enum.uniq()
fetch = WebFetch.new(max_body_bytes: 524_288, max_text_chars: 30_000)
File.mkdir_p!("tmp/research-v5-pages")

rows =
  Enum.with_index(urls, 1)
  |> Enum.map(fn {url, index} ->
    receipt =
      Tools.run(
        [fetch],
        [],
        %{id: "source-#{index}", name: "web_fetch", arguments: %{"url" => url}},
        %{
          cwd: File.cwd!(),
          session_id: "v5-preflight",
          call_id: "source-#{index}",
          tool_output_bytes: 100_000
        }
      )

    path = "tmp/research-v5-pages/#{index}.txt"
    if not receipt.error?, do: File.write!(path, receipt.output)

    %{
      "url" => url,
      "path" => path,
      "error" => receipt.error?,
      "bytes" => get_in(receipt, [:structured_content, "bytes"]),
      "truncated" => get_in(receipt, [:structured_content, "truncated"]),
      "text_chars" => String.length(receipt.output),
      "sha256" => Base.encode16(:crypto.hash(:sha256, receipt.output), case: :lower)
    }
  end)

File.write!(
  "tmp/research-v5-source-preflight.json",
  JSON.encode!(%{"rows" => rows, "fetch_calls" => length(rows)})
)

Enum.each(rows, fn row ->
  IO.puts(
    "#{row["url"]}: error=#{row["error"]} chars=#{row["text_chars"]} truncated=#{row["truncated"]}"
  )
end)
