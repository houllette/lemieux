# Offline grounding comparison: the research pipeline over locally served
# fixture pages against the same synthesis session asked the bare question.
#
# The "model" is a scripted, deterministic extractive responder: it answers
# with the sentence from the supplied sources that best matches the question
# and cites that source, and it says it cannot answer when no sources were
# supplied. Its answers therefore contain a fact only if the pipeline fetched
# the page carrying it. Expect `grounded-fetch: 5/5` and `model-alone: 0/5`.
# This demonstrates the pipeline's plumbing and grounding check, not any
# model's research quality; see bench/live.exs for the pending live run.

alias Lemieux.Providers.Scripted
alias Lemieux.Tools.WebFetch
alias ResearchExtension.FixtureServer
alias ResearchExtension.Search.Static

defmodule ResearchBench.Extractive do
  @moduledoc false

  @stop ~w(what which does where when how many much long the and for from with that this into
           must into single about does used name a an of to is are by on in it its be)

  def provider, do: Scripted.new([&respond/1])

  def respond(%Lemieux.Request{entries: entries}) do
    text =
      entries
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %{type: :user, payload: %{"text" => text}} -> text
        _entry -> nil
      end)

    {question, sources} = parse(text)
    Scripted.complete(JSON.encode!(answer(question, sources)))
  end

  defp parse(text) do
    case String.split(text, "\nSources:\n\n", parts: 2) do
      [head, blob] -> {question(head), sources(blob)}
      [head] -> {question(head), []}
    end
  end

  defp question(head) do
    case Regex.run(~r/^Question: (.+)$/m, head, capture: :all_but_first) do
      [question] -> question
      nil -> String.trim(head)
    end
  end

  defp sources(blob) do
    ~r/\[S\d+\] URL: (\S+)\n(.*?)(?=\n\n\[S\d+\] URL: |\z)/s
    |> Regex.scan(blob, capture: :all_but_first)
    |> Enum.map(fn [url, body] -> {url, body} end)
  end

  defp answer(_question, []) do
    %{
      "answer" => "No sources were supplied, so this cannot be answered from evidence.",
      "citations" => []
    }
  end

  defp answer(question, sources) do
    keywords = keywords(question)

    {score, sentence, url} =
      sources
      |> Enum.flat_map(fn {url, body} ->
        body
        |> String.split(~r/(?<=[.!?])\s+|\n+/)
        |> Enum.map(&{hits(&1, keywords), String.trim(&1), url})
      end)
      |> Enum.max_by(fn {score, _sentence, _url} -> score end, fn -> {0, "", nil} end)

    if score >= 2 do
      %{"answer" => sentence, "citations" => [url]}
    else
      %{
        "answer" => "The fetched sources do not answer this question.",
        "citations" => Enum.map(sources, fn {url, _body} -> url end)
      }
    end
  end

  defp keywords(question) do
    question
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}\-]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 4 and &1 not in @stop))
    |> Enum.uniq()
  end

  defp hits(sentence, keywords) do
    lowered = String.downcase(sentence)
    Enum.count(keywords, &String.contains?(lowered, &1))
  end
end

{:ok, server} = FixtureServer.start(Path.expand("fixtures/pages", __DIR__))
base = server.base_url

index =
  Static.new([
    %{
      keywords: ~w(tidepool port listen overview network),
      url: base <> "/tidepool-overview.html",
      title: "Tidepool — Overview",
      snippet: "Tidepool is a small message broker."
    },
    %{
      keywords: ~w(tidepool retain retention messages configuration default),
      url: base <> "/tidepool-config.html",
      title: "Tidepool — Configuration",
      snippet: "Every key has a default."
    },
    %{
      keywords: ~w(tidepool release introduced reef compaction version),
      url: base <> "/tidepool-release-notes.html",
      title: "Tidepool — Release notes",
      snippet: "What changed in each release."
    },
    %{
      keywords: ~w(tidepool drain command flag cli),
      url: base <> "/tidepool-cli.html",
      title: "Tidepool — Command line",
      snippet: "Administration commands."
    },
    %{
      keywords: ~w(tidepool maximum size message limits),
      url: base <> "/tidepool-limits.html",
      title: "Tidepool — Limits",
      snippet: "Fixed limits."
    },
    %{
      keywords: ~w(allotment gardening compost tomatoes),
      url: base <> "/allotment-gardening.html",
      title: "Allotment gardening in September",
      snippet: "Lift potatoes and turn the compost."
    }
  ])

sessions_dir = Path.join(System.tmp_dir!(), "research-extension-example-sessions")

model_alone = fn ->
  [
    provider: ResearchBench.Extractive.provider(),
    model: "test:model",
    sessions_dir: sessions_dir,
    session_options: [max_turns: 1]
  ]
end

grounded = fn ->
  [
    provider: ResearchBench.Extractive.provider(),
    model: "test:model",
    sessions_dir: sessions_dir,
    session_options: [max_turns: 1],
    search: {Static, index},
    fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true),
    top_k: 4,
    research_mode: :simple,
    discovery: false
  ]
end

[
  suite: "bench/manifest.json",
  execution: :scripted,
  agents: [
    {"model-alone", ResearchExtension.Baseline, model_alone},
    {"grounded-fetch", ResearchExtension, grounded}
  ],
  benchmark_options: [repetitions: 1, output: "tmp/research-report.json"]
]
