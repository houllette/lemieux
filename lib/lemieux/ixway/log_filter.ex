defmodule Lemieux.Ixway.LogFilter do
  @moduledoc """
  Removes upstream stream-failure logs that contain Ixway's private headers.

  ReqLLM logs an inspected API error before a route can handle it, and that
  error includes response headers. A primary Logger filter runs before any
  handler receives the message. Registering it when the Ixway route is used
  protects receipt credentials without changing ReqLLM or other providers.
  """

  @filter_id :lemieux_ixway_private_headers
  @private_headers ~w(x-ixway-key x-ixway-receipt-url x-ixway-receipt-token)

  @doc false
  @spec install() :: :ok | {:error, term()}
  def install do
    case :logger.add_primary_filter(@filter_id, {&__MODULE__.filter/2, nil}) do
      :ok -> :ok
      {:error, {:already_exist, @filter_id}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec filter(map(), term()) :: map() | :stop
  def filter(%{msg: {:string, message}} = event, _config) when is_binary(message) do
    if Enum.any?(@private_headers, &String.contains?(message, &1)), do: :stop, else: event
  end

  def filter(%{msg: {:report, report}} = event, _config) do
    if Enum.any?(@private_headers, &String.contains?(inspect(report), &1)), do: :stop, else: event
  end

  def filter(event, _config), do: event
end
