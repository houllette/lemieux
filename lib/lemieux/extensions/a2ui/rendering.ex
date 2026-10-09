defmodule Lemieux.Extensions.A2UI.Rendering do
  @moduledoc """
  The renderer-neutral preparation used by terminal display and repair feedback.

  A protocol-valid document can still fail diagram parsing or exceed the
  shared frame budget. Both consumers must see those failures; checking only
  JSON shape would tell the agent its rejected drawing was valid. Preparation
  is local and read-only, with no terminal dependency or model call.
  """
  alias Lemieux.Extensions.A2UI.{Diagram, Document}

  @doc "Validates a fence and prepares bounded native diagram frames in its resolved trees."
  @spec prepare(source :: String.t()) :: {:ok, [map()]} | {:error, String.t()} | :error
  def prepare(source) do
    with {:ok, trees} <- Document.validate(source),
         {:ok, trees, _left} <- prepare_all(trees, 64_000),
         do: {:ok, trees}
  end

  defp prepare_all(nodes, budget) do
    Enum.reduce_while(nodes, {:ok, [], budget}, fn node, {:ok, acc, left} ->
      case prepare_node(node, left) do
        {:ok, prepared, left} -> {:cont, {:ok, [prepared | acc], left}}
        {:error, message} -> {:halt, {:error, "#{node["id"]}: #{message}"}}
        :error -> {:halt, :error}
      end
    end)
    |> then(fn
      {:ok, nodes, left} -> {:ok, Enum.reverse(nodes), left}
      error -> error
    end)
  end

  defp prepare_node(%{"component" => type, "children" => children} = node, budget)
       when type in ["Column", "Row"] do
    with {:ok, children, left} <- prepare_all(children, budget),
         do: {:ok, Map.put(node, "children", children), left}
  end

  defp prepare_node(%{"component" => type} = node, budget) do
    if type in Diagram.types() do
      prepare_diagram(node, budget)
    else
      {:ok, node, budget}
    end
  end

  defp prepare_diagram(node, budget) do
    with {:ok, prepared} <- Diagram.prepare(node) do
      if prepared.cells <= budget,
        do: {:ok, Map.put(node, :diagram, prepared), budget - prepared.cells},
        else: {:error, "Diagram fence exceeds the shared 64,000-cell cache budget."}
    end
  end
end
