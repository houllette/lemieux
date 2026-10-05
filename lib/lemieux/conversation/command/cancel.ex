defmodule Lemieux.Conversation.Command.Cancel do
  @moduledoc """
  `/cancel`: stop the turn that is running.

  The one setting-like command that runs mid-turn, because stopping busy
  work is its purpose. Cancelling drops whatever the turn was waiting on — a
  question, a parked tool call — because the agent that asked is being
  stopped: a front end still treating the next line as an answer would send
  it into a turn that no longer exists, and the session forgets its parked
  calls when it cancels.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "cancel", description: "stop the current turn", action: :cancel}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true} = conversation),
    do: {%{conversation | asking: nil, question: nil, approvals: []}, [:cancel]}

  def parse(_arguments, conversation),
    do: Conversation.ready_unless_busy(conversation, [{:say, "nothing to cancel"}])

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :cancel) do
    :ok = Session.cancel(host.session)

    acc
  end
end
