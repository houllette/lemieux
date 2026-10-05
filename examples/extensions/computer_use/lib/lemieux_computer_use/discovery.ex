defmodule LemieuxComputerUse.Discovery do
  @moduledoc """
  A bounded breadth-first crawl over the existing guarded public fetch tool.
  Site knowledge guides classification but never becomes a browser selector.
  Attempts, depth, response bytes and model-visible excerpts have separate caps.
  """
  alias Lemieux.Tools
  alias Lemieux.Tools.WebFetch

  @spec crawl(url :: String.t(), opts :: keyword(), context :: map()) :: map()
  def crawl(url, opts, context) do
    count = Keyword.get(opts, :crawl_pages, 3)
    fetch = Keyword.get(opts, :fetch, WebFetch.new(max_body_bytes: 262_144, max_text_chars: 4000))

    state = %{
      pages: [],
      calls: [],
      seen: MapSet.new(),
      remaining: Keyword.get(opts, :crawl_bytes, 524_288)
    }

    walk([{url, 0}], URI.parse(url).host, count, state, fetch, opts, context)
  end

  defp walk([], _, _, state, _, _, _), do: result(state)

  defp walk(_, _, count, state, _, _, _) when count <= 0 or state.remaining <= 0,
    do: result(state)

  defp walk([{url, depth} | rest], host, count, state, fetch, opts, context) do
    if MapSet.member?(state.seen, url) do
      walk(rest, host, count, state, fetch, opts, context)
    else
      tool = %{fetch | max_body_bytes: min(fetch.max_body_bytes, state.remaining)}
      tool = LemieuxComputerUse.Fetch.new(tool, opts)

      call = %{
        id: "#{Map.get(context, :call_id, "browser")}-crawl-#{count}",
        name: "web_fetch",
        arguments: %{"url" => url}
      }

      receipt =
        Tools.run([tool], Map.get(context, :hooks, []), call, Map.put(context, :call_id, call.id))

      evidence = Map.get(receipt, :structured_content, %{})
      bytes = Map.get(evidence, "bytes", 0)

      state = %{
        state
        | seen: MapSet.put(state.seen, url),
          remaining: state.remaining - bytes,
          calls:
            state.calls ++
              [
                %{
                  "url" => url,
                  "error" => receipt.error?,
                  "outcome" => to_string(receipt.outcome),
                  "source" => evidence["source"],
                  "rendered_bytes" => evidence["rendered_bytes"],
                  "bytes" => bytes
                }
              ]
      }

      {state, links} = page(state, receipt, evidence, depth, host, opts)
      walk(rest ++ links, host, count - 1, state, fetch, opts, context)
    end
  end

  defp page(state, %{error?: true}, _, _, _, _), do: {state, []}

  defp page(state, receipt, evidence, depth, host, opts) do
    text = evidence["text"] || receipt.output

    page = %{
      "url" => evidence["url"],
      "title" => evidence["title"],
      "text" => String.slice(text, 0, 2000),
      "source" => evidence["source"],
      "truncated" => evidence["truncated"] || String.length(text) > 2000
    }

    links =
      if depth < Keyword.get(opts, :crawl_depth, 1) do
        (evidence["links"] || [])
        |> Enum.filter(&(URI.parse(&1).host == host))
        |> Enum.map(fn link -> {URI.to_string(%{URI.parse(link) | fragment: nil}), depth + 1} end)
      else
        []
      end

    {%{state | pages: state.pages ++ [page]}, links}
  end

  defp result(state), do: %{"pages" => state.pages, "requests" => state.calls}
end
