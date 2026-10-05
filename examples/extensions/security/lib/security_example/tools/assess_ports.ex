defmodule SecurityExample.Tools.AssessPorts do
  @moduledoc "A deterministic policy check exposed as an ordinary model-callable tool."
  @behaviour Lemieux.Tool

  @impl true
  def name, do: "assess_ports"
  @impl true
  def description,
    do:
      "Apply repeatable review policy to a list of observed open ports. Flags are review prompts, not confirmed vulnerabilities."

  @impl true
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "ports" => %{
          "type" => "array",
          "minItems" => 0,
          "maxItems" => 128,
          "items" => %{"type" => "integer", "minimum" => 1, "maximum" => 65535}
        }
      },
      "required" => ["ports"],
      "additionalProperties" => false
    }
  end

  @impl true
  def parallel_safe?, do: true
  @impl true
  def read_only?, do: true

  @impl true
  def run(%{"ports" => ports}, _context) do
    with {:ok, findings} <- SecurityExample.Pipeline.assess_ports(ports),
         do: {:ok, JSON.encode!(findings)}
  end

  def run(_args, _context), do: {:error, "ports is required"}
end
