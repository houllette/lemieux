defmodule Lemieux.Conversation.Command.Tools do
  @moduledoc """
  `/tools [list | enable NAME... | disable NAME...]`: the tool catalog.

  Listing is allowed mid-turn; enabling and disabling wait, because they
  change what the next request offers. Both mutations are atomic in the
  session — an unknown name leaves the set unchanged and is reported — and
  the host is told its catalog is stale rather than handed a fresh one, for
  a host that keeps none.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @usage "usage: /tools [list | enable NAME... | disable NAME...]"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "tools",
      description: "list, enable, or disable tools",
      accepts_arguments?: true,
      action: :tools_status,
      actions: [:tools_status, {:enable_tools, ["NAME"]}, {:disable_tools, ["NAME"]}],
      subcommands: [
        {"enable NAME...", {:enable_tools, ["NAME"]}},
        {"disable NAME...", {:disable_tools, ["NAME"]}}
      ]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:tools_status]

  def parse(command, %Conversation{busy?: true}) do
    if mutation?(command), do: Command.wait(), else: tools(command)
  end

  def parse(command, _conversation), do: tools(command)

  defp mutation?(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> then(&match?([action | _rest] when action in ["enable", "disable"], &1))
  end

  defp tools(command) do
    case String.split(String.trim(command), ~r/\s+/, trim: true) do
      ["list"] -> [:tools_status]
      ["enable" | names] when names != [] -> [{:enable_tools, names}]
      ["disable" | names] when names != [] -> [{:disable_tools, names}]
      _other -> [{:say, @usage}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :tools_status) do
    statuses = Session.tool_status(host.session)

    acc
    |> Dispatch.react(host, {:tool_statuses, statuses})
    |> Dispatch.fold(host, {:tools_status, statuses})
  end

  def perform(acc, host, {:enable_tools, names}),
    do: access(acc, host, Session.enable_tools(host.session, names))

  def perform(acc, host, {:disable_tools, names}),
    do: access(acc, host, Session.disable_tools(host.session, names))

  defp access(acc, host, {:ok, _names}), do: Dispatch.react(acc, host, :tools_changed)

  defp access(acc, host, {:error, reason}),
    do: Dispatch.say(acc, host, "could not change tools: #{Conversation.describe(reason)}")
end
