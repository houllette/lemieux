defmodule Lemieux.Conversation.Command.Prompts do
  @moduledoc """
  `/prompts`: the prompts the connected MCP servers offer, and sending one.

  A server's prompts are canned requests its authors wrote — "review this
  pull request", "summarise the incident" — and a person uses one as a slash
  command: `/mcp__github__review_pr 42`. They are not in the command registry
  because they come and go with the servers, so `Lemieux.Conversation` reads
  an unknown `/mcp__…` name as `{:mcp_prompt, name, arguments}` and this
  module finds it when it is performed, where the servers are. The name is
  `Lemieux.MCP.prompt_command/2`'s, the same one this listing shows.

  Arguments are `name=value` pairs (quoted when they have spaces), or plain
  words when the prompt takes one argument, or in its declared order. A
  required argument left out is named before anything is sent. The filled-in
  prompt is sent as the person's message: a turn, visible and cancellable
  like one they typed.

  The servers are the session's connected clients that declared prompts
  (`Lemieux.Session.mcp_clients/2`), so a server that offers prompts and no
  tools is listed and invocable like any other.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.MCP
  alias Lemieux.Session

  @typedoc "One prompt a server offers, as the listing shows it."
  @type prompt :: %{
          command: String.t(),
          server: String.t(),
          name: String.t(),
          description: String.t() | nil,
          arguments: [map()]
        }

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "prompts",
      description: "list the prompts MCP servers offer",
      action: :mcp_prompts,
      actions: [:mcp_prompts, {:mcp_prompt, "COMMAND", "ARGUMENTS"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:mcp_prompts]

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, _effect),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, :mcp_prompts) do
    session = host.session
    Dispatch.run(acc, host, fn -> {:mcp_prompts_result, list(session)} end)
  end

  def perform(acc, host, {:mcp_prompt, command, arguments}) do
    session = host.session

    Dispatch.run(acc, host, fn ->
      {:mcp_prompt_result, command, fetch(session, command, arguments)}
    end)
  end

  @doc """
  Every prompt the session's connected servers offer. A server that fails to
  answer is left out rather than failing the listing: one broken server is
  not a reason to hide the others' prompts.
  """
  @spec list(session :: pid()) :: {:ok, [prompt()]}
  def list(session) do
    prompts =
      session
      |> clients()
      |> Enum.flat_map(fn {server, client} ->
        case MCP.list_prompts(client) do
          {:ok, prompts} -> Enum.map(prompts, &prompt(server, &1))
          {:error, _reason} -> []
        end
      end)

    {:ok, prompts}
  end

  # The session's connected clients, rather than its tools: a server that
  # offers prompts and no tools has no tool to find it by, and was the one
  # server this listing could never show. Only servers that declared prompts
  # are asked; the rest would answer "method not found" on every listing.
  defp clients(session) do
    for %{name: server, client: client, capabilities: capabilities} <-
          Session.mcp_clients(session),
        Map.has_key?(capabilities, "prompts"),
        do: {server, client}
  end

  defp prompt(server, %{} = prompt) do
    name = prompt["name"] || prompt[:name]

    %{
      command: MCP.prompt_command(server, name),
      server: server,
      name: name,
      description: prompt["description"] || prompt[:description],
      arguments: prompt["arguments"] || prompt[:arguments] || []
    }
  end

  defp fetch(session, command, text) do
    with {:ok, prompts} <- list(session),
         {:ok, prompt} <- find(prompts, command),
         {:ok, arguments} <- arguments(text, prompt.arguments),
         {:ok, client} <- client(session, prompt.server) do
      MCP.prompt(client, prompt.name, arguments)
    end
  end

  defp find(prompts, command) do
    case Enum.find(prompts, &(&1.command == command)) do
      nil -> {:error, "no connected MCP server offers this prompt · /prompts lists them"}
      prompt -> {:ok, prompt}
    end
  end

  defp client(session, server) do
    case List.keyfind(clients(session), server, 0) do
      {^server, client} -> {:ok, client}
      nil -> {:error, "the #{server} server is not connected"}
    end
  end

  @doc """
  Reads the text after a prompt's command into its arguments, given the
  prompt's declared ones. See the moduledoc for the grammar.
  """
  @spec arguments(text :: String.t(), declared :: [map()]) ::
          {:ok, %{optional(String.t()) => String.t()}} | {:error, String.t()}
  def arguments(text, declared) when is_binary(text) and is_list(declared) do
    words = OptionParser.split(text)
    {pairs, plain} = Enum.split_with(words, &String.contains?(&1, "="))

    named =
      Map.new(pairs, fn pair ->
        [name, value] = String.split(pair, "=", parts: 2)
        {name, value}
      end)

    open = declared |> Enum.map(&argument_name/1) |> Enum.reject(&Map.has_key?(named, &1))

    positional =
      case {open, plain} do
        {_open, []} -> %{}
        {[only], plain} -> %{only => Enum.join(plain, " ")}
        {open, plain} -> open |> Enum.zip(plain) |> Map.new()
      end

    arguments = Map.merge(positional, named)

    case Enum.reject(required(declared), &Map.has_key?(arguments, &1)) do
      [] -> {:ok, arguments}
      missing -> {:error, "needs #{Enum.join(missing, ", ")} · write them as name=value"}
    end
  end

  defp argument_name(argument), do: argument["name"] || argument[:name]

  defp required(declared) do
    for argument <- declared,
        argument["required"] == true or argument[:required] == true,
        do: argument_name(argument)
  end

  @doc "The listing, as `/prompts` says it."
  @spec describe(prompts :: [prompt()]) :: String.t()
  def describe([]),
    do: "no connected MCP server offers prompts"

  def describe(prompts) do
    lines =
      Enum.map(prompts, fn prompt ->
        arguments =
          case Enum.map(prompt.arguments, &argument_label/1) do
            [] -> ""
            labels -> " " <> Enum.join(labels, " ")
          end

        description = if prompt.description, do: " — #{prompt.description}", else: ""
        "/#{prompt.command}#{arguments}#{description}"
      end)

    Enum.join(["MCP prompts · type one to send it as your message" | lines], "\n")
  end

  defp argument_label(argument) do
    name = argument_name(argument)
    if argument["required"] == true or argument[:required] == true, do: name, else: "[#{name}]"
  end
end
