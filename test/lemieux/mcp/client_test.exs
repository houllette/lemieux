defmodule Lemieux.MCP.ClientTest do
  @moduledoc """
  Driven against a real subprocess speaking real JSON over real pipes.

  The fixture in `test/fixtures/mcp_server.py` is deliberately not built on an
  SDK: it answers exactly what the specification says, in the shapes a client
  has to cope with rather than the ones it would prefer — including a server
  that predates the stateless rewrite, and one that prints noise on stdout.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Client
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Tool.Result

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  defp start(mode, opts \\ []) do
    start_supervised!(
      {Client,
       [
         server: "fixture",
         transport: {Lemieux.MCP.Transport.Stdio, %{command: "python3", args: [@fixture, mode]}},
         timeout: :timer.seconds(10)
       ] ++ opts},
      id: {:client, mode, System.unique_integer([:positive])}
    )
  end

  describe "a server that speaks the current revision" do
    test "is recognised as modern, at the version it advertises" do
      info = start("modern") |> Client.info()

      assert info.era == :modern
      assert info.version == "2026-07-28"
      assert info.ready?
    end

    test "lists its tools" do
      assert {:ok, tools} = start("modern") |> Client.list_tools()

      assert %RemoteTool{} = echo = Enum.find(tools, &(&1.name == "echo"))
      assert echo.description == "Echoes the text it is given."
      assert echo.server == "fixture"
      assert echo.output_schema["type"] == "object"
      assert echo.annotations == %{"readOnlyHint" => true}
      assert echo.meta == %{"publisher" => "fixture"}
      assert echo.protocol_version == "2026-07-28"
      assert echo.server_info == %{"name" => "fixture", "version" => "1.0.0"}
    end

    test "calls a tool and returns what it said" do
      assert {:ok, %Result{model_text: "echo: hello", structured_content: structured}} =
               start("modern") |> Client.call_tool("echo", %{"text" => "hello"})

      assert structured == %{"echo" => "echo: hello"}
    end

    test "a tool that fails is an error the model can read, not a broken call" do
      assert {:error, %Result{model_text: "that did not work"}} =
               start("modern") |> Client.call_tool("explode", %{})
    end

    test "calling a tool the server does not have is an error naming it" do
      assert {:error, message} = start("modern") |> Client.call_tool("nope", %{})
      assert message =~ "nope"
    end
  end

  describe "a server from before the stateless rewrite" do
    # The whole point of the probe: this server rejects `server/discover`, and
    # the client has to notice and fall back rather than give up.
    test "is recognised as legacy, and handshaken with" do
      info = start("legacy") |> Client.info()

      assert info.era == :legacy
      assert info.version == "2025-11-25"
      assert info.ready?
    end

    test "lists and calls its tools just the same" do
      client = start("legacy")

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1.name == "echo"))

      assert {:ok, %Result{model_text: "echo: hi"}} =
               Client.call_tool(client, "echo", %{"text" => "hi"})
    end
  end

  describe "tolerating what servers actually do" do
    test "a tool with no input schema is dropped, and the rest still work" do
      assert {:ok, tools} = start("modern") |> Client.list_tools()

      refute Enum.any?(tools, &(&1.name == "unusable"))
      assert Enum.any?(tools, &(&1.name == "echo"))
    end

    # The specification lets clients on other transports ignore `x-mcp-header`
    # entirely, and there are no headers here to mirror into.
    test "a header annotation that only matters over HTTP does not cost a tool here" do
      assert {:ok, tools} = start("modern") |> Client.list_tools()

      assert Enum.any?(tools, &(&1.name == "badly_routed"))
    end

    # Servers print banners and warnings to stdout despite being asked not to.
    test "noise on stdout does not stop the client working" do
      client = start("broken")

      assert Client.info(client).ready?

      assert {:ok, %Result{model_text: "echo: still here"}} =
               Client.call_tool(client, "echo", %{"text" => "still here"})
    end
  end

  describe "when a server cannot be used" do
    test "a version nobody has in common is reported, not guessed around" do
      info = start("picky") |> Client.info()

      refute info.ready?
      assert info.failure =~ "no protocol version in common"
    end

    # The isolation that matters: a session with a broken server keeps running.
    test "a client that never connected answers errors instead of dying" do
      client =
        start_supervised!(
          {Client,
           server: "gone",
           transport: {Lemieux.MCP.Transport.Stdio, %{command: "definitely-not-a-real-command"}}},
          id: :missing_command
        )

      assert {:error, message} = Client.list_tools(client)
      assert message =~ "definitely-not-a-real-command"
      assert Process.alive?(client)
    end

    test "a server that dies mid-session reports it rather than hanging" do
      client = start("modern")
      assert {:ok, _tools} = Client.list_tools(client)

      # Kill the server out from under the client.
      %{transport: %{port: port}} = :sys.get_state(client)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      System.cmd("kill", ["-9", to_string(os_pid)])

      assert {:error, _message} = Client.call_tool(client, "echo", %{"text" => "anyone there?"})
      assert Process.alive?(client)
    end
  end
end
