defmodule Lmx.Application do
  @moduledoc """
  OTP entry point for the standalone `lmx` executable.

  Lemieux itself deliberately has no application callback: embedding the
  library must not start a runtime or claim a terminal. The launcher runs the
  command after OTP boot completes, so SASL can upgrade a fully started host.
  Running the CLI here used to keep application startup blocked for the whole
  TUI session, which prevents a normal release lifecycle.
  """

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([{Task.Supervisor, name: Lmx.Tasks}],
      strategy: :one_for_one,
      name: Lmx.Supervisor
    )
  end
end
