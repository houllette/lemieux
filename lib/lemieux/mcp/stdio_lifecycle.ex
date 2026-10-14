defmodule Lemieux.MCP.StdioLifecycle do
  @moduledoc """
  Safe lifecycle evidence for a stdio wrapper, never proof of a remote target.

  Pass an observer PID as `:stdio_observer` to receive
  `{:mcp_stdio, endpoint, event}`. Events carry no command, environment, server
  output or exception text. A wrapper's exit and even successful local teardown
  leave an external target's outcome unknown; its backend must attest that.
  """
  @type kind :: :launch_failed | :wrapper_exit | :interrupted | :output_limit | :eof
  @type t :: %__MODULE__{
          kind: kind(),
          status: integer() | nil,
          target_outcome: :unknown
        }
  @enforce_keys [:kind]
  defstruct [:kind, :status, target_outcome: :unknown]

  @doc false
  @spec emit(
          observer :: pid() | nil,
          endpoint :: term(),
          kind :: kind(),
          status :: integer() | nil
        ) ::
          :ok
  def emit(observer, endpoint, kind, status \\ nil) do
    if is_pid(observer),
      do: send(observer, {:mcp_stdio, endpoint, %__MODULE__{kind: kind, status: status}})

    :ok
  end
end
