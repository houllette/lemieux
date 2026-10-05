defmodule ResearchExtension.PipelineTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Tools.WebFetch
  alias Lemieux.WebSearch.Backends.Scripted, as: ScriptedSearch
  alias ResearchExtension.FixtureServer
  alias ResearchExtension.Pipeline
  alias ResearchExtension.Search.Static

  @moduletag :tmp_dir
  @pages Path.expand("../bench/fixtures/pages", __DIR__)

  setup %{tmp_dir: tmp_dir} do
    {:ok, server} = FixtureServer.start(@pages)
    on_exit(fn -> FixtureServer.stop(server) end)

    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)

    %{base: server.base_url, workspace: workspace, sessions: Path.join(tmp_dir, "sessions")}
  end

  defp index(base) do
    Static.new([
      %{
        keywords: ~w(tidepool port listen),
        url: base <> "/tidepool-overview.html",
        title: "Overview",
        snippet: "broker"
      },
      %{
        keywords: ~w(tidepool retain messages),
        url: base <> "/tidepool-config.html",
        title: "Configuration",
        snippet: "defaults"
      },
      %{
        keywords: ~w(tidepool release reef),
        url: base <> "/tidepool-release-notes.html",
        title: "Release notes",
        snippet: "changes"
      },
      %{
        keywords: ~w(compost gardening),
        url: base <> "/allotment-gardening.html",
        title: "Gardening",
        snippet: "compost"
      }
    ])
  end

  defp scripted(json), do: Scripted.new([Scripted.complete(json)])

  defp opts(context, overrides) do
    Keyword.merge(
      [
        search: {Static, index(context.base)},
        fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true),
        top_k: 3,
        discovery: false,
        research_mode: :simple,
        cwd: context.workspace,
        timeout_ms: 10_000
      ],
      overrides
    )
  end

  defp session(context, provider),
    do: [provider: provider, model: "test:model", sessions_dir: context.sessions]

  test "answers from fetched pages and cites only fetched URLs", context do
    overview = context.base <> "/tidepool-overview.html"

    provider =
      scripted(
        JSON.encode!(%{
          "answer" => "Tidepool listens on TCP port 7433 by default.",
          "citations" => [overview]
        })
      )

    assert {:ok, result} =
             Pipeline.run(
               "What TCP port does Tidepool listen on by default?",
               opts(context, session: session(context, provider))
             )

    assert result.answer == "Tidepool listens on TCP port 7433 by default."
    assert result.citations == [overview]
    assert result.skipped == []

    assert [%{url: ^overview, truncated?: false, bytes: bytes} | _rest] = result.fetched
    assert bytes > 0
    assert length(result.fetched) == 3
    assert result.session["status"] == "completed"
    assert result.session["tool_metrics"]["requests"] == 1
    assert result.session["tool_metrics"]["calls"] == 0

    [request] = Scripted.requests(provider)

    assert request.output_schema == %{
             "type" => "object",
             "properties" => %{
               "answer" => %{"type" => "string"},
               "citations" => %{"type" => "array", "items" => %{"type" => "string"}}
             },
             "required" => ["answer", "citations"],
             "additionalProperties" => false
           }

    prompt =
      request.entries
      |> Enum.reverse()
      |> Enum.find(&(&1.type == :user))
      |> then(& &1.payload["text"])

    assert prompt =~ "Question: What TCP port does Tidepool listen on by default?"
    assert prompt =~ "[S1] URL: #{overview}"
    assert prompt =~ "Tidepool listens on TCP port 7433 by default."
    assert prompt =~ "untrusted"
    refute prompt =~ "Ignore previous instructions"
  end

  test "rejects a citation to a URL that was not fetched", context do
    provider =
      scripted(
        JSON.encode!(%{
          "answer" => "Port 7433.",
          "citations" => [
            context.base <> "/tidepool-overview.html",
            "https://example.com/elsewhere"
          ]
        })
      )

    assert {:error, {:unfetched_citation, "https://example.com/elsewhere"}, partial} =
             Pipeline.run("Tidepool port", opts(context, session: session(context, provider)))

    assert length(partial.fetched) == 3
    assert partial.raw_answer =~ "elsewhere"
    assert partial.session["status"] == "completed"
  end

  test "rejects an answer that cites nothing", context do
    provider = scripted(JSON.encode!(%{"answer" => "Probably 7433.", "citations" => []}))

    assert {:error, :uncited_answer, partial} =
             Pipeline.run("Tidepool port", opts(context, session: session(context, provider)))

    assert partial.fetched != []
  end

  test "rejects synthesis output that is not the JSON contract", context do
    provider = scripted("7433, I think.")

    assert {:error, :malformed_synthesis, %{raw_answer: "7433, I think."}} =
             Pipeline.run("Tidepool port", opts(context, session: session(context, provider)))
  end

  test "accepts a fenced JSON reply", context do
    overview = context.base <> "/tidepool-overview.html"
    json = JSON.encode!(%{"answer" => "7433", "citations" => [overview]})
    provider = scripted("```json\n" <> json <> "\n```")

    assert {:ok, %{answer: "7433"}} =
             Pipeline.run("Tidepool port", opts(context, session: session(context, provider)))
  end

  test "flags a page over the per-page cap and stops at the total budget", context do
    notes = context.base <> "/tidepool-release-notes.html"
    overview = context.base <> "/tidepool-overview.html"
    config = context.base <> "/tidepool-config.html"
    provider = scripted(JSON.encode!(%{"answer" => "3.4.0", "citations" => [notes]}))

    assert {:ok, result} =
             Pipeline.run(
               "Which tidepool release introduced reef?",
               opts(context,
                 fetch:
                   WebFetch.new(unsafe_allow_loopback_for_tests: true, max_body_bytes: 1_024),
                 max_total_bytes: 2_100,
                 session: session(context, provider)
               )
             )

    assert [
             %{url: ^notes, bytes: 1_024, truncated?: true},
             %{url: ^overview, bytes: 1_024, truncated?: true}
           ] = result.fetched

    assert [%{url: ^config, reason: reason}] = result.skipped
    assert reason =~ "total fetch budget of 2100 bytes"
  end

  test "reports a search backend error and an empty result set", context do
    failing = ScriptedSearch.new([{:error, "quota exhausted"}])

    assert {:error, {:search, message}} =
             Pipeline.run("anything", opts(context, search: {ScriptedSearch, failing}))

    assert message =~ "quota exhausted"

    empty = ScriptedSearch.new([{:ok, [], %{}}])

    assert {:error, :no_results} =
             Pipeline.run("anything", opts(context, search: {ScriptedSearch, empty}))
  end

  test "bounds a long research question before sending it to a search backend", context do
    backend = ScriptedSearch.new([{:ok, [], %{}}])
    question = "PostgreSQL migration " <> String.duplicate("output plugin ", 40)

    assert {:error, :no_results} =
             Pipeline.run(question, opts(context, search: {ScriptedSearch, backend}))

    assert [{query, _options}] = ScriptedSearch.requests(backend)
    assert length(String.split(query)) == 45
    assert String.length(query) <= 400
    assert String.starts_with?(query, "PostgreSQL migration output plugin")
  end

  test "balanced query retains late qualifiers within the adapter cap" do
    question =
      "Go 1.27 migration " <>
        String.duplicate("generic methods compatibility ", 20) <>
        "but check the late goroutineleakprofile removal and SIMD opt-in"

    leading = Pipeline.query(question, :leading)
    balanced = Pipeline.query(question, :balanced)

    refute leading =~ "goroutineleakprofile"
    assert balanced =~ "goroutineleakprofile"
    assert balanced =~ "Go 1.27 migration"
    assert length(String.split(balanced)) <= 45
    assert String.length(balanced) <= 400
  end

  test "balanced query option reaches the search backend", context do
    backend = ScriptedSearch.new([{:ok, [], %{}}])

    question =
      "Go 1.27 migration " <>
        String.duplicate("generic methods compatibility ", 20) <>
        "but check the late goroutineleakprofile removal"

    assert {:error, :no_results} =
             Pipeline.run(
               question,
               opts(context, search: {ScriptedSearch, backend}, query_strategy: :balanced)
             )

    assert [{query, _options}] = ScriptedSearch.requests(backend)
    assert query =~ "goroutineleakprofile"
  end

  test "a page the fetch tool refuses is skipped with its reason, not fatal", context do
    overview = context.base <> "/tidepool-overview.html"

    search =
      Static.new([
        %{keywords: ~w(tidepool), url: "http://10.0.0.1/secret", title: "Internal", snippet: "x"},
        %{keywords: ~w(tidepool), url: overview, title: "Overview", snippet: "broker"}
      ])

    provider = scripted(JSON.encode!(%{"answer" => "7433", "citations" => [overview]}))

    assert {:ok, result} =
             Pipeline.run(
               "tidepool port",
               opts(context, search: {Static, search}, session: session(context, provider))
             )

    assert [%{url: "http://10.0.0.1/secret", reason: reason}] = result.skipped
    assert reason =~ "private address"
    assert [%{url: ^overview}] = result.fetched
  end

  test "fetching nothing at all is an error that keeps the skip reasons", context do
    search =
      Static.new([
        %{keywords: ~w(tidepool), url: "http://10.0.0.1/secret", title: "Internal", snippet: "x"}
      ])

    assert {:error, :nothing_fetched, %{fetched: [], skipped: [%{reason: reason}]}} =
             Pipeline.run("tidepool", opts(context, search: {Static, search}))

    assert reason =~ "private address"
  end

  test "hooks apply to the pipeline's search and fetch calls", context do
    hooks = [before_tool_call: fn _call, _context -> {:deny, "no network in this sandbox"} end]

    assert {:error, {:search, message}} = Pipeline.run("tidepool", opts(context, hooks: hooks))
    assert message =~ "denied: no network in this sandbox"
  end

  test "the agent entry point returns completed and failed observations", context do
    overview = context.base <> "/tidepool-overview.html"

    input = %{
      prompt: "What TCP port does Tidepool listen on by default?",
      cwd: context.workspace,
      timeout_ms: 10_000
    }

    good = scripted(JSON.encode!(%{"answer" => "Port 7433.", "citations" => [overview]}))

    assert {:ok, observation} =
             Lemieux.Agent.run(
               ResearchExtension,
               input,
               session(context, good) ++
                 [
                   discovery: false,
                   research_mode: :simple,
                   search: {Static, index(context.base)},
                   fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true)
                 ]
             )

    assert observation["status"] == "completed"
    assert observation["answer"] == "Port 7433."
    assert observation["citations"] == [overview]

    assert [%{"url" => ^overview, "bytes" => _bytes, "truncated" => false} | _rest] =
             observation["fetched"]

    assert observation["skipped"] == []
    assert observation["tool_metrics"]["requests"] == 1

    bad =
      scripted(
        JSON.encode!(%{"answer" => "Port 7433.", "citations" => ["https://example.com/made-up"]})
      )

    assert {:error, {:unfetched_citation, "https://example.com/made-up"}, failed} =
             Lemieux.Agent.run(
               ResearchExtension,
               input,
               session(context, bad) ++
                 [
                   discovery: false,
                   research_mode: :simple,
                   search: {Static, index(context.base)},
                   fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true)
                 ]
             )

    assert failed["status"] == "failed"
    assert failed["answer"] == ""
    assert failed["reason"] =~ "unfetched_citation"
    assert length(failed["fetched"]) == 3
  end

  test "the static backend ranks by keyword overlap and honours the result limit" do
    index =
      Static.new([
        %{keywords: ~w(Alpha beta), url: "https://a.example/", title: "A", snippet: "a"},
        %{keywords: ~w(beta gamma delta), url: "https://b.example/", title: "B", snippet: "b"},
        %{keywords: ~w(omega), url: "https://c.example/", title: "C", snippet: "c"}
      ])

    assert {:ok, results, %{"provider" => "static"}} =
             Static.search(index, "Beta and gamma, delta?", max_results: 5)

    assert Enum.map(results, & &1.url) == ["https://b.example/", "https://a.example/"]

    assert {:ok, [%{url: "https://b.example/"}], _usage} =
             Static.search(index, "gamma beta", max_results: 1)

    assert {:ok, [], _usage} = Static.search(index, "nothing relevant", max_results: 5)

    assert_raise ArgumentError, fn ->
      Static.new([%{keywords: [], url: "x", title: "t", snippet: "s"}])
    end
  end

  test "the pipeline rejects unusable configuration", context do
    assert_raise ArgumentError, ~r/:fetch/, fn ->
      Pipeline.run("q", opts(context, fetch: :not_a_tool))
    end

    assert_raise ArgumentError, ~r/:top_k/, fn -> Pipeline.run("q", opts(context, top_k: 0)) end
  end
end
