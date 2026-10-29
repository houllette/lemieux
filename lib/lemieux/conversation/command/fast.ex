defmodule Lemieux.Conversation.Command.Fast do
  @moduledoc """
  `/fast [on|off|ultrafast]`: faster service for subsequent requests.

  Bare toggles fast on or any enabled mode off. The session is the authority
  on capability and refuses unsupported modes even when a host lists the
  command. Faster service may cost more and requires provider account access.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "fast",
      description: "toggle faster service (may cost more)",
      accepts_arguments?: true,
      action: {:set_fast_mode, "MODE"},
      actions: [{:set_fast_mode, "MODE"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_mode, %Conversation{busy?: true}), do: Command.wait()

  def parse(mode, _conversation) do
    mode = String.trim(mode)
    [{:set_fast_mode, if(mode == "", do: "toggle", else: mode)}]
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:set_fast_mode, mode}) do
    case Session.set_fast_mode(host.session, mode) do
      {:ok, mode} ->
        Dispatch.say(
          acc,
          host,
          "fast: #{mode}" <> if(mode == "off", do: "", else: " · faster service may cost more")
        )

      {:error, {:fast_mode_unsupported, model, _mode, supported}} ->
        Dispatch.say(
          acc,
          host,
          "fast mode is unavailable for #{model} · supported: #{Enum.join(["off" | supported], ", ")}"
        )

      {:error, reason} ->
        Dispatch.say(acc, host, "could not set fast mode: #{Conversation.describe(reason)}")
    end
  end
end
