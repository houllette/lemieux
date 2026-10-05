defmodule Lemieux.Conversation.Command.Copy do
  @moduledoc """
  `/copy`: the latest agent response, to the host's clipboard.

  The wording of each failure lives here once. Before the shared
  dispatcher, the screen and the prompt each had their own copy and they
  disagreed.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session
  alias Lemieux.Transcript

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "copy", description: "copy the latest agent response", action: :copy}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:copy]

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, :copy),
    do: Dispatch.say(acc, host, "no agent response to copy")

  def perform(acc, host, :copy) do
    host.session
    |> Session.snapshot()
    |> Map.fetch!(:entries)
    |> Transcript.latest_assistant_text()
    |> copied(acc, host)
  end

  defp copied({:ok, text}, acc, host) do
    case clipboard(host, text) do
      :ok ->
        Dispatch.say(acc, host, "copied the latest agent response")

      {:error, :unsupported_transport} ->
        Dispatch.say(acc, host, "clipboard copy is unavailable for this terminal transport")

      {:error, reason} ->
        Dispatch.say(acc, host, "could not copy the latest agent response: #{inspect(reason)}")

      other ->
        Dispatch.say(acc, host, "could not copy the latest agent response: #{inspect(other)}")
    end
  end

  defp copied({:error, :not_found}, acc, host),
    do: Dispatch.say(acc, host, "no agent response to copy")

  defp clipboard(%Dispatch{clipboard: nil}, _text), do: {:error, :unsupported_transport}
  defp clipboard(%Dispatch{clipboard: copy}, text), do: copy.(text)
end
