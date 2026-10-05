# Fetch citation pages absent from the frozen designated-source snapshots.
alias Lemieux.Tools
alias Lemieux.Tools.WebFetch
ledger = "tmp/research-v5-ledger.json" |> File.read!() |> JSON.decode!()
source = "tmp/research-v5-source-preflight.json" |> File.read!() |> JSON.decode!()
have = MapSet.new(Enum.map(source["rows"], & &1["url"]))

urls =
  ledger
  |> Enum.flat_map(& &1["citations"])
  |> Enum.uniq()
  |> Enum.reject(&MapSet.member?(have, &1))

fetch = WebFetch.new(max_body_bytes: 524_288, max_text_chars: 30_000)
File.mkdir_p!("tmp/research-v5-audit-pages")

rows =
  Enum.with_index(urls, 1)
  |> Enum.map(fn {url, index} ->
    receipt =
      Tools.run(
        [fetch],
        [],
        %{id: "audit-#{index}", name: "web_fetch", arguments: %{"url" => url}},
        %{
          cwd: File.cwd!(),
          session_id: "v5-audit",
          call_id: "audit-#{index}",
          tool_output_bytes: 140_000
        }
      )

    path = "tmp/research-v5-audit-pages/#{index}.txt"
    if not receipt.error?, do: File.write!(path, receipt.output)

    %{
      "url" => url,
      "path" => path,
      "error" => receipt.error?,
      "bytes" => get_in(receipt, [:structured_content, "bytes"]),
      "truncated" => get_in(receipt, [:structured_content, "truncated"]),
      "sha256" => Base.encode16(:crypto.hash(:sha256, receipt.output), case: :lower)
    }
  end)

File.write!(
  "tmp/research-v5-audit-fetch.json",
  JSON.encode!(%{"rows" => rows, "fetch_calls" => length(rows)})
)

Enum.each(rows, fn row ->
  IO.puts("#{row["url"]}: error=#{row["error"]} truncated=#{row["truncated"]}")
end)
