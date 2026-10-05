defmodule Lemieux.Conversation.Command.Unsteer do
  @moduledoc """
  `/unsteer`: take back the steer still waiting for the next model request.

  A line typed while a turn runs is a steer, and the session holds it until
  its next request — until then it can be taken back. The only way to do
  that used to be Cmd-Z, which Terminal.app, iTerm2 and VS Code keep for
  their own Undo and never send: the screen said "Cmd+Z revokes it" about a
  key most people's terminals swallow. A command reaches every terminal.

  Runs mid-turn, because that is the only time a steer can be waiting. The
  screen performs it itself, since the steer is also a row it drew and has to
  take away (`Lemieux.TUI.Submission.unsteer/1`); the shared half here is for
  a front end that does not, and revokes the newest steer the session still
  holds.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "unsteer",
      description: "take back the steer waiting for the next model request",
      action: :unsteer
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:unsteer]

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, :unsteer),
    do: Dispatch.say(acc, host, nothing_waiting())

  def perform(acc, host, :unsteer) do
    case host.session |> Session.info() |> Map.get(:queued_steers, []) |> List.last() do
      nil -> Dispatch.say(acc, host, nothing_waiting())
      text -> Dispatch.say(acc, host, revoked(Session.revoke_steer(host.session, text)))
    end
  end

  @doc "What `/unsteer` says when there is no steer to take back."
  @spec nothing_waiting() :: String.t()
  def nothing_waiting, do: "no steer is waiting"

  @doc """
  What `/unsteer` says once `Lemieux.Session.revoke_steer/2` has answered,
  or once the session turned out to have stopped (`{:error, :not_running}`,
  which a front end that catches the call's exit can pass).
  """
  @spec revoked(result :: :ok | {:error, :already_sent | :not_running}) :: String.t()
  def revoked(:ok), do: "steer revoked before the next model request"
  def revoked({:error, :already_sent}), do: "steer already sent"
  def revoked({:error, :not_running}), do: "the session stopped before the steer was sent"
end
