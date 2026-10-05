defmodule Lemieux.Conversation.Command.Reflect do
  @moduledoc """
  `/reflect [opportunities]`: a review of the session, run as a turn.

  Refused mid-turn rather than queued: a reflection *is* a turn, and a line
  typed while one runs is a steer. The parse notes which mode is in flight,
  because the opportunity mode has a second half — the answer is mined into
  feedback records when the turn ends — and the turn ending is the only
  signal that the answer exists.

  `perform/3` marks the conversation busy before the model is asked, for the
  reason `Lemieux.Conversation.Dispatch` gives: the parse cannot, because a
  host policy may still refuse the command between the parse and the call.
  Gathering the evidence walks the whole transcript, so it runs inside the
  work handed to the host rather than on a draw loop.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Reflection

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "reflect",
      description: "review this session and suggest harness improvements",
      accepts_arguments?: true,
      action: {:reflect, :assessment}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_mode, %Conversation{busy?: true}),
    do: [{:say, "wait for it to finish, or /cancel before reflecting"}]

  def parse(mode, conversation) do
    case String.trim(mode) do
      "" -> reflect(conversation, :assessment)
      "opportunities" -> reflect(conversation, :opportunities)
      _other -> {:error, "usage: /reflect [opportunities]"}
    end
  end

  defp reflect(conversation, mode),
    do: {%{conversation | reflecting: mode}, [{:reflect, mode}]}

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:reflect, mode}) do
    session = host.session

    acc
    |> Dispatch.fold(host, {:reflection_started, mode})
    |> Dispatch.react(host, {:reflecting, mode})
    |> Dispatch.run(host, fn -> {:reflection_result, Reflection.reflect(session, mode: mode)} end)
  end
end
