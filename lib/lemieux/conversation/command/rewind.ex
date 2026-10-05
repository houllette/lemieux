defmodule Lemieux.Conversation.Command.Rewind do
  @moduledoc """
  `/rewind N [--force]`: put back the files the agent changed in its last `N`
  turns, newest first.

  `/undo` repeated, through `Lemieux.Checkpoint.rewind/4`, which stops early
  when there is nothing left to undo. The same waiting, conflicts and note to
  the model as `Lemieux.Conversation.Command.Undo`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Checkpoint
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Command.Undo
  alias Lemieux.Conversation.Dispatch

  @usage "usage: /rewind N [--force] · N is how many of the agent's turns to undo"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "rewind",
      description: "put back the files the agent changed in its last N turns",
      accepts_arguments?: true,
      action: {:rewind, 1, false}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}),
    do: Command.wait("wait for the turn to finish, or /cancel it, before rewinding")

  def parse(arguments, _conversation) do
    words = String.split(arguments, ~r/\s+/, trim: true)
    {flags, counts} = Enum.split_with(words, &(&1 in ["--force", "force"]))

    with [count] <- counts,
         {turns, ""} when turns > 0 <- Integer.parse(count) do
      [{:rewind, turns, flags != []}]
    else
      _usage -> [{:say, @usage}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{checkpoints: nil} = host, _effect),
    do: Dispatch.say(acc, host, Undo.off())

  def perform(acc, host, {:rewind, turns, force?}) do
    %{checkpoints: store, id: id} = host
    environment = Dispatch.environment(host)

    Dispatch.run(acc, host, fn ->
      {:rewind_result,
       Checkpoint.rewind(store, id, turns, environment: environment, force: force?)}
    end)
  end
end
