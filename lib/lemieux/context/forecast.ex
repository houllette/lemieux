defmodule Lemieux.Context.Forecast do
  @moduledoc """
  Forecasts the input of the *pending* request from a provider measurement.

  The last response's usage is the best measurement Lemieux has, but a user
  prompt, tool result or preparation hook can change the request before it is
  sent. Request snapshots record the neutral input's encoded size, so the
  change since the measured request can be scaled by that request's observed
  tokens per byte. This is an estimate, not a provider tokenizer: images and
  provider-specific framing can change the ratio. Hosts with a local, bounded
  exact counter can supply it; they need not install one to use compaction.

  An old transcript without input sizes, or the first request after compaction,
  falls back to a rough byte estimate. The source travels with the number so
  a cost policy can distinguish a measured projection from an exact count.
  """

  alias Lemieux.Context
  alias Lemieux.Entry
  alias Lemieux.Request

  @type t :: %{input_tokens: pos_integer(), source: :exact | :measured_delta | :bytes}

  @doc "Forecasts input tokens for `request`, using an optional host counter."
  @spec input(Request.t(), [Entry.t()], keyword()) :: t()
  def input(%Request{} = request, entries, opts \\ []) do
    case count(Keyword.get(opts, :counter), request) do
      {:ok, tokens} -> %{input_tokens: tokens, source: :exact}
      :unknown -> estimate(request, entries)
    end
  end

  defp count(nil, _request), do: :unknown

  defp count(counter, request) when is_function(counter, 1) do
    case counter.(request) do
      {:ok, tokens} when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _unknown -> :unknown
    end
  rescue
    _error -> :unknown
  catch
    _kind, _reason -> :unknown
  end

  defp estimate(request, entries) do
    current_bytes = Request.input_bytes(request)
    context = Context.position(entries)

    case last_measured_request(entries, context) do
      %{bytes: old_bytes, tokens: old_tokens} ->
        change = div((current_bytes - old_bytes) * old_tokens, old_bytes)

        %{
          input_tokens: max(max(old_tokens + change, div(current_bytes + 3, 4)), 1),
          source: :measured_delta
        }

      nil ->
        %{input_tokens: max(div(current_bytes + 3, 4), 1), source: :bytes}
    end
  end

  defp last_measured_request(_entries, %Context{measured?: false}), do: nil

  defp last_measured_request(entries, %Context{current: current}) do
    tokens = current.input + current.cached + current.cache_write

    with %Entry{usage: %{"request_id" => id}} <-
           Enum.find(Enum.reverse(entries), &is_map(&1.usage)),
         %Entry{payload: %{"input_bytes" => bytes}} <-
           Enum.find(Enum.reverse(entries), &(&1.type == :request and &1.payload["id"] == id)),
         true <- is_integer(bytes) and bytes > 0 and tokens > 0 do
      %{bytes: bytes, tokens: tokens}
    else
      _other -> nil
    end
  end
end
