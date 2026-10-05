defmodule LemieuxComputerUse.Driver do
  @moduledoc """
  Browser runtime supplied by the host. An observation's action references are
  executable only in that same session and must be checked again before input.
  `:stale` means no mutation was attempted; every uncertain mutation is an error.
  """
  @callback open(url :: String.t(), opts :: keyword()) :: {:ok, term()} | {:error, String.t()}
  @callback observe(session :: term()) :: {:ok, map()} | {:error, String.t()}
  @callback act(session :: term(), page :: map(), action :: map(), text :: String.t() | nil) ::
              :ok | {:error, :stale | String.t()}
  @callback close(session :: term()) :: term()
end
