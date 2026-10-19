defmodule Lemieux.Session.Notification do
  @moduledoc false

  alias Lemieux.Session.Core
  alias Lemieux.Session.Document
  alias Lemieux.Session.Prompts

  def validate(%{"id" => id, "text" => text} = event)
      when is_binary(id) and byte_size(id) in 1..200 and is_binary(text) and
             byte_size(text) in 1..24_000,
      do: Document.validate("lemieux.notification", event)

  def validate(_event), do: {:error, :invalid_notification}

  # The receipt is written before inference. After a crash between the receipt
  # and dispatch we prefer a visible result without an answer to spending twice.
  # Historical receipts never restore permission to continue.
  def deliver(state, event, opts) do
    cond do
      delivered?(state, event["id"]) -> {:reply, :duplicate, state}
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
        value["id"] == id and value["session_id"] == state.id

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
