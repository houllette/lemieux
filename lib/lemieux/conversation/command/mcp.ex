defmodule Lemieux.Conversation.Command.MCP do
  @moduledoc """
  `/mcp [list | add PATH | remove NAME | reconnect [NAME]]`: the MCP servers.

  Listing is allowed mid-turn; the three mutations wait, because they change
  the catalog the next request is built from. Each mutation is run through
  the host's `:run` — connecting takes a moment — and the listing is fetched
  by the same work that made the change, so a host that ran it off its draw
  loop does not come back on to make a second call. `nil` rather than `[]`
  for the listing when nothing changed: an empty listing is a fact about
  the servers, and "no listing" is a fact about the change.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.MCP.Config, as: MCPConfig
  alias Lemieux.Session

  @usage "usage: /mcp [list | add PATH | remove NAME | reconnect [NAME]]"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "mcp",
      description: "list and manage MCP servers",
      accepts_arguments?: true,
      action: :mcp_status,
      actions: [:mcp_status, {:mcp_add, "PATH"}, {:mcp_remove, "NAME"}, {:mcp_reconnect, :all}],
      subcommands: [
        {"add PATH", {:mcp_add, "PATH"}},
        {"remove NAME", {:mcp_remove, "NAME"}},
        {"reconnect [NAME]", {:mcp_reconnect, :all}}
      ]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:mcp_status]

  def parse(command, %Conversation{busy?: true}) do
    if mutation?(command), do: Command.wait(), else: mcp(command)
  end

  def parse(command, _conversation), do: mcp(command)

  defp mutation?(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> then(&match?([action | _rest] when action in ["add", "remove", "reconnect"], &1))
  end

  defp mcp(command) do
    case String.split(String.trim(command), ~r/\s+/, parts: 2, trim: true) do
      ["list"] -> [:mcp_status]
      ["add", path] -> [{:mcp_add, path}]
      ["remove", name] -> [{:mcp_remove, name}]
      ["reconnect"] -> [{:mcp_reconnect, :all}]
      ["reconnect", name] -> [{:mcp_reconnect, name}]
      _other -> [{:say, @usage}]
    end
  end

  # Off the host's draw loop: the listing waits for startup connections to
  # settle, and a `/mcp` typed while a slow server was still connecting froze
  # the screen for as long as the server took. The answer is
  # `{:mcp_listing, statuses}`, which `Lemieux.Conversation.Dispatch.answer/3`
  # hands on as the listing it always was.
  @impl Lemieux.Conversation.Command
  def perform(acc, host, :mcp_status) do
    session = host.session

    Dispatch.run(acc, host, fn -> {:mcp_listing, Session.mcp_status(session, :infinity)} end)
  end

  def perform(acc, host, {:mcp_add, path}) do
    session = host.session

    change(acc, host, "add", fn ->
      with {:ok, servers} <- MCPConfig.read(path) do
        Session.add_mcp_servers(session, servers)
      end
    end)
  end

  def perform(acc, host, {:mcp_remove, name}) do
    session = host.session

    change(acc, host, "remove #{name}", fn -> Session.remove_mcp_server(session, name) end)
  end

  def perform(acc, host, {:mcp_reconnect, target}) do
    session = host.session

    change(acc, host, "reconnect #{target}", fn -> Session.reconnect_mcp(session, target) end)
  end

  defp change(acc, host, action, change) do
    session = host.session

    acc
    |> Dispatch.react(host, {:mcp_started, action})
    |> Dispatch.run(host, fn ->
      result = change.()
      statuses = if result == :ok, do: Session.mcp_status(session)
      {:mcp_result, action, result, statuses}
    end)
  end
end
