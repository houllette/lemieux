defmodule Lemieux.Extensions.Web.BraveTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Web.Brave

  test "sends the documented Brave request and parses web results" do
    caller = self()

    request = fn opts ->
      send(caller, {:request, opts})

      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "web" => %{
             "results" => [
               %{
                 "title" => "Lemieux",
                 "url" => "https://example.com/lemieux",
                 "description" => "A minimal agent harness.",
                 "page_age" => "2026-08-20T10:30:00Z"
               }
             ]
           }
         }
       }}
    end

    backend = Brave.new(api_key: "secret-token", request: request)

    assert {:ok, [result], usage} =
             Brave.search(backend, "elixir agents", domains: ["hexdocs.pm"], max_results: 3)

    assert_receive {:request, request_opts}
    assert request_opts[:url] == "https://api.search.brave.com/res/v1/web/search"
    assert request_opts[:params][:q] == "elixir agents (site:hexdocs.pm)"
    assert request_opts[:params][:count] == 3
    assert request_opts[:params][:result_filter] == "web"
    assert {"x-subscription-token", "secret-token"} in request_opts[:headers]

    assert result.title == "Lemieux"
    assert result.published_at == ~U[2026-08-20 10:30:00Z]

    assert usage == %{
             "kind" => "web_search",
             "provider" => "brave",
             "requests" => 1,
             "cost_usd" => 0.005
           }
  end

  test "returns explicit safe errors for HTTP, transport and malformed responses" do
    assert {:error, "Brave Search rejected the API key"} =
             search_with(fn _opts -> {:ok, %Req.Response{status: 401, body: %{}}} end)

    assert {:error, "Brave Search rate limit exceeded"} =
             search_with(fn _opts -> {:ok, %Req.Response{status: 429, body: %{}}} end)

    assert {:error, "Brave Search request failed with HTTP 503"} =
             search_with(fn _opts -> {:ok, %Req.Response{status: 503, body: %{}}} end)

    assert {:error, "could not reach Brave Search"} =
             search_with(fn _opts -> {:error, %RuntimeError{message: "secret-token"}} end)

    assert {:error, "Brave Search returned a malformed response"} =
             search_with(fn _opts -> {:ok, %Req.Response{status: 200, body: %{"web" => []}}} end)
  end

  test "refuses a domain-expanded query beyond Brave's documented limit" do
    backend = Brave.new(api_key: "token", request: fn _opts -> flunk("request must not run") end)
    query = String.duplicate("q", 390)

    assert {:error, message} =
             Brave.search(backend, query, domains: ["example.com"], max_results: 5)

    assert message =~ "400-character"

    assert {:error, message} =
             Brave.search(backend, Enum.map_join(1..51, " ", &"word#{&1}"),
               domains: [],
               max_results: 5
             )

    assert message =~ "50-word"
  end

  test "decodes Brave's HTML entities and accepts absent or null descriptions" do
    request = fn _opts ->
      {:ok,
       %Req.Response{
         status: 200,
         body: %{
           "web" => %{
             "results" => [
               %{
                 "title" => "Tools &amp; streams",
                 "url" => "https://example.com/1",
                 "description" => "Use &quot;async&quot; and &#x27;tasks&#39;."
               },
               %{"title" => "No snippet", "url" => "https://example.com/2", "description" => nil},
               %{"title" => "Missing snippet", "url" => "https://example.com/3"}
             ]
           }
         }
       }}
    end

    assert {:ok, [first, second, third], _usage} = search_with(request)
    assert first.title == "Tools & streams"
    assert first.snippet == "Use \"async\" and 'tasks'."
    assert second.snippet == ""
    assert third.snippet == ""
  end

  test "still rejects a description with an invalid non-null type" do
    assert {:error, "Brave Search returned a malformed response"} =
             search_with(fn _opts ->
               {:ok,
                %Req.Response{
                  status: 200,
                  body: %{
                    "web" => %{
                      "results" => [
                        %{
                          "title" => "Invalid",
                          "url" => "https://example.com",
                          "description" => 42
                        }
                      ]
                    }
                  }
                }}
             end)
  end

  test "inspection cannot reveal a credential or a request closure" do
    backend = Brave.new(api_key: "secret-token")
    refute inspect(backend) =~ "secret-token"
    refute inspect(backend) =~ "Req.get"
    assert inspect(backend) =~ "api.search.brave.com"
  end

  @tag :live
  # Even when chosen by `path:LINE`; see `LemieuxTest.Spend.skip/0`.
  @tag skip: LemieuxTest.Spend.skip()
  test "live search returns normalized results when explicitly enabled" do
    api_key = System.fetch_env!("BRAVE_SEARCH_API_KEY")
    backend = Brave.new(api_key: api_key)

    assert {:ok, results, %{"requests" => 1}} =
             Brave.search(backend, "Elixir programming language", max_results: 2, domains: [])

    assert results != []
    assert Enum.all?(results, &String.starts_with?(&1.url, "http"))
  end

  defp search_with(request) do
    backend = Brave.new(api_key: "secret-token", request: request)
    Brave.search(backend, "test", domains: [], max_results: 5)
  end
end
