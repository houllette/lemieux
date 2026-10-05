defmodule Lemieux.Conversation.Command.Compact do
  @moduledoc """
  `/compact`: summarise the earlier conversation now.

  Waits for the turn: a compaction under a running request would race it.
  It asks the model for the summary, so it blocks for seconds, and
  `perform/3` hands it to the host's `:run` for the answer to come back as
  `{:compaction_result, result}`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{name: "compact", description: "summarise earlier conversation", action: :compact}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:compact]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :compact) do
    session = host.session

    Dispatch.run(acc, host, fn -> {:compaction_result, Session.compact(session)} end)
  end
end
