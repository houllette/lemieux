defmodule Lemieux.Subagent.Context do
  @moduledoc """
  A bounded evidence packet explicitly selected by a host for a fresh child.

  Nothing selects or copies parent history implicitly. Entry IDs are stable
  source references; their payload digests let a reader detect changed evidence.
  The packet is data, not inherited policy or tool authority. Hosts must exclude
  secrets before selecting entries. Oversize packets are refused rather than
  silently dropping the constraint that happened to come last.
  """

  alias Lemieux.Contract
  alias Lemieux.Entry

  @max_bytes 32_768

  @doc "Selects exact entries from a named transcript, retaining order and provenance."
  @spec select(session_id :: String.t(), entries :: [Entry.t()], ids :: [String.t()]) ::
          {:ok, map()} | {:error, term()}
  def select(session_id, entries, ids) when is_binary(session_id) and is_list(ids) do
    selected = Enum.filter(entries, &(&1.id in ids))

    if length(Enum.uniq(ids)) == length(ids) and length(selected) == length(ids) do
      packet = %{
        "version" => 1,
        "source_session_id" => session_id,
        "entries" =>
          Enum.map(selected, fn entry ->
            %{
              "id" => entry.id,
              "type" => to_string(entry.type),
              "payload" => entry.payload,
              "digest" => Contract.digest(entry.payload)
            }
          end)
      }

      validate(packet)
    else
      {:error, :unknown_or_duplicate_context_entry}
    end
  end

  @doc "Validates packet version, bounds and source payload digests."
  @spec validate(packet :: term()) :: {:ok, map() | nil} | {:error, term()}
  def validate(nil), do: {:ok, nil}

  def validate(%{"version" => 1, "source_session_id" => source, "entries" => entries} = packet)
      when is_binary(source) and source != "" and is_list(entries) do
    valid = Enum.all?(entries, &valid_entry?/1)
    ids = for %{"id" => id} <- entries, do: id

    if valid and length(ids) == length(Enum.uniq(ids)) and
         byte_size(JSON.encode!(packet)) <= @max_bytes,
       do: {:ok, packet},
       else: {:error, :invalid_or_oversized_context}
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] -> {:error, :invalid_context}
  end

  def validate(_packet), do: {:error, :invalid_context}

  @doc "Validates a host-configured packet or raises for invalid configuration."
  @spec validate!(packet :: term()) :: map() | nil
  def validate!(packet) do
    case validate(packet) do
      {:ok, packet} -> packet
      {:error, reason} -> raise ArgumentError, "invalid subagent context: #{inspect(reason)}"
    end
  end

  defp valid_entry?(%{"id" => id, "type" => type, "payload" => payload, "digest" => digest})
       when is_binary(id) and id != "" and is_binary(type) and is_map(payload),
       do: Contract.digest(payload) == digest

  defp valid_entry?(_entry), do: false
end
