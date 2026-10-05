defmodule Lemieux.MCP.TransportsTest do
  @moduledoc """
  A transport the library has never heard of, registered by name and used.

  The point is that nothing in `Lemieux.MCP` names `stdio` or `http` on the
  connect path any more: a configuration names a transport, a map says which
  module that is, and the module reads its own configuration. The transport
  here is scripted in-process so that what is proved is the registry, not the
  wire.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lemieux.MCP
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.RemoteTool

  defmodule Scripted do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    # The configuration reaches the transport as it was written, string keys
    # and all, together with the connect options a host passed.
    @impl Lemieux.MCP.Transport
    def configure(%{"answers_as" => answers_as}, opts),
      do: {:ok, %{answers_as: answers_as, cwd: Keyword.get(opts, :cwd)}}

    def configure(_config, _opts), do: {:error, "a scripted MCP server needs answers_as"}

    @impl Lemieux.MCP.Transport
    def connect(config), do: {:ok, Map.put(config, :seen, [])}

    @impl Lemieux.MCP.Transport
    def call(state, %{"id" => id, "method" => method}, _timeout) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id, "result" => result(method, state)},
       %{state | seen: [method | state.seen]}}
    end

    defp result("server/discover", _state), do: %{"supportedVersions" => ["2026-07-28"]}

    defp result("tools/list", state) do
      %{
        "tools" => [
          %{
            "name" => state.answers_as,
            "description" => "Answers from #{state.cwd}.",
            "inputSchema" => %{"type" => "object", "properties" => %{}}
          }
        ]
      }
    end

    @impl Lemieux.MCP.Transport
    def notify(state, _notification), do: {:ok, state}

    @impl Lemieux.MCP.Transport
    def prepare_tools(state, tools), do: {tools, state}

    @impl Lemieux.MCP.Transport
    def close(_state), do: :ok
  end

  setup do
    runtime = :"lemieux_mcp_transports_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime}
  end

  defp connect(runtime, config, opts \\ []) do
    MCP.connect(
      [config],
      [supervisor: runtime, transports: %{"scripted" => Scripted}] ++ opts
    )
  end

  describe "the built-in registry" do
    test "names stdio and http, and nothing else" do
      assert %{"stdio" => Lemieux.MCP.Transport.Stdio, "http" => Lemieux.MCP.Transport.HTTP} =
               MCP.transports()

      assert map_size(MCP.transports()) == 2
    end
  end

  describe "a transport registered under a new name" do
    test "is connected and lists its tools end to end", %{runtime: runtime} do
      config = %{"name" => "lab", "transport" => "scripted", "answers_as" => "ping"}

      assert {[%RemoteTool{} = tool], [client]} = connect(runtime, config, cwd: "/somewhere")

      assert tool.name == "ping"
      assert tool.server == "lab"
      assert tool.client == client
      assert tool.protocol_version == "2026-07-28"
      # The connect options reached `configure/2`, which is how a host's
      # transport gets at anything the configuration must not carry.
      assert tool.description == "Answers from /somewhere."
      assert Client.info(client).era == :modern
    end

    test "may be named with an atom, like everything else in a config", %{runtime: runtime} do
      config = %{"name" => "lab", "transport" => "scripted", "answers_as" => "ping"}

      assert {[%RemoteTool{name: "ping"}], [_client]} =
               MCP.connect([config], supervisor: runtime, transports: %{scripted: Scripted})
    end

    test "decides for itself what its configuration needs", %{runtime: runtime} do
      config = %{"name" => "lab", "transport" => "scripted"}

      {result, log} = with_log(fn -> connect(runtime, config) end)

      assert result == {[], []}
      assert log =~ "the MCP server lab is unavailable"
      assert log =~ "needs answers_as"
    end
  end

  describe "a name nobody registered" do
    test "is refused with the names that are known, built in and added",
         %{runtime: runtime} do
      config = %{"name" => "lab", "transport" => "carrier-pigeon"}

      {result, log} = with_log(fn -> connect(runtime, config) end)

      assert result == {[], []}
      assert log =~ ~s(there is no "carrier-pigeon" MCP transport)
      assert log =~ "http, scripted, stdio"
    end

    test "without a host map, the known names are the built-in ones", %{runtime: runtime} do
      config = %{"name" => "lab", "transport" => "carrier-pigeon"}

      {result, log} = with_log(fn -> MCP.connect([config], supervisor: runtime) end)

      assert result == {[], []}
      assert log =~ "http, stdio"
      refute log =~ "scripted"
    end
  end
end
