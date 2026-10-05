defmodule ResearchExtension.Search.Static do
  @moduledoc """
  A `Lemieux.WebSearch.Backend` over a fixed index, for offline tests and
  benches.

  Each entry names the keywords it answers to and the result it stands for.
  A query is tokenized and every entry scored by how many of its keywords the
  query contains; entries that match nothing are dropped, the rest are ranked
  by score (ties keep index order) and cut to `max_results`. The ranking is
  deliberately simple: this backend exists so the pipeline can be exercised
  against local fixture pages without a search key, not to be a search engine.
  """

  @behaviour Lemieux.WebSearch.Backend

  alias Lemieux.WebSearch.Result

  @typedoc "One indexed page: the keywords that select it and the result returned for it."
  @type entry :: %{
          keywords: [String.t()],
          url: String.t(),
          title: String.t(),
          snippet: String.t()
        }

  @doc "Validates an index; the returned list is the backend state."
  @spec new(entries :: [entry()]) :: [entry()]
  def new(entries) when is_list(entries) do
    Enum.each(entries, fn entry ->
      unless match?(
               %{keywords: [_ | _], url: url, title: title, snippet: snippet}
               when is_binary(url) and is_binary(title) and is_binary(snippet),
               entry
             ),
             do: raise(ArgumentError, "invalid static search entry: #{inspect(entry)}")
    end)

    Enum.map(entries, fn entry ->
      Map.update!(entry, :keywords, fn words -> Enum.map(words, &String.downcase/1) end)
    end)
  end

  @impl Lemieux.WebSearch.Backend
  def search(entries, query, opts) when is_list(entries) and is_binary(query) do
    tokens = query |> tokens() |> MapSet.new()
    limit = Keyword.get(opts, :max_results, 5)

    results =
      entries
      |> Enum.map(fn entry ->
        {Enum.count(entry.keywords, &MapSet.member?(tokens, &1)), entry}
      end)
      |> Enum.reject(fn {score, _entry} -> score == 0 end)
      |> Enum.sort_by(fn {score, _entry} -> -score end)
      |> Enum.take(limit)
      |> Enum.map(fn {_score, entry} ->
        %Result{title: entry.title, url: entry.url, snippet: entry.snippet}
      end)

    {:ok, results, %{"provider" => "static", "requests" => 1, "cost_usd" => 0}}
  end

  defp tokens(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}\-]+/u, trim: true)
  end
end
