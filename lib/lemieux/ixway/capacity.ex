defmodule Lemieux.Ixway.Capacity do
  @moduledoc "A pooled quota refusal normalized by the Ixway route."

  alias Lemieux.Provider.Error, as: ProviderError
  alias ReqLLM.Error.API
  alias ReqLLM.Error.API.Request

  defexception [:status, :reset_at, :retry_after, provider_code: "quota_exhausted"]

  @impl Exception
  def message(%__MODULE__{reset_at: %DateTime{} = at}),
    do: "Pooled Codex quota exhausted. Resets #{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")}."

  def message(%__MODULE__{}), do: "Pooled Codex quota exhausted."

  # Ixway #306 tracks the gateway emitting error.code and error.reset_at.
  # Deployed gateways still use a generic 503, so match their exact quota
  # refusal on this route only. Account checks and ordinary overloads can
  # look identical in status, type and Retry-After and still recover.
  @legacy ~r/\ANo pooled Codex account could take this request: the account has used 100% of a quota window(?: \(resets (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) UTC\))?\./
  @denied "No pooled Codex account could take this request: OpenAI reports the account has no quota available."

  @spec normalize(Lemieux.Provider.Route.result()) :: Lemieux.Provider.Route.result()
  def normalize({:error, %API.Stream{cause: %Request{} = request}} = result),
    do: normalize_request(result, request)

  def normalize({:error, %Request{} = request} = result), do: normalize_request(result, request)
  def normalize(result), do: result

  defp normalize_request(result, %Request{status: status, response_body: body} = request) do
    error = error_body(body)

    case quota_reset(ProviderError.code(request), error, status) do
      {:exhausted, reset_at} ->
        ms = ProviderError.retry_after_ms(request)

        {:error,
         %__MODULE__{
           status: status,
           reset_at: reset_at,
           retry_after: if(is_integer(ms), do: ms / 1_000)
         }}

      :other ->
        result
    end
  end

  defp error_body(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> error_body(decoded)
      _invalid -> %{}
    end
  end

  defp error_body(%{"error" => %{} = error}), do: error
  defp error_body(%{} = body), do: body
  defp error_body(_body), do: %{}

  defp quota_reset("quota_exhausted", error, _status),
    do: {:exhausted, reset_time(error["reset_at"])}

  defp quota_reset(_code, %{"message" => @denied <> _rest}, 503),
    do: {:exhausted, nil}

  defp quota_reset(_code, %{"message" => message}, 503) when is_binary(message) do
    case Regex.run(@legacy, message) do
      [_match, at] -> {:exhausted, reset_time(at <> ":00Z")}
      [_match] -> {:exhausted, nil}
      nil -> :other
    end
  end

  defp quota_reset(_code, _error, _status), do: :other

  defp reset_time(at) when is_integer(at) do
    case DateTime.from_unix(at) do
      {:ok, datetime} -> datetime
      _invalid -> nil
    end
  end

  defp reset_time(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> nil
    end
  end

  defp reset_time(_unknown), do: nil
end
