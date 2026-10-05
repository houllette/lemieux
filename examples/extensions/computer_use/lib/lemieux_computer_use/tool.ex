defmodule LemieuxComputerUse.Tool do
  @moduledoc "One bounded browser task exposed through the ordinary Lemieux tool contract."
  @behaviour Lemieux.Tool.Configured
  defstruct opts: []
  @impl true
  def name(_), do: "computer_use"
  @impl true
  def description(_),
    do:
      "Perform a bounded experimental browser task. Supply a goal and starting URL or search query. Actions use current page controls; completion claims require independent verification."

  @impl true
  def schema(_) do
    %{
      "type" => "object",
      "properties" => %{
        "goal" => %{"type" => "string", "maxLength" => 4000},
        "url" => %{"type" => "string", "maxLength" => 2048},
        "query" => %{"type" => "string", "maxLength" => 400}
      },
      "required" => ["goal"],
      "additionalProperties" => false
    }
  end

  @impl true
  def run(tool, args, context) do
    case LemieuxComputerUse.Runner.run(args, tool.opts, context) do
      {status, report} ->
        {status,
         Lemieux.Tool.Result.new(
           JSON.encode!(Map.take(report, ~w(status reason url steps elapsed_ms verified))),
           structured_content: report
         )}
    end
  end

  @impl true
  def metadata(tool),
    do: %{
      effects: %{class: "write", resource_types: ["browser"], external_cost: "unknown"},
      runtime: %{
        timeout_ms: Keyword.get(tool.opts, :timeout_ms, 90_000) + 5000,
        max_output_bytes: 120_000
      }
    }
end
