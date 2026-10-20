defmodule Lemieux.Session.Notification do
  @moduledoc false

  alias Lemieux.Session.Core
  alias Lemieux.Session.Document
  alias Lemieux.Session.Prompts

  def validate(%{"id" => id, "text" => text} = event)
      when is_binary(id) and byte_size(id) in 1..200 and is_binary(text) and
             byte_size(text) in 1..24_000,
      do:
        if(valid_receipts?(event["receipt_ids"]),
          do: Document.validate("lemieux.notification", event),
          else: {:error, :invalid_notification}
        )

  def validate(_event), do: {:error, :invalid_notification}

  defp valid_receipts?(nil), do: true

  defp valid_receipts?(ids) when is_list(ids) and length(ids) in 1..256,
    do:
      Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..200)) and
        length(Enum.uniq(ids)) == length(ids)

  defp valid_receipts?(_ids), do: false

  # The receipt is written before inference. After a crash between the receipt
  # and dispatch we prefer a visible result without an answer to spending twice.
  # Historical receipts never restore permission to continue.
  def deliver(state, event, opts) do
    receipts = event["receipt_ids"] || [event["id"]]

    cond do
      delivered?(state, event["id"]) -> {:reply, :duplicate, state}
      Enum.all?(receipts, &delivered?(state, &1)) -> {:reply, :duplicate, state}
      Enum.any?(receipts, &delivered?(state, &1)) -> {:reply, {:error, :partial_duplicate}, state}
      Core.busy?(state) -> {:reply, {:error, :busy}, state}
      true -> accept(state, event, opts)
    end
  end

  defp delivered?(state, id) do
    Enum.any?(state.reversed_entries, fn
      %{
        type: :extension_state,
        payload: %{"namespace" => "lemieux.notification", "value" => value}
      } ->
        value["session_id"] == state.id and
          (value["id"] == id or id in (value["receipt_ids"] || []))

      %{
        type: :tool_result,
        payload: %{"error" => false, "metadata" => %{"notification_receipt_ids" => ids}}
      }
      when is_list(ids) ->
        id in ids

      _entry ->
        false
    end)
  end

  defp accept(state, event, opts) do
    follow_up? = Keyword.get(opts, :follow_up, false) == true
    value = Map.merge(event, %{"session_id" => state.id, "follow_up" => follow_up?})

    payload = %{
      "version" => 1,
      "namespace" => "lemieux.notification",
      "revision" => state.next_seq + 1,
      "value" => value
    }

    state = Core.append(state, {:extension_state, payload, nil})
    state = if follow_up?, do: Prompts.start_notification_hook(state, event, opts), else: state
    {:reply, :ok, state}
  end
end
