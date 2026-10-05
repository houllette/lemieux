defmodule LemieuxComputerUse.Search do
  @moduledoc "Explicit credential-free Exa search using Lemieux's existing MCP client."
  @behaviour Lemieux.WebSearch.Backend
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.Transport.HTTP
  alias Lemieux.WebSearch.Result

  @impl true
  def search(_state, query, opts) do
    config = %{url: "https://mcp.exa.ai/mcp?tools=web_search_advanced_exa", headers: %{}}

    with {:ok, client} <-
           Client.start_link(
             server: "computer-use-exa",
             transport: {HTTP, config},
             owner: self(),
             timeout: 15_000
           ) do
      try do
        case Client.call_tool(client, "web_search_advanced_exa", %{
               "query" => query,
               "numResults" => Keyword.get(opts, :max_results, 3)
             }) do
          {:ok, result} -> parse(result.model_text, result.structured_content)
          _ -> {:error, "Exa search failed; no alternate provider was used"}
        end
      after
        GenServer.stop(client)
      end
    end
  end

  @doc false
  @spec parse(text :: String.t(), structured :: map() | nil) ::
          {:ok, [Result.t()], map()} | {:error, String.t()}
  def parse(text, structured) do
    decoded =
      case JSON.decode(text) do
        {:ok, data} -> data
        _ -> structured
      end

    case decoded do
      %{"results" => results} when is_list(results) ->
        rows =
          for %{"url" => url} = row <- Enum.take(results, 5), is_binary(url) do
            %Result{
              url: url,
              title: row["title"] || url,
              snippet: String.slice(row["text"] || "", 0, 1500)
            }
          end

        {:ok, rows, %{"backend" => "exa-mcp", "cost_usd" => nil}}

      _ ->
        {:error, "Exa returned an unsupported search response"}
    end
  end
end
