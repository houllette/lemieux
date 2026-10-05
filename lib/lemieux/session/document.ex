defmodule Lemieux.Session.Document do
  @moduledoc """
  Versioned, bounded extension documents projected from a session transcript.

  The session serializes compare-and-swap commits; this module only validates
  and projects data. Namespace meanings belong to extensions. Documents carry
  no executable code or live authority, and fork copies their historical value
  without sharing mutable state. A complete bounded checkpoint per mutation
  makes replay independent of tool-result truncation and compaction. This is
  session-local state, not a cross-session issue database or scheduler. An
  extension checkpoint may carry the separate, metered usage of the external
  operation that produced it; its document value still grants no authority.
  """

  alias Lemieux.Entry

  @max_bytes 65_536

  @doc "Reads the newest checkpoint from entries supplied newest first."
  @spec read(reversed_entries :: [Entry.t()], namespace :: String.t()) ::
          {:ok, map()} | {:error, term()}
  def read(reversed_entries, namespace) do
    case Enum.find(
           reversed_entries,
           &(&1.type == :extension_state and &1.payload["namespace"] == namespace)
         ) do
      nil ->
        {:ok, %{revision: 0, value: nil}}

      %{payload: %{"version" => 1, "revision" => revision, "value" => value}}
      when is_integer(revision) and revision > 0 and is_map(value) ->
        {:ok, %{revision: revision, value: value}}

      _invalid ->
        {:error, :invalid_document}
    end
  end

  @doc "Validates a bounded JSON checkpoint before it reaches the session process."
  @spec validate(namespace :: term(), value :: term(), usage :: map() | nil) ::
          :ok | {:error, term()}
  def validate(namespace, value, usage \\ nil)

  def validate(namespace, value, usage)
      when is_binary(namespace) and byte_size(namespace) in 1..128 and is_map(value) do
    entry =
      Entry.new(:extension_state, %{"namespace" => namespace, "value" => value}, usage: usage)

    cond do
      not valid_usage?(usage) -> {:error, :invalid_usage}
      byte_size(Entry.encode!(entry)) > @max_bytes - 256 -> {:error, :document_too_large}
      true -> :ok
    end
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] -> {:error, :invalid_document}
  end

  def validate(_namespace, _value, _usage), do: {:error, :invalid_document}

  defp valid_usage?(nil), do: true

  defp valid_usage?(%{
         "model" => model,
         "input_tokens" => input,
         "output_tokens" => output,
         "cost_usd" => cost
       })
       when is_binary(model) and model != "" and is_integer(input) and input >= 0 and
              is_integer(output) and output >= 0 and
              ((is_number(cost) and cost >= 0) or is_nil(cost)),
       do: true

  defp valid_usage?(_usage), do: false
end
