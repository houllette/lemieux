defmodule Lemieux.Conversation.Command.New do
  @moduledoc """
  `/new`: start a separate session with a new transcript and usage totals.

  The front end owns session startup, so the command only checks that no turn
  is running and hands it the action. Reusing `Session.clear/1` here would keep
  the old id and cumulative stats even though the pane looked empty.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "new", description: "start a new session", action: :new}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:new]

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, :new), do: acc
end
