defmodule Lemieux.Conversation.Command.Retry do
  @moduledoc """
  `/retry`: send the request that failed again.

  Answers at once — the request is sent, not awaited — but a session
  mid-stop can still hold the call for as long as its stop hook, so it goes
  through the host's `:run`. `Lemieux.Conversation.Dispatch.answer/3` turns
  an accepted retry into a turn starting.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{name: "retry", description: "send the request that failed again", action: :retry}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: [{:say, "it is still running"}]
  def parse(_arguments, _conversation), do: [:retry]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :retry) do
    session = host.session

    Dispatch.run(acc, host, fn -> {:retry_result, Session.retry(session)} end)
  end
end
