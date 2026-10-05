defmodule Lemieux.MCP.ConnectTest do
  @moduledoc """
  `Lemieux.MCP.connect_server/2` and what configuration decides at connect
  time: per-server budgets, the transport a Claude-style `"type"` names, what
  a stdio server inherits, and what a repository's configuration may read.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lemieux.MCP
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.MCP.Transport.Stdio
  alias Lemieux.Tool.Result

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  defmodule Serial do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    @impl true
    def configure(_config, _opts), do: {:ok, %{}}
    @impl true
    def connect(config), do: {:ok, config}
    @impl true
    def call(state, %{"id" => id, "method" => "server/discover"}, _timeout),
      do: {:ok, %{"id" => id, "result" => %{"supportedVersions" => ["2026-07-28"]}}, state}

    def call(state, %{"id" => id, "method" => "tools/list"}, _timeout) do
      tools = [%{"name" => "t", "inputSchema" => %{"type" => "object"}}]
      {:ok, %{"id" => id, "result" => %{"tools" => tools}}, state}
    end

    @impl true
    def notify(state, _message), do: {:ok, state}
    @impl true
    def prepare_tools(state, tools), do: {tools, state}
    @impl true
    def close(_state), do: :ok
  end

  setup do
    runtime = :"lemieux_mcp_connect_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime}
  end

  defp fixture(name, extra \\ %{}) do
    Map.merge(
      %{
        "name" => name,
        "type" => "stdio",
        "command" => "python3",
        "args" => [@fixture, "duplex"]
      },
      extra
    )
  end

  defp env_of(tools, name) do
    tool = Enum.find(tools, &(&1.name == "env"))
    {:ok, %Result{model_text: value}} = MCP.call_tool(tool, %{"name" => name}, %{})
    value
  end

  # A variable unique to one test, so async cases cannot see each other's.
  defp secret(context) do
    name = "LEMIEUX_MCP_#{System.unique_integer([:positive])}_TOKEN"
    System.put_env(name, "s3cret")
    on_exit(fn -> System.delete_env(name) end)
    Map.put(context, :secret, name)
  end

  test "connect_server returns the client, its tools and the listing's notices", %{runtime: rt} do
    assert {:ok, %{name: "fx", client: client, tools: tools, notices: notices}} =
             capture_log_result(fn -> MCP.connect_server(fixture("fx"), supervisor: rt) end)

    assert Enum.all?(tools, &(&1.client == client))
    assert Enum.all?(tools, &ReqLLM.Tool.valid_name?(RemoteTool.qualified_name(&1)))
    assert Enum.any?(notices, &(&1 =~ "files.read"))
  end

  test "a per-server tool budget applies to that server's calls", %{runtime: rt} do
    config = fixture("fx", %{"tool_timeout" => 250})

    {:ok, %{tools: tools}} =
      capture_log_result(fn -> MCP.connect_server(config, supervisor: rt) end)

    slow = Enum.find(tools, &(&1.name == "slow"))
    assert {:error, message} = MCP.call_tool(slow, %{"seconds" => 2}, %{})
    assert message =~ "did not answer within"
  end

  test "a Claude-style \"type\" decides the transport" do
    assert MCP.config(%{"name" => "a", "type" => "http", "url" => "https://x"})["transport"] ==
             "http"

    assert MCP.config(%{"name" => "b", "type" => "streamable-http", "url" => "https://x"})[
             "transport"
           ] == "http"

    assert MCP.config(%{"name" => "c", "url" => "https://x"})["transport"] == "http"
    assert MCP.config(%{"name" => "d", "command" => "run"})["transport"] == "stdio"
  end

  test "a legacy SSE server is refused with directions rather than a riddle", %{runtime: rt} do
    config = %{"name" => "old", "type" => "sse", "url" => "https://example.com/sse"}

    {result, log} = with_log(fn -> MCP.connect_server(config, supervisor: rt) end)

    assert {:error, %{name: "old", reason: reason}} = result
    assert reason =~ "legacy SSE transport"
    assert reason =~ ~s("type": "http")
    assert log =~ "legacy SSE"
  end

  describe "what a stdio server inherits" do
    setup :secret

    test "everything, by default", %{runtime: rt, secret: secret} do
      {:ok, %{tools: tools}} =
        capture_log_result(fn -> MCP.connect_server(fixture("fx"), supervisor: rt) end)

      assert env_of(tools, secret) == "s3cret"
    end

    test "no credential-shaped variable when the policy scrubs", %{runtime: rt, secret: secret} do
      {:ok, %{tools: tools}} =
        capture_log_result(fn ->
          MCP.connect_server(fixture("fx"), supervisor: rt, credentials: {:scrub, []})
        end)

      assert env_of(tools, secret) == "<unset>"
      assert env_of(tools, "PATH") != "<unset>"
    end

    test "a variable the configuration names is still passed", %{runtime: rt, secret: secret} do
      config = fixture("fx", %{"env" => %{secret => "${#{secret}}"}})

      {:ok, %{tools: tools}} =
        capture_log_result(fn ->
          MCP.connect_server(config, supervisor: rt, credentials: {:scrub, []})
        end)

      assert env_of(tools, secret) == "s3cret"
    end

    test "port_env unsets exactly the withheld variables the config did not name", %{
      secret: secret
    } do
      env = Stdio.port_env(%{"OWN" => "1"}, {:scrub, []})

      assert {~c"OWN", ~c"1"} in env
      assert {String.to_charlist(secret), false} in env
      refute Enum.any?(env, &match?({~c"PATH", _}, &1))
      assert Stdio.port_env(%{"OWN" => "1"}, :inherit) == [{~c"OWN", ~c"1"}]
    end
  end

  describe "a repository's configuration" do
    setup :secret

    test "may not read a credential-shaped variable", %{runtime: rt, secret: secret} do
      config = fixture("repo", %{"env" => %{"T" => "${#{secret}}"}, "source" => "project"})

      {result, _log} = with_log(fn -> MCP.connect_server(config, supervisor: rt) end)

      assert {:error, %{reason: reason}} = result
      assert reason =~ "${#{secret}}"
      assert reason =~ "credential-shaped"
    end

    test "may read one a person allowed", %{runtime: rt, secret: secret} do
      config = fixture("repo", %{"env" => %{"T" => "${#{secret}}"}, "source" => "project"})

      {:ok, %{tools: tools}} =
        capture_log_result(fn ->
          MCP.connect_server(config, supervisor: rt, allow_env: [secret])
        end)

      assert env_of(tools, "T") == "s3cret"
    end

    test "may still read an ordinary variable, and a default" do
      assert {:ok, "/usr"} = MCP.expand("${LEMIEUX_UNSET_HOME:-/usr}", source: "project")
      assert {:ok, _path} = MCP.expand("${PATH}", source: "project")
    end
  end

  describe "tools from several servers" do
    test "are named apart even when their servers' names collide once made valid",
         %{runtime: rt} do
      {tools, clients, errors} =
        capture_log_result(fn ->
          MCP.connect_report([fixture("my.docs"), fixture("my_docs")], supervisor: rt)
        end)

      assert errors == %{}
      assert length(clients) == 2
      names = Enum.map(tools, &RemoteTool.qualified_name/1)
      assert length(names) == length(Enum.uniq(names))
    end
  end

  test "a client whose transport declares no mode stays serial", %{runtime: rt} do
    assert {:ok, %{client: client}} =
             MCP.connect_server(%{"name" => "s", "transport" => "serial"},
               supervisor: rt,
               transports: %{"serial" => Serial}
             )

    assert Client.info(client).mode == :serial
  end

  # Most of these connect a real server, whose listing logs at info level.
  defp capture_log_result(fun) do
    {result, _log} = with_log(fun)
    result
  end
end
