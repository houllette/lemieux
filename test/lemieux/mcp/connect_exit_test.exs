defmodule Lemieux.MCP.ConnectExitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Lemieux.MCP
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Exiting do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    @impl true
    def configure(config, _opts), do: {:ok, config}
    @impl true
    def connect(config), do: {:ok, config}
    @impl true
    def call(state, %{"id" => id, "method" => "server/discover"}, _timeout) do
      if state["phase"] == "during",
        do: send(self(), {:system, {self(), make_ref()}, {:terminate, state["reason"]}})

      {:ok, %{"id" => id, "result" => %{"supportedVersions" => ["2026-07-28"]}}, state}
    end

    def call(state, %{"id" => id, "method" => "tools/list"}, _timeout) do
      if state["phase"] == "after",
        do: send(self(), {:system, {self(), make_ref()}, {:terminate, state["reason"]}})

      tools = [%{"name" => "read", "inputSchema" => %{"type" => "object"}}]
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
    runtime = :"connect_exit_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime}
  end

  for phase <- ["during", "after"], reason <- [:normal, :shutdown] do
    test "#{reason} client exit #{phase} discovery leaves the session retryable", context do
      config = %{
        "name" => "linear",
        "transport" => "exit",
        "phase" => unquote(phase),
        "reason" => unquote(reason)
      }

      capture_log(fn ->
        assert {:error, %{name: "linear", reason: message}} =
                 MCP.connect_server(config,
                   supervisor: context.runtime,
                   transports: %{"exit" => Exiting}
                 )

        assert message =~ "client stopped"

        {:ok, session} =
          Lemieux.start_session(
            supervisor: context.runtime,
            provider: Scripted.new([]),
            model: "test:model",
            tools: [],
            store: JSONL.new(context.tmp_dir),
            mcp_servers: [config],
            mcp_transports: %{"exit" => Exiting}
          )

        assert [%{error: error}] = Session.mcp_status(session, :infinity)
        assert error =~ "client stopped"
        assert :ok = Session.reconnect_mcp(session, "linear")
        assert Process.alive?(session)
        assert [%{name: "linear", error: error}] = Session.mcp_status(session)
        assert error =~ "client stopped"
        assert :ok = Session.add_mcp_servers(session, [Map.put(config, "phase", "ready")])
        assert [%{tool_count: 1, error: nil}] = Session.mcp_status(session)
      end)
    end
  end
end
