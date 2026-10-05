defmodule Lemieux.MCP.HTTPTest do
  @moduledoc """
  Driven against the fixture serving real HTTP on a real socket.

  The fixture validates the headers this revision requires and answers `400`
  with a `HeaderMismatch` when they disagree with the body — so these tests
  fail if the transport stops sending them, which is the failure that would
  otherwise show up only against somebody else's server.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Client
  alias Lemieux.MCP.Transport.HTTP
  alias Lemieux.Tool.Result

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  setup do
    %{port: free_port()}
  end

  # Let the kernel choose among ports which are actually free. Folding
  # scheduler-local unique integers into a small range can assign two
  # concurrent fixture servers the same port.
  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # Returns the port the fixture is actually answering on, which is not always
  # the one asked for.
  defp serve(mode, port, attempts \\ 3) do
    server =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        :hide,
        line: 1024,
        args: [@fixture, mode, "--http", to_string(port)]
      ])

    # Captured now, not in on_exit: by then the test process that owns the port
    # has finished, the port is closed, and Port.info returns nil — which is
    # how a run leaves a trail of orphaned servers holding their pipes open.
    {:os_pid, os_pid} = Port.info(server, :os_pid)

    on_exit(fn -> System.cmd("kill", ["-9", to_string(os_pid)], stderr_to_stdout: true) end)

    case await_listening(port, server) do
      :ok ->
        port

      # `free_port/0` names a port by binding one and letting go, so between
      # that and the fixture binding it another case doing the same thing can
      # take it, and the fixture exits instead of listening. Connecting is not
      # enough to notice: the squatter is listening, so the connection succeeds
      # and the client goes on to talk to a server that never answers MCP —
      # which arrives ten seconds later as `{:error, "timeout"}` and looks like
      # a broken transport. Watching for the fixture's own exit is what tells
      # the two apart, and the next port is a fresh one because the squatter
      # holds this one for the rest of its own test.
      {:error, :exited} when attempts > 1 ->
        serve(mode, free_port(), attempts - 1)

      {:error, reason} ->
        flunk("the fixture never listened on #{port}: #{inspect(reason)}")
    end
  end

  defp await_listening(_port, server) do
    receive do
      {^server, {:data, {:eol, "ready"}}} -> :ok
      {^server, {:exit_status, _status}} -> {:error, :exited}
    after
      5_000 -> {:error, :startup_timeout}
    end
  end

  defp start(mode, port) do
    port = serve(mode, port)

    start_supervised!(
      {Client,
       server: "fixture",
       transport: {HTTP, %{url: "http://127.0.0.1:#{port}/mcp"}},
       timeout: :timer.seconds(10)},
      id: {:http_client, port}
    )
  end

  describe "a modern server" do
    test "is recognised, and its headers are accepted", %{port: port} do
      info = start("modern", port) |> Client.info()

      assert info.era == :modern
      assert info.version == "2026-07-28"
      assert info.ready?, info.failure || ""
    end

    test "lists and calls tools", %{port: port} do
      client = start("modern", port)

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1.name == "echo"))

      assert {:ok, %Result{model_text: "echo: over http"}} =
               Client.call_tool(client, "echo", %{"text" => "over http"})
    end

    # The fixture answers 400 HeaderMismatch unless Mcp-Method, Mcp-Name and
    # MCP-Protocol-Version all agree with the body, so a passing call is proof
    # the transport sent them.
    test "a tool call carries the headers the revision requires", %{port: port} do
      assert {:ok, _output} =
               start("modern", port) |> Client.call_tool("echo", %{"text" => "hi"})
    end
  end

  describe "parameters a server asks to be mirrored into headers" do
    test "are sent as Mcp-Param headers", %{port: port} do
      client = start("modern", port)

      # Listing first is what teaches the transport which arguments to mirror.
      assert {:ok, _tools} = Client.list_tools(client)

      assert {:ok, output} =
               Client.call_tool(client, "routed", %{"region" => "us-west1", "query" => "SELECT 1"})

      assert output.model_text == "region header: us-west1"
    end

    # Required by the specification: one malformed annotation costs one tool,
    # not the whole list.
    test "a tool whose annotations are unusable is left out, and the rest work", %{port: port} do
      assert {:ok, tools} = start("modern", port) |> Client.list_tools()

      refute Enum.any?(tools, &(&1.name == "badly_routed"))
      assert Enum.any?(tools, &(&1.name == "echo"))
      assert Enum.any?(tools, &(&1.name == "routed"))
    end
  end

  describe "an event stream" do
    # A server may answer either way, per request, and a client must cope with
    # both. This one streams a progress notification before the response.
    test "is read past its notifications to the response", %{port: port} do
      client = start("sse", port)

      assert {:ok, %Result{model_text: "echo: streamed"}} =
               Client.call_tool(client, "echo", %{"text" => "streamed"})
    end

    # A changed tool list announced beside an unrelated answer is still a
    # changed tool list.
    test "a list change announced in it is heard, and the tools listed again", %{port: port} do
      port = serve("sse", port)

      client =
        start_supervised!(
          {Client,
           server: "fixture",
           transport: {HTTP, %{url: "http://127.0.0.1:#{port}/mcp"}},
           timeout: :timer.seconds(10),
           notify: self()},
          id: {:http_client, :notify, port}
        )

      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, %Result{model_text: "changed"}} = Client.call_tool(client, "change", %{})

      assert_receive {:mcp_tools_changed, %{client: ^client, tools: tools}}, 5_000
      assert Enum.any?(tools, &(&1.name == "added"))
    end
  end

  describe "concurrency" do
    test "HTTP calls run independently of each other", %{port: port} do
      client = start("modern", port)
      assert Client.info(client).mode == :independent

      tasks =
        for n <- 1..4,
            do: Task.async(fn -> Client.call_tool(client, "echo", %{"text" => "#{n}"}) end)

      answers = Enum.map(tasks, &Task.await(&1, 10_000))

      assert Enum.sort(for {:ok, %Result{model_text: text}} <- answers, do: text) ==
               ["echo: 1", "echo: 2", "echo: 3", "echo: 4"]
    end
  end

  describe "a server from before the stateless rewrite" do
    test "is detected through the body of its 400, and handshaken with", %{port: port} do
      info = start("legacy", port) |> Client.info()

      assert info.era == :legacy
      assert info.version == "2025-11-25"
      assert info.ready?, info.failure || ""
    end

    # The fixture rejects anything after initialize that does not echo the
    # session it minted, so working at all proves the header is carried.
    test "its session id is carried on every later request", %{port: port} do
      client = start("legacy", port)

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1.name == "echo"))

      assert {:ok, %Result{model_text: "echo: hi"}} =
               Client.call_tool(client, "echo", %{"text" => "hi"})
    end
  end

  describe "when the server is not there" do
    test "a refused connection is reported rather than crashing the client" do
      client =
        start_supervised!(
          {Client, server: "gone", transport: {HTTP, %{url: "http://127.0.0.1:1/mcp"}}},
          id: :refused
        )

      refute Client.info(client).ready?
      assert {:error, _message} = Client.list_tools(client)
      assert Process.alive?(client)
    end
  end
end
