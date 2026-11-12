defmodule Lemieux.MCP.InspectionTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  defmodule Catalog do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport
    @impl true
    def configure(config, _opts), do: {:ok, config}
    @impl true
    def connect(config), do: {:ok, config}
    @impl true
    def call(state, %{"id" => id, "method" => "server/discover"}, _timeout),
      do:
        {:ok,
         %{
           "id" => id,
           "result" => %{
             "supportedVersions" => ["2026-07-28"],
             "capabilities" => %{"prompts" => %{}}
           }
         }, state}

    def call(%{"name" => "empty"} = state, %{"id" => id, "method" => "tools/list"}, _timeout),
      do: {:ok, %{"id" => id, "result" => %{"tools" => []}}, state}

    def call(state, %{"id" => id, "method" => "tools/list"}, _timeout) do
      tool = %{
        "name" => "files.read",
        "description" => "Read a file",
        "inputSchema" => %{
          "type" => "object",
          "required" => ["path"],
          "properties" => %{"path" => %{"type" => "string"}}
        }
      }

      {:ok, %{"id" => id, "result" => %{"tools" => [tool]}}, state}
    end

    def call(_state, request, _timeout), do: raise("inspection invoked #{inspect(request)}")
    @impl true
    def notify(state, _message), do: {:ok, state}
    @impl true
    def prepare_tools(state, tools), do: {tools, state}
    @impl true
    def close(_state), do: :ok
  end

  test "transport closure is visible without discarding cached tool details", %{tmp_dir: dir} do
    rt = :"mcp_closed_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: rt})
    fixture = Path.expand("../../fixtures/mcp_server.py", __DIR__)

    capture_log(fn ->
      {:ok, session} =
        Lemieux.start_session(
          supervisor: rt,
          provider: Scripted.new([]),
          model: "test:model",
          tools: [],
          store: JSONL.new(dir),
          subscriber: self(),
          mcp_servers: [
            %{"name" => "stdio", "command" => "python3", "args" => [fixture, "modern"]}
          ]
        )

      Session.mcp_status(session, :infinity)
      [%{client: client}] = Session.mcp_clients(session)
      transport = :sys.get_state(client).transport
      capture = transport.diagnostics
      Port.close(transport.port)
      assert_receive {:lemieux, _, {:mcp_server, %{name: "stdio", status: :failed}}}

      assert {:ok, %{server: %{status: :failed, tool_count: 0}, tools: [tool | _]}} =
               Session.inspect_mcp(session, "stdio")

      refute tool.enabled?
      assert tool.reason == "server is failed"
      assert map_size(tool.input_schema) > 0
      assert [] = Session.catalog(session)
      refute Process.alive?(capture)
    end)
  end

  test "inspection isolates servers, names tools exactly and includes disabled schemas", %{
    tmp_dir: dir
  } do
    rt = :"mcp_inspect_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: rt})
    provider = Scripted.new([])

    capture_log(fn ->
      {:ok, session} =
        Lemieux.start_session(
          supervisor: rt,
          provider: provider,
          model: "test:model",
          tools: [],
          store: JSONL.new(dir),
          mcp_servers:
            for(name <- ["one", "two", "empty"], do: %{"name" => name, "transport" => "catalog"}),
          mcp_transports: %{"catalog" => Catalog}
        )

      Session.mcp_status(session, :infinity)

      assert {:ok, %{tools: [tool], server: %{name: "one", status: :connected}}} =
               Session.inspect_mcp(session, "one")

      assert tool.name == "files.read"
      assert tool.model_name in Enum.map(Session.catalog(session), &Lemieux.Tool.name/1)
      assert tool.input_schema["required"] == ["path"]
      assert tool.input_schema["properties"]["path"]["type"] == "string"
      assert tool.enabled?
      assert {:ok, [_]} = Session.disable_tools(session, [tool.model_name])

      assert {:ok, %{tools: [%{enabled?: false, reason: "disabled for this session"}]}} =
               Session.inspect_mcp(session, "one")

      assert {:ok, %{tools: [], server: %{status: :connected}}} =
               Session.inspect_mcp(session, "empty")

      assert :ok = Session.set_mcp_enabled(session, "two", false)

      assert {:ok, %{tools: [], server: %{status: :disabled}}} =
               Session.inspect_mcp(session, "two")

      assert {:error, :unknown_server} = Session.inspect_mcp(session, "missing")
      assert Scripted.requests(provider) == []
    end)
  end
end
