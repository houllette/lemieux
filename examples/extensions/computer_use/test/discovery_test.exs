defmodule LemieuxComputerUse.DiscoveryTest do
  use ExUnit.Case, async: true
  alias LemieuxComputerUse.{Discovery, Fixture}

  setup do
    {:ok, server, url} = Fixture.start()
    on_exit(fn -> Fixture.stop(server) end)

    %{
      url: url,
      opts: [fetch: Lemieux.Tools.WebFetch.new(unsafe_allow_loopback_for_tests: true)],
      context: %{
        cwd: File.cwd!(),
        tool_output_bytes: 20_000,
        environment: Lemieux.Environment.local(),
        hooks: []
      }
    }
  end

  test "breadth-first discovery enforces page, depth and byte bounds", %{
    url: url,
    opts: opts,
    context: context
  } do
    full = Discovery.crawl(url, opts, context)

    assert Enum.map(full["pages"], &URI.parse(&1["url"]).path) == [
             "/index.html",
             "/hotels.html",
             "/help.html"
           ]

    assert length(Discovery.crawl(url, opts ++ [crawl_pages: 1], context)["pages"]) == 1
    assert length(Discovery.crawl(url, opts ++ [crawl_depth: 0], context)["pages"]) == 1
    bounded = Discovery.crawl(url, opts ++ [crawl_bytes: 1024], context)
    assert length(bounded["requests"]) == 2
    assert List.last(bounded["pages"])["truncated"]
    assert Enum.reduce(bounded["requests"], 0, &(&1["bytes"] + &2)) <= 1024
    assert Discovery.crawl(url, opts ++ [crawl_pages: 0], context)["requests"] == []
  end

  test "a fetch denial returns no content and cannot expand the crawl", %{
    url: url,
    opts: opts,
    context: context
  } do
    context = %{context | hooks: [before_tool_call: fn _, _ -> {:deny, "fixture denial"} end]}

    assert %{"pages" => [], "requests" => [%{"outcome" => "denied"}]} =
             Discovery.crawl(url, opts, context)
  end
end
