defmodule Lemieux.Jobs.Intent do
  @moduledoc false
  @spec validate(intent :: term()) :: :ok | {:error, term()}
  def validate(intent) when is_map(intent) do
    if prompt?(intent["prompt"]) and workspace?(intent["cwd"]) and
         limits?(intent["limits"]) and time?(intent["run_at"]) and timeout?(intent["timeout_ms"]) and
         byte_size(JSON.encode!(intent)) <= 65_536, do: :ok, else: {:error, :invalid_job_intent}
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] -> {:error, :invalid_job_intent}
  end

  def validate(_intent), do: {:error, :invalid_job_intent}

  defp prompt?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 32_768

  defp workspace?(value), do: is_binary(value) and value != "" and Path.type(value) == :absolute

  defp limits?(limits) when is_map(limits),
    do: map_size(limits) > 0 and Enum.all?(limits, &limit?/1)

  defp limits?(_limits), do: false
  defp limit?({"max_requests", n}), do: is_integer(n) and n > 0
  defp limit?({"max_cost_usd", n}), do: is_number(n) and n >= 0
  defp limit?(_limit), do: false
  defp time?(nil), do: true

  defp time?(value) when is_binary(value),
    do: match?({:ok, _time, 0}, DateTime.from_iso8601(value))

  defp time?(_value), do: false
  defp timeout?(nil), do: true
  defp timeout?(value), do: is_integer(value) and value > 0
end
