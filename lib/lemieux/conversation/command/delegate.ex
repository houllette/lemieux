defmodule Lemieux.Conversation.Command.Delegate do
  @moduledoc """
  `/delegate [on | off]`: whether the agent may send investigations to
  read-only subagents.

  Delegation is a tool — `delegate` — so switching it is enabling or
  disabling that tool in the session, which is also what `/tools` does; this
  is the name a person looks for. It waits for the turn, like `/tools`,
  because it changes what the next request offers. A session that was given
  no `delegate` tool says so rather than enabling nothing.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @tool "delegate"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "delegate",
      description: "let the agent send work to subagents (on/off)",
      accepts_arguments?: true,
      action: :delegate_status,
      actions: [:delegate_status, {:set_delegate, true}],
      subcommands: [{"on | off", {:set_delegate, true}}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(arguments, conversation) do
    case {String.downcase(String.trim(arguments)), conversation} do
      {status, _conversation} when status in ["", "status"] -> [:delegate_status]
      {_switch, %Conversation{busy?: true}} -> Command.wait()
      {"on", _conversation} -> [{:set_delegate, true}]
      {"off", _conversation} -> [{:set_delegate, false}]
      _other -> [{:say, "usage: /delegate [on | off]"}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, _effect),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, :delegate_status) do
    message =
      case delegate(host.session) do
        nil -> absent()
        %{enabled?: true} -> "delegation on · the agent may send investigations to subagents"
        %{enabled?: false} -> "delegation off · /delegate on to allow it"
      end

    Dispatch.say(acc, host, message)
  end

  def perform(acc, host, {:set_delegate, enabled?}) do
    if delegate(host.session) do
      host.session
      |> switch(enabled?)
      |> switched(acc, host, enabled?)
    else
      Dispatch.say(acc, host, absent())
    end
  end

  defp switch(session, true), do: Session.enable_tools(session, [@tool])
  defp switch(session, false), do: Session.disable_tools(session, [@tool])

  defp switched({:ok, _names}, acc, host, enabled?) do
    acc
    |> Dispatch.react(host, :tools_changed)
    |> Dispatch.say(host, if(enabled?, do: "delegation on", else: "delegation off"))
  end

  defp switched({:error, reason}, acc, host, _enabled?),
    do: Dispatch.say(acc, host, "could not change delegation: #{Conversation.describe(reason)}")

  defp delegate(session), do: session |> Session.tool_status() |> Enum.find(&(&1.name == @tool))

  defp absent,
    do: "this session has no delegate tool · delegation is set up when a session starts"
end
