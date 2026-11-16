defmodule Lemieux.CLI.ACP.Tool do
  @moduledoc false
  @behaviour Lemieux.Tool.Configured

  alias Lemieux.CLI.ACP.Environment
  alias Lemieux.CLI.ACP.Server
  alias Lemieux.Tool, as: NativeTool
  alias Lemieux.Tool.Override

  defstruct [:tool, :server, :filesystem]

  @spec attach(tools :: [NativeTool.t()], server :: pid(), filesystem :: map()) :: [
          NativeTool.t()
        ]
  def attach(tools, server, filesystem) do
    Enum.map(tools, &%__MODULE__{tool: &1, server: server, filesystem: filesystem})
  end

  @impl NativeTool.Configured
  @spec name(tool :: struct()) :: String.t()
  def name(%{tool: tool}), do: NativeTool.name(tool)

  @impl NativeTool.Configured
  @spec description(tool :: struct()) :: String.t()
  def description(%{tool: tool}), do: NativeTool.description(tool)

  @impl NativeTool.Configured
  @spec schema(tool :: struct()) :: map()
  def schema(%{tool: tool}), do: NativeTool.schema(tool)

  @impl NativeTool.Configured
  @spec run(tool :: struct(), args :: map(), context :: map()) :: NativeTool.run_return()
  def run(%{tool: tool, server: server, filesystem: filesystem}, args, context) do
    send(server, {:acp_tool, context.session_id, context.call_id, :started})

    bridge = %{
      read?: filesystem[:read] == true,
      write?: filesystem[:write] == true,
      request: fn method, params ->
        Server.client_request(server, context.session_id, method, params)
      end,
      notify: fn event ->
        Server.tool_event(server, context.session_id, context.call_id, event)
      end
    }

    environment = Environment.wrap(context.environment, bridge)
    NativeTool.invoke(tool, args, %{context | environment: environment})
  end

  @impl NativeTool.Configured
  @spec parallel_safe?(tool :: struct()) :: boolean()
  def parallel_safe?(%{tool: tool}), do: NativeTool.parallel_safe?(tool)

  @impl NativeTool.Configured
  @spec read_only?(tool :: struct()) :: boolean()
  def read_only?(%{tool: tool}), do: NativeTool.read_only?(tool)

  @impl NativeTool.Configured
  @spec metadata(tool :: struct()) :: map()
  def metadata(%{tool: tool}) do
    # Use the existing descriptor wrapper machinery to retain the underlying
    # tool's origin and policy while recording this execution adapter.
    tool
    |> Override.new!(before: &unchanged/2, digest: "lemieux-acp-environment-v1")
    |> NativeTool.metadata()
  end

  defp unchanged(args, _context), do: {:ok, args}
end
