defmodule Lemieux.Conversation.Command.Redo do
  @moduledoc """
  `/redo [--force]`: take back the last `/undo` — put every file it changed
  back the way it was just before it ran.

  An undo cannot tell a change the person saved while one of the agent's
  commands was running from the command's own change, so it puts both back.
  Without a way back, that would make `/undo` the one command a careful
  person avoids. `Lemieux.Checkpoint.undo/3` saves what each file held
  before it wrote anything; this puts that back through
  `Lemieux.Checkpoint.redo/3`. A file changed since the undo is left alone
  and named unless `--force`, by the same reasoning as `/undo`'s. The turn
  can be undone again afterwards.

  The answer comes back as `{:undo_result, result}`: an undo taken back is
  reported, and noted for the model, the way an undo is, and every front
  end already routes that answer.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Checkpoint
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Command.Undo
  alias Lemieux.Conversation.Dispatch

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "redo",
      description: "take back the last /undo",
      accepts_arguments?: true,
      action: {:redo, false}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}),
    do: Command.wait("wait for the turn to finish, or /cancel it, before redoing")

  def parse(arguments, _conversation) do
    case String.trim(arguments) do
      "" -> [{:redo, false}]
      flag when flag in ["--force", "force"] -> [{:redo, true}]
      _other -> [{:say, "usage: /redo [--force]"}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{checkpoints: nil} = host, _effect),
    do: Dispatch.say(acc, host, Undo.off())

  def perform(acc, host, {:redo, force?}) do
    %{checkpoints: store, id: id} = host
    environment = Dispatch.environment(host)

    Dispatch.run(acc, host, fn ->
      {:undo_result, Checkpoint.redo(store, id, environment: environment, force: force?)}
    end)
  end

  @doc "What `/redo` says when no undo is left to take back."
  @spec nothing() :: String.t()
  def nothing, do: "nothing to redo · /redo takes back the last /undo of this session"
end
