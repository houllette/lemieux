defmodule ResearchExtension.DiscoveryTest do
  use ExUnit.Case, async: true
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tools.WebFetch
  alias ResearchExtension.{FixtureServer, Pipeline, Search.Static}
  @moduletag :tmp_dir

  setup %{tmp_dir: path} do
    File.write!(
      Path.join(path, "index.html"),
      "<main><h1>Official Tidepool documentation</h1><a href='guide.html'>Operations guide</a><a href='guide.html#drain'>Drain</a><a href='http://10.0.0.1/secret'>Private</a></main>"
    )

    File.write!(
      Path.join(path, "guide.html"),
      "<main>Tidepool retains messages for 72 hours. Drain requires --confirm.</main>"
    )

    File.write!(
      Path.join(path, "junk.html"),
      "<main>Third-party overview without operational details.</main>"
    )

    {:ok, server} = FixtureServer.start(path)
    on_exit(fn -> FixtureServer.stop(server) end)

    search =
      Static.new(
        Enum.map(
          ["junk", "index"],
          &%{
            keywords: ~w(tidepool drain retention),
            url: server.base_url <> "/#{&1}.html",
            title: &1,
            snippet: "Tidepool"
          }
        )
      )

    %{
      base: server.base_url,
      opts: [
        search: {Static, search},
        fetch: WebFetch.new(unsafe_allow_loopback_for_tests: true),
        top_k: 3,
        research_mode: :simple,
        cwd: path,
        session: [
          provider:
            Scripted.new([
              Scripted.complete(
                JSON.encode!(%{
                  "answer" => "72 hours; --confirm",
                  "citations" => [server.base_url <> "/guide.html"]
                })
              )
            ]),
          model: "test:model",
          sessions_dir: Path.join(path, "sessions")
        ]
      ]
    }
  end

  test "guided discovery skips a weaker search hit, follows a unique documentation link and grounds synthesis",
       %{base: base, opts: opts} do
    owner = self()

    classify = fn request ->
      send(owner, {:choice, request})

      url =
        case length(request["state"]["sources"]) do
          0 -> base <> "/index.html"
          1 -> base <> "/guide.html"
          _ -> "STOP"
        end

      choice(request, url)
    end

    assert {:ok, result} =
             Pipeline.run(
               "Tidepool retention and drain requirements",
               opts ++ [discovery: [classify: classify]]
             )

    assert Enum.map(result.fetched, & &1.url) == [base <> "/index.html", base <> "/guide.html"]
    assert result.citations == [base <> "/guide.html"]
    assert result.discovery.stop_reason == "model_stop"
    assert length(result.discovery.decisions) == 3
    assert_receive {:choice, first}
    assert Enum.any?(Map.values(candidates(first)), &(&1["url"] == base <> "/junk.html"))

    assert_receive {:choice, second}
    assert Enum.all?(Map.values(second["questions"]["next"]["criteria"]), &is_binary/1)
    assert Map.has_key?(second["questions"]["next"]["criteria"], "STOP")
    links = candidates(second) |> Map.values() |> Enum.map(& &1["url"])

    assert Enum.count(links, &(&1 == base <> "/guide.html")) == 1
    refute "http://10.0.0.1/secret" in links
    [request] = Scripted.requests(opts[:session][:provider])

    assert Enum.any?(
             request.entries,
             &(is_map(&1.payload) and
                 String.contains?(&1.payload["text"] || "", "Drain requires --confirm"))
           )
  end

  test "an invented choice fails without fetching or synthesizing", %{opts: opts} do
    classify = fn _ ->
      {:ok,
       %{
         "answers" => %{
           "next" => %{
             "choice" => "https://made-up.example",
             "confidence" => 1.0,
             "probabilities" => %{}
           }
         }
       }}
    end

    assert {:error, {:discovery, "invalid_choice"}, partial} =
             Pipeline.run("Tidepool", opts ++ [discovery: [classify: classify]])

    assert partial.fetched == []
    assert Scripted.requests(opts[:session][:provider]) == []
  end

  test "the default hosted adapter selects linked sources and returns JSON agent evidence", %{
    base: base,
    opts: opts
  } do
    request = fn wire_opts ->
      question = wire_opts[:json]

      url =
        case length(question["state"]["sources"]) do
          0 -> base <> "/index.html"
          1 -> base <> "/guide.html"
          _ -> "STOP"
        end

      {:ok, answer} = choice(question, url)
      {:ok, %Req.Response{status: 200, body: answer}}
    end

    session = Keyword.fetch!(opts, :session)

    agent_opts =
      Keyword.delete(opts, :session) ++
        session ++
        [discovery: [provider: typesafe("test-key"), request: request]]

    input = %{prompt: "Tidepool retention and drain", cwd: opts[:cwd], timeout_ms: 10_000}
    assert {:ok, observation} = Lemieux.Agent.run(ResearchExtension, input, agent_opts)
    assert observation["citations"] == [base <> "/guide.html"]
    assert observation["discovery"]["stop_reason"] == "model_stop"
    assert length(observation["discovery"]["decisions"]) == 3
    refute JSON.encode!(observation) =~ "test-key"
  end

  test "host policy governs classifier calls before spending quota", %{opts: opts} do
    owner = self()

    classify = fn _ ->
      send(owner, :classified)
      {:error, "private provider detail"}
    end

    hooks = [
      before_tool_call: fn call, _ ->
        if call.name == "research_discovery_choice",
          do: {:deny, "no classification"},
          else: :allow
      end
    ]

    assert {:error, {:discovery, "classifier_failed"}, _} =
             Pipeline.run("Tidepool", opts ++ [discovery: [classify: classify], hooks: hooks])

    refute_receive :classified
  end

  test "attempts share the fetch byte budget", %{
    base: base,
    opts: opts
  } do
    owner = self()

    classify = fn request ->
      send(owner, {:request, request})

      choice(
        request,
        if(request["state"]["sources"] == [], do: base <> "/index.html", else: "STOP")
      )
    end

    assert {:error, {:unfetched_citation, _}, partial} =
             Pipeline.run(
               "Tidepool",
               opts ++ [max_total_bytes: 1024, discovery: [classify: classify, max_depth: 0]]
             )

    assert Enum.sum(Enum.map(partial.fetched, & &1.bytes)) <= 1024
    assert_receive {:request, _}
    refute_receive {:request, _}
    assert partial.discovery.stop_reason == "byte_budget"
  end

  test "depth zero does not offer linked pages", %{base: base, opts: opts} do
    owner = self()

    classify = fn request ->
      send(owner, {:request, request})

      choice(
        request,
        if(request["state"]["sources"] == [], do: base <> "/index.html", else: "STOP")
      )
    end

    assert {:error, {:unfetched_citation, _}, partial} =
             Pipeline.run("Tidepool", opts ++ [discovery: [classify: classify, max_depth: 0]])

    assert partial.discovery.stop_reason == "model_stop"
    assert_receive {:request, _}
    assert_receive {:request, request}

    refute Enum.any?(Map.values(candidates(request)), &(&1["url"] == base <> "/guide.html"))
  end

  test "a lone candidate is opened without asking the classifier", %{base: base, opts: opts} do
    owner = self()
    index = base <> "/index.html"

    search =
      Static.new([%{keywords: ~w(tidepool), url: index, title: "index", snippet: "Tidepool"}])

    classify = fn request ->
      send(owner, {:classified, request})
      choice(request, index)
    end

    assert {:error, {:unfetched_citation, _}, partial} =
             Pipeline.run(
               "Tidepool",
               Keyword.put(opts, :search, {Static, search}) ++
                 [discovery: [classify: classify, max_depth: 0]]
             )

    refute_received {:classified, _}
    assert Enum.map(partial.fetched, & &1.url) == [index]
    assert partial.discovery.classifier_attempts == 0
    assert partial.discovery.stop_reason == "frontier_exhausted"

    assert [
             %{
               "choice" => "1",
               "url" => ^index,
               "confidence" => nil,
               "model" => nil,
               "usage" => nil
             }
           ] = partial.discovery.decisions
  end

  test "the discovery deadline stops a stalled classifier before synthesis", %{opts: opts} do
    owner = self()

    classify = fn _ ->
      send(owner, {:worker, self()})

      receive do
        :never -> {:error, "unreachable"}
      end
    end

    assert {:error, {:discovery, "discovery_timeout_or_failure"}, partial} =
             Pipeline.run("Tidepool", opts ++ [discovery: [classify: classify, timeout_ms: 100]])

    assert partial.discovery.evidence_incomplete
    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    assert Scripted.requests(opts[:session][:provider]) == []
  end

  test "bad discovery configuration fails before search or synthesis", %{opts: opts} do
    for bad <- [
          [classify: nil],
          [classify: fn _ -> :unused end, max_depth: 4],
          [classify: fn _ -> :unused end, candidate_limit: 11]
        ] do
      assert_raise ArgumentError, fn -> Pipeline.run("Tidepool", opts ++ [discovery: bad]) end
    end

    assert Scripted.requests(opts[:session][:provider]) == []
  end

  # The offered sources: every description but STOP's is a candidate's
  # metadata as a JSON string.
  defp candidates(request) do
    for {id, description} <- request["questions"]["next"]["criteria"],
        id != "STOP",
        into: %{},
        do: {id, JSON.decode!(description)}
  end

  defp choice(request, url) do
    criteria = request["questions"]["next"]["criteria"]

    selected =
      if url == "STOP",
        do: "STOP",
        else:
          Enum.find_value(candidates(request), fn {id, row} -> if row["url"] == url, do: id end)

    assert selected

    {:ok,
     %{
       # The native adapter's request names a model, which the answer echoes.
       "model" => request["model"] || "scripted-discovery",
       "answers" => %{
         "next" => %{
           "choice" => selected,
           "confidence" => 1.0,
           "probabilities" =>
             Map.new(criteria, fn {id, _} -> {id, if(id == selected, do: 1.0, else: 0.0)} end)
         }
       },
       "usage" => %{"input_tokens" => 1}
     }}
  end

  defp typesafe(key),
    do: %{
      name: "typesafe",
      type: :typesafe,
      base_url: "https://api.typesafe.ai",
      api_key: key,
      api_key_header: nil,
      headers: %{},
      model: nil
    }
end
