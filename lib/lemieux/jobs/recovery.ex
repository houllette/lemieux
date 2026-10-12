defmodule Lemieux.Jobs.Recovery do
  @moduledoc false
  alias Lemieux.Entry
  alias Lemieux.Jobs.Journal
  alias Lemieux.Store
  alias Lemieux.Transcript

  @spec effects(journal :: Journal.t(), id :: String.t()) :: [Journal.stored_record()]
  def effects(journal, id), do: pages(journal, "effect-" <> id <> "-", nil, [])

  defp pages(journal, prefix, cursor, records) do
    {:ok, page} = Journal.scan(journal, prefix, cursor, 100)

    if page == [],
      do: Enum.reverse(records),
      else: pages(journal, prefix, List.last(page).key, Enum.reverse(page, records))
  end

  @spec assess(journal :: Journal.t(), job :: map()) :: :ok | {:error, term()}
  def assess(journal, job) do
    unknown =
      Enum.filter(effects(journal, job["id"]), fn record ->
        record.value["status"] == "started" and not retryable?(record.value["effect"])
      end)

    if unknown == [], do: :ok, else: {:error, {:unresolved_effects, Enum.map(unknown, & &1.key)}}
  end

  @spec measured_cost(journal :: Journal.t(), id :: String.t()) :: number()
  def measured_cost(journal, id) do
    effects(journal, id)
    |> Enum.reduce(0, fn record, total ->
      cost =
        get_in(record.value, ["result", "cost_usd"]) ||
          get_in(record.value, ["result", "cost", "usd"])

      if record.value["status"] == "completed" and is_number(cost), do: total + cost, else: total
    end)
  end

  @spec retryable?(effect :: map()) :: boolean()
  def retryable?(%{"kind" => "tool", "descriptor" => descriptor}) do
    effects = descriptor["effects"]

    (effects["class"] in ["read", "attention"] and
       (not is_map(effects["external_cost"]) or effects["external_cost"]["maximum_usd"] == 0) and
       descriptor["origin"]["type"] != "mcp") or
      (effects["idempotent"] == true and effects["retryable"] == true)
  end

  def retryable?(_effect), do: false

  @spec valid_reconciliation?(effect :: map(), decision :: map()) :: boolean()
  def valid_reconciliation?(_effect, %{"status" => "not_run"}), do: true

  def valid_reconciliation?(%{"kind" => "tool"} = effect, %{"result" => result})
      when is_map(result) do
    result["call_id"] == effect["call_id"] and result["name"] == effect["name"] and
      is_binary(result["output"]) and is_boolean(result["error"])
  end

  def valid_reconciliation?(%{"kind" => "provider"} = effect, %{"result" => result})
      when is_map(result) do
    is_list(result["entries"]) and result["entries"] != [] and
      Enum.all?(result["entries"], &valid_provider_entry?(&1, effect["request_id"]))
  end

  def valid_reconciliation?(_effect, _decision), do: false

  defp valid_provider_entry?(%{"type" => type, "payload" => payload} = entry, request_id)
       when type in ["assistant", "error"] and is_map(payload) do
    payload["request_id"] == request_id and
      (is_nil(entry["usage"]) or is_map(entry["usage"]))
  end

  defp valid_provider_entry?(_entry, _request_id), do: false

  @spec repair(journal :: Journal.t(), job :: map(), store :: Store.t()) :: :ok | {:error, term()}
  def repair(journal, job, store) do
    records = effects(journal, job["id"])

    Enum.reduce_while(job["sessions"], :ok, fn session_id, :ok ->
      case repair_session(store, session_id, records) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp repair_session(store, session_id, records) do
    case Store.lock(store, session_id) do
      {:ok, lock} when not is_nil(lock) ->
        try do
          case Store.read(store, session_id) do
            {:ok, entries} -> repair_entries(store, session_id, entries, records)
            {:error, :not_found} -> :ok
            error -> error
          end
        after
          Store.unlock(store, session_id, lock)
        end

      {:ok, nil} ->
        {:error, :transcript_lock_required}

      error ->
        error
    end
  end

  defp repair_entries(store, session_id, entries, records) do
    records =
      records
      |> Enum.filter(&(&1.value["effect"]["session_id"] == session_id))
      |> Enum.sort_by(& &1.value["started_at"])

    {entries, appended} =
      Enum.reduce(records, {entries, []}, fn record, {entries, appended} ->
        specs = missing_entries(record.value, entries) ++ reconciliation_note(record, entries)

        Enum.reduce(specs, {entries, appended}, fn {type, payload, usage}, {entries, appended} ->
          parent = List.last(entries)

          entry =
            Entry.new(type, payload,
              parent: parent,
              seq: if(parent, do: parent.seq + 1, else: 0),
              usage: usage
            )

          {entries ++ [entry], appended ++ [entry]}
        end)
      end)

    _entries = entries
    Store.append(store, session_id, appended)
  end

  defp missing_entries(
         %{
           "status" => "completed",
           "effect" => %{"kind" => "provider", "request_id" => id, "purpose" => "turn"},
           "result" => result
         },
         entries
       ) do
    if Enum.any?(entries, &(&1.type in [:assistant, :error] and &1.payload["request_id"] == id)),
      do: [],
      else:
        for(
          item <- result["entries"] || [],
          do: {entry_type(item["type"]), item["payload"], item["usage"]}
        )
  end

  defp missing_entries(
         %{
           "status" => "completed",
           "effect" => %{"kind" => "tool", "call_id" => id, "wave_id" => wave},
           "result" => result
         },
         entries
       ) do
    entries = wave_entries(entries, wave)

    if Enum.any?(Transcript.unanswered_calls(entries), &(&1.id == id)),
      do: [{:tool_result, result, nil}],
      else: []
  end

  defp missing_entries(_record, _entries), do: []

  # A session may have recorded an unknown outcome before the host fenced it.
  # Preserve that history and add current host evidence as a system message;
  # a second tool result would violate provider call/response pairing.
  defp reconciliation_note(
         %{key: key, value: %{"status" => status, "evidence" => evidence} = value},
         entries
       )
       when status in ["completed", "not_run"] do
    recorded? = Enum.any?(entries, &(&1.payload["reconciled_effect"] == key))

    if recorded? do
      []
    else
      [
        {:system,
         %{
           "reconciled_effect" => key,
           "text" =>
             reconciliation_text(status, key) <>
               JSON.encode!(%{
                 "effect" => value["effect"],
                 "result" => value["result"],
                 "evidence" => evidence
               })
         }, nil}
      ]
    end
  end

  defp reconciliation_note(_record, _entries), do: []

  defp reconciliation_text("completed", key),
    do: "The current host verified the completed effect #{key}. Do not repeat it. "

  defp reconciliation_text("not_run", key),
    do:
      "The current host verified that effect #{key} did not execute. Any retry requires current policy and admission. "

  # Call ids may be reused in later waves. A receipt belongs to its original
  # assistant entry, not the next unanswered call with the same vendor id.
  defp wave_entries(entries, wave) do
    case Enum.drop_while(entries, &(&1.id != wave)) do
      [assistant | rest] -> [assistant | Enum.take_while(rest, &(&1.type != :assistant))]
      [] -> []
    end
  end

  defp entry_type("assistant"), do: :assistant
  defp entry_type("error"), do: :error

  @spec stop_reason(journal :: Journal.t(), job :: map(), store :: Store.t()) :: atom() | nil
  def stop_reason(journal, job, store) do
    with true <- job["recover"] == true,
         {:ok, entries} <- Store.read(store, job["session_id"]),
         %Entry{type: :assistant, payload: %{"request_id" => request_id}} <-
           entries
           |> Enum.reverse()
           |> Enum.find(
             &(&1.type in [:user, :request, :assistant, :tool_result, :error, :cancelled])
           ),
         record when not is_nil(record) <-
           Enum.find(
             effects(journal, job["id"]),
             &(&1.value["effect"]["request_id"] == request_id and
                 &1.value["status"] == "completed")
           ) do
      reason(record.value["result"]["stop_reason"])
    else
      _unfinished -> nil
    end
  end

  defp reason("stop"), do: :stop
  defp reason("length"), do: :length
  defp reason("error"), do: :error
  defp reason(_reason), do: nil

  @spec pending(store :: Store.t(), sessions :: [String.t()]) :: [map()]
  def pending(store, sessions), do: Enum.flat_map(sessions, &pending_session(store, &1))

  defp pending_session(store, id) do
    case Store.read(store, id) do
      {:ok, entries} -> entries |> Enum.reduce(%{}, &pending_entry(&1, &2, id)) |> Map.values()
      {:error, :not_found} -> []
      {:error, reason} -> raise "could not read pending approvals: #{inspect(reason)}"
    end
  end

  defp pending_entry(%Entry{type: :approval, payload: payload}, pending, id) do
    if payload["status"] == "pending",
      do: Map.put(pending, payload["call_id"], Map.put(payload, "session_id", id)),
      else: Map.delete(pending, payload["call_id"])
  end

  defp pending_entry(%Entry{type: :tool_result, payload: payload}, pending, _id),
    do: Map.delete(pending, payload["call_id"])

  defp pending_entry(_entry, pending, _id), do: pending
end
