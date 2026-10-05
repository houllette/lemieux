defmodule Lemieux.Conversation.Command.Context do
  @moduledoc """
  `/context`: where the session stands in its window, drawn by the front end.

  The parse answers a text report; the TUI swaps it for the
  `:context_status` action and draws the window as bands. Neither asks the
  session anything, so `perform/3` is a no-op.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "context", description: "show context usage", action: :context_status}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, conversation) do
    Conversation.ready_unless_busy(conversation, [
      {:say, Conversation.context_report(conversation)}
    ])
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
