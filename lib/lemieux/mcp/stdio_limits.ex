defmodule Lemieux.MCP.StdioLimits do
  @moduledoc """
  Byte limits shared by native framing and managed MCP pipes.

  A limit ends the connection; protocol messages are never truncated. Total
  output includes invalid lines. Diagnostic accounting retains counts only,
  because a server's banners can contain credentials. Configure these through
  `:stdio_limits` in MCP connection options, outside the recorded server config.
  """
  @defaults [
    max_frame_bytes: 4_194_304,
    max_buffer_bytes: 8_388_608,
    max_total_bytes: 67_108_864,
    max_diagnostic_bytes: 16_384
  ]

  @doc "Validate finite byte limits, merging the shipped defaults."
  @spec new(options :: keyword()) :: {:ok, map()} | {:error, String.t()}
  def new(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Enum.all?(options, fn {key, value} ->
           Keyword.has_key?(@defaults, key) and is_integer(value) and value in 1..1_073_741_824
         end) do
      {:ok, Map.new(Keyword.merge(@defaults, options))}
    else
      {:error, "stdio limits require known keys and positive finite byte counts"}
    end
  end

  def new(_invalid), do: {:error, "stdio limits require a keyword list"}
end
