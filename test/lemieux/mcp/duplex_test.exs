defmodule Lemieux.MCP.DuplexTest do
  @moduledoc """
  What a client does once its handshake is over, against a stdio fixture that
  answers requests concurrently: several calls in flight, calls withdrawn when
  their caller goes away, deadlines that count silence rather than time, and
  what a server says without being asked.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.MCP.Transport.Stdio
  alias Lemieux.Tool.Result
  alias LemieuxTest.CommandGate

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  defp start(mode \\ "duplex", opts \\ []) do
    start_supervised!(
      {Client,
       [
         server: "fixture",
         transport: {Stdio, %{command: "python3", args: [@fixture, mode]}},
         timeout: :timer.seconds(10)
       ] ++ opts},
      id: {:duplex_client, System.unique_integer([:positive])}
    )
  end

  defp text({:ok, %Result{model_text: text}}), do: text

  # Waits for the fixture to have recorded a cancellation: it arrives as a
  # notification the server handles on its own schedule.
  defp cancelled(client),
    do: client |> Client.call_tool("cancelled", %{"wait" => true}) |> text() |> JSON.decode!()

  defp held_call(client, gate) do
    {:ok, port} = :inet.port(gate.listener)
    Client.call_tool(client, "slow", %{"control_port" => port})
  end

  test "a stdio client is duplex once the handshake is over" do
    assert Client.info(start()).mode == :duplex
  end

  test "a fast call is answered while a slow one on the same server is still running" do
    client = start()
    gate = CommandGate.new()
    slow = Task.async(fn -> held_call(client, gate) end)
    socket = CommandGate.ready(gate)
    fast = Task.async(fn -> Client.call_tool(client, "fast", %{"text" => "hi"}) end)

    assert text(Task.await(fast)) == "fast: hi"
    assert Task.yield(slow, 0) == nil
    assert :ok = CommandGate.release(socket)
    assert text(Task.await(slow)) == "released"
  end

  test "a call whose caller goes away is withdrawn, and the server hears about it" do
    client = start()

    gate = CommandGate.new()
    caller = spawn(fn -> held_call(client, gate) end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    socket = CommandGate.ready(gate)
    Process.exit(caller, :kill)

    assert [_withdrawn] = cancelled(client)
    assert :ok = CommandGate.closed(socket)
    # And the server is free for the next call rather than waiting it out.
    assert text(Client.call_tool(client, "fast", %{"text" => "next"})) == "fast: next"
  end

  test "a deadline counts silence: progress keeps a long call alive" do
    client = start("duplex", tool_timeout: 400)

    args = %{"seconds" => 1.2, "progress" => true, "interval" => 0.05}
    assert text(Client.call_tool(client, "slow", args)) =~ "slept"
  end

  test "a silent call past its deadline fails, and is cancelled on the server" do
    client = start("duplex", tool_timeout: 300)

    assert {:error, message} = Client.call_tool(client, "slow", %{"seconds" => 3})
    assert message =~ "did not answer within"
    assert [_withdrawn] = cancelled(client)
  end

  test "a changed tool list is listed again and announced" do
    client = start("duplex", notify: self())
    assert {:ok, tools} = Client.list_tools(client)
    refute Enum.any?(tools, &(&1.name == "added"))

    assert text(Client.call_tool(client, "change", %{})) == "changed"

    assert_receive {:mcp_tools_changed, %{server: "fixture", client: ^client, tools: changed}}

    assert %RemoteTool{client: ^client} = Enum.find(changed, &(&1.name == "added"))
  end

  test "a ping from the server is answered" do
    assert text(start() |> Client.call_tool("ping_me", %{})) == "pong received"
  end

  test "a legacy server works the same way after its handshake" do
    client = start("legacy_duplex")
    assert Client.info(client).era == :legacy

    gate = CommandGate.new()
    slow = Task.async(fn -> held_call(client, gate) end)
    socket = CommandGate.ready(gate)
    fast = Task.async(fn -> Client.call_tool(client, "fast", %{"text" => "old"}) end)
    assert text(Task.await(fast)) == "fast: old"
    assert Task.yield(slow, 0) == nil
    assert :ok = CommandGate.release(socket)
    assert text(Task.await(slow)) == "released"
  end

  describe "tools whose names no provider accepts" do
    test "are offered under a valid name, still route by their own, and are reported" do
      client = start()
      assert {:ok, tools} = Client.list_tools(client)

      dotted = Enum.find(tools, &(&1.name == "files.read"))
      offered = RemoteTool.qualified_name(dotted)
      assert ReqLLM.Tool.valid_name?(offered)
      assert offered =~ ~r/\Afixture__files_read_[0-9a-f]{6}\z/

      # The schema had no "type"; it is read as the object it must be.
      assert dotted.schema["type"] == "object"

      assert {:ok, %Result{model_text: "files.read ran"}} = MCP.call_tool(dotted, %{}, %{})
      assert Enum.any?(Client.info(client).notices, &(&1 =~ "files.read"))
    end
  end

  describe "prompts and resources" do
    test "are listed and read from a server that declares them" do
      client = start()

      assert {:ok, [%{"name" => "review"}]} = Client.list_prompts(client)
      assert {:ok, text} = MCP.prompt(client, "review", %{"path" => "lib/a.ex"})
      assert text =~ "Please review lib/a.ex"

      assert {:ok, resources} = MCP.list_resources(client)
      assert Enum.map(resources, & &1["uri"]) == ["fixture://notes", "fixture://logo"]
      assert {:ok, "remember the milk"} = MCP.resource(client, "fixture://notes")
      assert {:ok, logo} = MCP.resource(client, "fixture://logo")
      assert logo =~ "image/png"
    end

    test "a server that did not declare prompts has none, and is not asked" do
      assert {:ok, []} = start("modern") |> Client.list_prompts()
    end

    test "a prompt command name is valid for any server name" do
      assert MCP.prompt_command("github", "review") == "mcp__github__review"
      assert MCP.prompt_command("my docs", "summarise.all") =~ ~r/\Amcp__my_docs__summarise_all_/
    end
  end

  describe "a server that goes away" do
    test "fails every call in flight at once, rather than leaving them waiting" do
      client = start()
      gate = CommandGate.new()
      slow = Task.async(fn -> held_call(client, gate) end)
      socket = CommandGate.ready(gate)

      %{transport: %{port: port}} = :sys.get_state(client)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      System.cmd("kill", ["-9", to_string(os_pid)])
      assert :ok = CommandGate.closed(socket)

      assert {:error, message} = Task.await(slow, 5_000)
      assert message =~ "python3"
      assert {:error, _} = Client.call_tool(client, "fast", %{})
      assert Process.alive?(client)
    end
  end
end
