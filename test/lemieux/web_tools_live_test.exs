defmodule Lemieux.WebToolsLiveTest do
  use ExUnit.Case, async: false

  alias Lemieux.Extensions.Web.Brave
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools
  alias Lemieux.Tools.WebFetch
  alias Lemieux.Tools.WebSearch

  # Opt in to this file only: the repository's other live tests can invoke
  # model providers. These scenarios make two paid search calls in total.
  @moduletag :live
  # Even when chosen by `path:LINE`; see `LemieuxTest.Spend.skip/0`.
  @moduletag skip: LemieuxTest.Spend.skip()
  @moduletag :tmp_dir
  @context %{cwd: "/tmp", session_id: "web-live", tool_output_bytes: 140_000}

  test "live Brave results can be opened through the ordinary tool path" do
    search = search()

    call = %{
      id: "search",
      name: "web_search",
      arguments: %{
        "query" => "Elixir Task.Supervisor async_nolink",
        "domains" => ["hexdocs.pm"],
        "max_results" => 2
      }
    }

    result = Tools.run([search], [], call, @context)
    refute result.error?, result.output
    assert result.cost == %{"usd" => Brave.request_cost_usd(elem(search.backend, 1))}
    assert [first | _] = result.structured_content["results"]
    assert URI.parse(first["url"]).host =~ "hexdocs.pm"
    assert result.output =~ "untrusted external content"

    page =
      Tools.run(
        [WebFetch.new()],
        [],
        %{id: "fetch", name: "web_fetch", arguments: %{"url" => first["url"]}},
        @context
      )

    refute page.error?, page.output
    assert page.structured_content["status"] == 200
    assert page.structured_content["text"] =~ "async_nolink"
    assert page.structured_content["bytes"] > 0
    assert page.output =~ "untrusted external data"
  end

  test "live session persists paid search evidence without its key", %{tmp_dir: path} do
    # Requests are sequential even on a one-request-per-second subscription.
    Process.sleep(1100)
    supervisor = :"web_live_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    provider =
      Scripted.new(
        [
          Scripted.tool_call(
            "search",
            "web_search",
            %{"query" => "Elixir programming language", "max_results" => 2},
            usage: %{"cost_usd" => 0.0}
          ),
          Scripted.complete("Search completed", usage: %{"cost_usd" => 0.0})
        ],
        estimated_cost_usd: 0
      )

    store = JSONL.new(path)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: supervisor,
        provider: provider,
        model: "test:model",
        store: store,
        tools: [search()],
        subscriber: self(),
        max_cost_usd: 0.01
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)
    id = Session.id(session)
    :ok = Session.prompt(session, "Search")
    assert_receive {:lemieux, ^id, {:finished, reason}}, 30_000
    assert reason == :stop
    {:ok, entries} = Lemieux.Store.read(store, id)
    result = Enum.find(entries, &(&1.type == :tool_result))
    refute result.payload["error"], result.payload["output"]
    assert result.payload["cost"] == %{"usd" => 0.005}
    assert result.payload["metadata"]["usage"]["requests"] == 1
    assert result.payload["structured_content"]["results"] != []
    assert_in_delta Session.snapshot(session).spent_usd, 0.005, 1.0e-12
    refute inspect(entries) =~ System.fetch_env!("BRAVE_SEARCH_API_KEY")
  end

  test "live HTML redirects reach the document and respect a reduced byte cap" do
    url = "https://elixir-lang.org/getting-started/introduction.html"
    call = %{id: "refresh", name: "web_fetch", arguments: %{"url" => url}}
    page = Tools.run([WebFetch.new()], [], call, @context)
    refute page.error?, page.output
    assert page.structured_content["text"] =~ "Elixir"
    assert page.structured_content["url"] =~ "hexdocs.pm"
    assert page.structured_content["requested_url"] == url
    assert page.structured_content["redirects"] in 1..3

    capped =
      Tools.run([WebFetch.new(max_body_bytes: 4096, max_text_chars: 500)], [], call, @context)

    refute capped.error?, capped.output
    assert capped.structured_content["bytes"] <= 4096
    assert capped.structured_content["truncated"]
    assert String.length(capped.structured_content["text"]) <= 500
  end

  defp search do
    backend = Brave.new(api_key: System.fetch_env!("BRAVE_SEARCH_API_KEY"))
    WebSearch.new(backend: {Brave, backend}, max_cost_usd: Brave.request_cost_usd(backend))
  end
end
