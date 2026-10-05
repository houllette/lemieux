defmodule LemieuxJevCompaction.Transport do
  @moduledoc """
  Unary HTTP transport for SystemOneSDK with redirects and retries disabled.

  The SDK's default Pristine transport delegates to `:httpc`, whose defaults
  follow redirects and can retry a response carrying Retry-After. Neither is
  acceptable for a compaction decision that sends a bearer credential and has a one-request
  budget. TypeSafe paths, authentication, serialization and response decoding
  remain owned by SystemOneSDK and its TypeSafe provider.
  """

  @behaviour Pristine.Ports.Transport

  alias Pristine.Core.{Request, Response}

  @connect_timeout_ms 5_000

  @impl true
  @spec send(request :: Request.t(), context :: Pristine.Core.Context.t()) ::
          {:ok, Response.t()} | {:error, term()}
  def send(%Request{} = request, _context) do
    with {:ok, method} <- method(request.method),
         {:ok, {{_version, status, _reason}, headers, body}} <-
           :httpc.request(
             method,
             http_request(request, method),
             http_options(request),
             body_format: :binary
           ) do
      {:ok,
       %Response{
         status: status,
         headers:
           Map.new(headers, fn {name, value} ->
             {String.downcase(to_string(name)), to_string(value)}
           end),
         body: IO.iodata_to_binary(body)
       }}
    end
  end

  defp method(:get), do: {:ok, :get}
  defp method(:post), do: {:ok, :post}
  defp method("GET"), do: {:ok, :get}
  defp method("POST"), do: {:ok, :post}
  defp method(_), do: {:error, :unsupported_method}

  defp http_request(%Request{} = request, method) do
    headers =
      Enum.map(request.headers, fn {name, value} ->
        {String.to_charlist(to_string(name)), String.to_charlist(to_string(value))}
      end)

    url = String.to_charlist(request.url)

    case method do
      :get -> {url, headers}
      :post -> {url, headers, ~c"application/json", request.body || ""}
    end
  end

  defp http_options(%Request{metadata: metadata}) do
    timeout = timeout(metadata)

    [
      timeout: timeout,
      connect_timeout: min(timeout, @connect_timeout_ms),
      autoredirect: false,
      autoretry: 0
    ]
  end

  defp timeout(%{timeout: value}) when is_integer(value) and value > 0, do: value
  defp timeout(_), do: 15_000
end
