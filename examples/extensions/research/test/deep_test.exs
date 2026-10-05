defmodule ResearchExtension.DeepTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.WebFetch
  alias Lemieux.WebSearch.Backends.Scripted, as: Search
  alias Lemieux.WebSearch.Result
  alias ResearchExtension.FixtureServer
  alias ResearchExtension.Pipeline

  @moduletag :tmp_dir
  @pages Path.expand("../bench/fixtures/pages", __DIR__)

  setup %{tmp_dir: dir} do
    {:ok, server} = FixtureServer.start(@pages)
    on_exit(fn -> FixtureServer.stop(server) end)

    %{base: server.base_url, cwd: dir}
  end

  defp row(url), do: %Result{url: url, title: "Fixture source", snippet: "Tidepool documentation"}

  defp plan do
    %{
      "initial_query" => "Tidepool default TCP port",
      "facts" => [
        %{"need" => "Default TCP port", "query" => "Tidepool default TCP port 7433"},
        %{"need" => "Default message retention", "query" => "Tidepool default retention 72 hours"}
      ]
    }
  end

  defp options(context, search, overrides) do
    Keyword.merge(
      [
        search: {Search, search},
        fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true),
        discovery: false,
        cwd: context.cwd,
        plan: fn _question -> {:ok, plan()} end
      ],
      overrides
    )
  end

  test "the default pipeline searches an uncovered fact and verifies one fetched passage per claim",
       context do
    overview = context.base <> "/tidepool-overview.html"
    config = context.base <> "/tidepool-config.html"

    search =
      Search.new([
        {:ok, [row(overview)], %{}},
        {:ok, [row(config)], %{}}
      ])

    compose = fn _question, _facts, pages ->
      claims = [
        %{
          "id" => "C1",
          "answer" => "Tidepool listens on port 7433 by default.",
          "citation" => overview,
          "passage" => "Tidepool listens on TCP port 7433 by default."
        }
      ]

      if length(pages) == 2 do
        {:ok,
         %{
           "claims" =>
             claims ++
               [
                 %{
                   "id" => "C2",
                   "answer" => "Messages are retained for 72 hours by default.",
                   "citation" => config,
                   "passage" =>
                     "By default Tidepool retains messages for 72 hours before they are compacted away."
                 }
               ]
         }}
      else
        {:ok, %{"claims" => claims}}
      end
    end

    assert {:ok, result} =
             Pipeline.run(
               "What are Tidepool's default port and retention?",
               options(context, search, compose: compose)
             )

    assert result.answer =~ "7433"
    assert result.answer =~ "72 hours"
    assert result.citations == [overview, config]
    assert Enum.map(result.claims, & &1.id) == ["C1", "C2"]
    assert result.discovery == %{searches: 2, fetch_attempts: 2, model_requests: 0}

    assert Enum.map(Search.requests(search), &elem(&1, 0)) == [
             "Tidepool default TCP port",
             "Tidepool default retention 72 hours"
           ]
  end

  test "a fetched URL with an unrelated passage cannot satisfy a planned fact", context do
    overview = context.base <> "/tidepool-overview.html"
    search = Search.new([{:ok, [row(overview)], %{}}, {:ok, [row(overview)], %{}}])

    compose = fn _question, _facts, _pages ->
      {:ok,
       %{
         "claims" => [
           %{
             "id" => "C1",
             "answer" => "Tidepool listens on port 7433.",
             "citation" => overview,
             "passage" => "Tidepool listens on TCP port 7433 by default."
           },
           %{
             "id" => "C2",
             "answer" => "Messages are retained for 72 hours.",
             "citation" => overview,
             "passage" => "Messages are retained for 72 hours by default."
           }
         ]
       }}
    end

    assert {:error, {:incomplete_evidence, ["C2"]}, partial} =
             Pipeline.run("Tidepool defaults", options(context, search, compose: compose))

    assert length(partial.fetched) == 1
    assert partial.discovery.searches == 2
  end

  test "an invalid plan stops before spending search quota", context do
    search = Search.new([])
    invalid = Map.put(plan(), "initial_query", String.duplicate("a", 401))

    assert {:error, {:research_plan, :invalid_fact_or_query}} =
             Pipeline.run(
               "Tidepool defaults",
               options(context, search, plan: fn _ -> {:ok, invalid} end)
             )

    assert Search.requests(search) == []
  end
end
