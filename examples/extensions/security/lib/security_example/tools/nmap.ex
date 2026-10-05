defmodule SecurityExample.Tools.Nmap do
  @moduledoc "A reusable Nmap wrapper that honors the host's tool execution environment."
  @behaviour Lemieux.Tool

  @impl true
  def name, do: "nmap_scan"
  @impl true
  def description,
    do:
      "TCP-connect scan of one authorized IPv4 address and explicit ports. Returns bounded Nmap XML and terminal status; requires nmap in the host environment."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "target" => %{"type" => "string", "description" => "One authorized IPv4 address."},
        "ports" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 128,
          "items" => %{"type" => "integer", "minimum" => 1, "maximum" => 65535}
        }
      },
      "required" => ["target", "ports"],
      "additionalProperties" => false
    }
  end

  @impl true
  def metadata,
    do: %{
      effects: %{class: "write", resource_types: ["network"]},
      runtime: %{timeout_ms: 30_000, concurrency: %{class: "exclusive"}}
    }

  @impl true
  def run(%{"target" => target, "ports" => ports}, context) do
    with {:ok, command} <- SecurityExample.Pipeline.nmap_command(target, ports) do
      Lemieux.Tools.Bash.run(%{"command" => command, "timeout_ms" => 30_000}, context)
    end
  end

  def run(_args, _context), do: {:error, "target and ports are required"}
end
