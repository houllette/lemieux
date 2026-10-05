defmodule Lemieux.MCP.ReferencesTest do
  @moduledoc """
  A connected server's resources as `@server:uri` references, and a server
  that offers prompts and resources but no tools, inside a real session.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Conversation.Command.Prompts
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  # A server offering prompts and resources and no tools, spoken in memory.
  defmodule Library do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    @impl true
    def configure(_config, _opts), do: {:ok, %{}}
    @impl true
    def connect(config), do: {:ok, config}

    @impl true
    def call(state, %{"id" => id, "method" => method} = request, _timeout),
      do: {:ok, %{"id" => id, "result" => result(method, request["params"] || %{})}, state}

    @impl true
    def notify(state, _message), do: {:ok, state}
    @impl true
    def prepare_tools(state, tools), do: {tools, state}
    @impl true
    def close(_state), do: :ok

    defp result("server/discover", _params),
      do: %{
        "supportedVersions" => ["2026-07-28"],
        "capabilities" => %{"prompts" => %{}, "resources" => %{}}
      }

    defp result("tools/list", _params), do: %{"tools" => []}

    defp result("prompts/list", _params),
      do: %{
        "prompts" => [
          %{"name" => "review", "arguments" => [%{"name" => "path", "required" => true}]}
        ]
      }

    defp result("prompts/get", params),
      do: %{
        "messages" => [
          %{
            "role" => "user",
            "content" => %{
              "type" => "text",
              "text" => "Please review " <> params["arguments"]["path"]
            }
          }
        ]
      }

    defp result("resources/list", _params),
      do: %{"resources" => [%{"uri" => "mem://notes", "name" => "notes"}]}

    defp result("resources/read", %{"uri" => "mem://notes" = uri}),
      do: %{
        "contents" => [%{"uri" => uri, "mimeType" => "text/plain", "text" => "remember the milk"}]
      }
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_mcp_references_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start(context, script) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        subscriber: self(),
        tools: [],
        mcp_servers: [%{"name" => "library", "transport" => "library"}],
        mcp_transports: %{"library" => __MODULE__.Library}
      )

    # Connections settle off the session process; this answers once they have.
    Session.mcp_status(session, 30_000)

    {session, provider}
  end

  defp prompted_attachments(session, text) do
    id = Session.id(session)
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    [user] = for %{type: :user} = entry <- Session.snapshot(session).entries, do: entry
    Map.get(user.payload, "attachments", [])
  end

  describe "@server:uri in a prompt" do
    test "attaches what the server holds under that URI", context do
      {session, _provider} = start(context, [Scripted.complete("noted")])

      assert [attachment] = prompted_attachments(session, "use @library:mem://notes please")

      assert %{
               "kind" => "resource",
               "path" => "library:mem://notes",
               "server" => "library",
               "uri" => "mem://notes"
             } = attachment

      assert attachment["text"] =~ "1\tremember the milk"
    end

    test "says so when no connected server has that name", context do
      {session, _provider} = start(context, [Scripted.complete("noted")])

      assert [%{"kind" => "error", "text" => text}] =
               prompted_attachments(session, "use @nobody:mem://notes")

      assert text =~ "no connected MCP server is called nobody"
    end
  end

  describe "a server offering prompts and resources but no tools" do
    test "is found by /prompts", context do
      {session, _provider} = start(context, [])

      assert {:ok, [%{command: command, server: "library", name: "review"}]} =
               Prompts.list(session)

      assert command == Lemieux.MCP.prompt_command("library", "review")
    end

    test "has its prompt fetched when the prompt's command is invoked", context do
      {session, _provider} = start(context, [])
      command = Lemieux.MCP.prompt_command("library", "review")

      # A host that keeps the work's answer instead of folding it, so the test
      # sees what the server sent back without a turn being started.
      host =
        Dispatch.new(
          session: session,
          id: Session.id(session),
          say: fn acc, text -> [{:say, text} | acc] end,
          write: fn acc, _text -> acc end,
          fold: fn acc, event -> [{:fold, event} | acc] end,
          run: fn acc, work -> [{:answer, work.()} | acc] end,
          react: fn acc, _reaction -> acc end
        )

      assert [{:answer, {:mcp_prompt_result, ^command, {:ok, text}}}] =
               Dispatch.perform([], host, {:mcp_prompt, command, "path=lib/a.ex"})

      assert text =~ "Please review lib/a.ex"
    end

    test "offers its resources to a host", context do
      {session, _provider} = start(context, [])

      assert [%{server: "library", uri: "mem://notes", name: "notes"}] =
               Session.mcp_resources(session)
    end
  end
end
