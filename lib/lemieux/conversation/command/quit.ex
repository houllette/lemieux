defmodule Lemieux.Conversation.Command.Quit do
  @moduledoc """
  `/quit`, `/exit`: leave the interface.

  Parsed even mid-turn — leaving is always allowed — and performed by the
  front end, which owns the process to stop.
  """

  @behaviour Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{name: "quit", aliases: ["exit"], description: "leave the session", action: :quit}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:quit]

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
