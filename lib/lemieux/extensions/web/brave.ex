defmodule Lemieux.Extensions.Web.Brave do
  @moduledoc """
  Brave Search API backend, the one `Lemieux.Extensions.Web` ships.

  The adapter is intentionally outside the model-facing tool. It owns Brave's
  endpoint, token header, site-operator translation and response shape; a
  library embedder remains free to provide any backend implementing
  `Lemieux.WebSearch.Backend`. `lmx` reaches it only after `--web-search
  brave`, `LMX_WEB_SEARCH=brave` or the personal config's `"web_search"`
  selected the capability, which is consent to disclose model-generated
  queries and spend search quota; a provider key alone never enables network access.

  `:request` is an executable injection seam for offline tests and hosts with a
  customized Req stack. It receives ordinary `Req.get/1` options. Neither it
  nor the API key is serialized into session configuration or descriptors.
  """

  @behaviour Lemieux.WebSearch.Backend

  alias Lemieux.WebFetch.HTML
  alias Lemieux.WebSearch.Result

  @endpoint "https://api.search.brave.com/res/v1/web/search"
  @request_cost_usd 0.005
  @max_query_chars 400
  @max_query_words 50

  @type request :: (keyword() -> {:ok, Req.Response.t()} | {:error, term()})
  @type t :: %__MODULE__{
          api_key: String.t(),
          endpoint: String.t(),
          request: request(),
          request_cost_usd: number()
        }

  @enforce_keys [:api_key, :endpoint, :request, :request_cost_usd]
  @derive {Inspect, only: [:endpoint, :request_cost_usd]}
  defstruct [:api_key, :endpoint, :request, :request_cost_usd]

  @doc "Builds the standalone Brave backend from host-owned credentials."
  @spec new(opts :: keyword()) :: t()
  def new(opts) when is_list(opts) do
    api_key = Keyword.fetch!(opts, :api_key)
    endpoint = Keyword.get(opts, :endpoint, @endpoint)
    request = Keyword.get(opts, :request, &Req.get/1)
    request_cost_usd = Keyword.get(opts, :request_cost_usd, @request_cost_usd)

    unless is_binary(api_key) and api_key != "",
      do: raise(ArgumentError, ":api_key must be a non-empty string")

    unless is_binary(endpoint) and endpoint != "",
      do: raise(ArgumentError, ":endpoint must be a non-empty string")

    unless is_function(request, 1),
      do: raise(ArgumentError, ":request must be an arity-one function")

    unless is_number(request_cost_usd) and request_cost_usd >= 0,
      do: raise(ArgumentError, ":request_cost_usd must be non-negative")

    %__MODULE__{
      api_key: api_key,
      endpoint: endpoint,
      request: request,
      request_cost_usd: request_cost_usd
    }
  end

  @doc "The configured maximum charged for one Brave search request."
  @spec request_cost_usd(backend :: t()) :: number()
  def request_cost_usd(%__MODULE__{} = backend), do: backend.request_cost_usd

  @impl Lemieux.WebSearch.Backend
  def search(%__MODULE__{} = backend, query, opts) when is_binary(query) and is_list(opts) do
    domains = Keyword.get(opts, :domains, [])
    max_results = Keyword.get(opts, :max_results, 5)

    with {:ok, expanded_query} <- expanded_query(query, domains),
         {:ok, response} <- request(backend, expanded_query, max_results),
         {:ok, results} <- response(response) do
      {:ok, results, usage(backend)}
    end
  rescue
    _error -> {:error, "could not reach Brave Search"}
  catch
    _kind, _reason -> {:error, "could not reach Brave Search"}
  end

  defp expanded_query(query, []), do: validate_query(query)

  defp expanded_query(query, domains) do
    restriction = Enum.map_join(domains, " OR ", &"site:#{&1}")
    expanded = query <> " (" <> restriction <> ")"

    validate_query(expanded)
  end

  defp validate_query(expanded) do
    cond do
      String.length(expanded) > @max_query_chars ->
        {:error, "query plus domain restrictions exceeds Brave Search's 400-character limit"}

      expanded |> String.split() |> length() > @max_query_words ->
        {:error, "query plus domain restrictions exceeds Brave Search's 50-word limit"}

      true ->
        {:ok, expanded}
    end
  end

  defp request(backend, query, max_results) do
    opts = [
      url: backend.endpoint,
      headers: [
        {"accept", "application/json"},
        {"x-subscription-token", backend.api_key}
      ],
      params: [
        q: query,
        count: max_results,
        result_filter: "web",
        text_decorations: false,
        safesearch: "moderate"
      ],
      receive_timeout: 20_000,
      retry: false
    ]

    case backend.request.(opts) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, _reason} -> {:error, "could not reach Brave Search"}
      _invalid -> {:error, "could not reach Brave Search"}
    end
  end

  defp response(%Req.Response{status: 200, body: body}), do: parse_body(body)

  defp response(%Req.Response{status: status}) when status in [401, 403],
    do: {:error, "Brave Search rejected the API key"}

  defp response(%Req.Response{status: 429}), do: {:error, "Brave Search rate limit exceeded"}

  defp response(%Req.Response{status: status}) when is_integer(status),
    do: {:error, "Brave Search request failed with HTTP #{status}"}

  defp response(_response), do: {:error, "Brave Search returned a malformed response"}

  defp parse_body(%{"web" => %{"results" => results}}) when is_list(results),
    do: parse_results(results)

  defp parse_body(body) when is_map(body) and not is_map_key(body, "web"), do: {:ok, []}
  defp parse_body(%{"web" => nil}), do: {:ok, []}
  defp parse_body(_body), do: {:error, "Brave Search returned a malformed response"}

  defp parse_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, parsed} ->
      case parse_result(result) do
        {:ok, result} -> {:cont, {:ok, [result | parsed]}}
        :error -> {:halt, {:error, "Brave Search returned a malformed response"}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  # Brave can omit descriptions or return null. Rejecting that valid row
  # would discard every other result in the paid response as malformed.
  defp parse_result(%{"title" => title, "url" => url} = result)
       when is_binary(title) and is_binary(url) do
    parse_result(result, Map.get(result, "description"))
  end

  defp parse_result(_result), do: :error

  defp parse_result(result, snippet) when is_binary(snippet) or is_nil(snippet) do
    {:ok,
     %Result{
       title: HTML.decode_entities(result["title"]),
       url: result["url"],
       snippet: HTML.decode_entities(snippet || ""),
       published_at: published_at(result["page_age"])
     }}
  end

  defp parse_result(_result, _snippet), do: :error

  defp published_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp published_at(_value), do: nil

  defp usage(backend) do
    %{
      "kind" => "web_search",
      "provider" => "brave",
      "requests" => 1,
      "cost_usd" => backend.request_cost_usd
    }
  end
end
