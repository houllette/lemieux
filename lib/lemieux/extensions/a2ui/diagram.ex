defmodule Lemieux.Extensions.A2UI.Diagram do
  @moduledoc """
  Bounded, renderer-neutral diagrams for the terminal catalog and preview tool.

  Source and native JSON share one constructor, limit and layout path. Native
  enums use fixed tables, never input-derived atoms. Compact width variants
  are prepared once; consumers select a complete variant or the relationship
  summary instead of clipping connectors. Exterior canvas margins alone are
  removed. No executable directives or model-selected inks cross this boundary.
  """

  @types ~w(MermaidDiagram Flowchart SequenceDiagram C4Diagram StateDiagram ERDiagram)
  @properties %{
    "MermaidDiagram" => ~w(source title labelWidth),
    "Flowchart" => ~w(nodes edges groups direction title labelWidth),
    "SequenceDiagram" => ~w(participants events title labelWidth),
    "C4Diagram" => ~w(level elements relationships boundaries title labelWidth),
    "StateDiagram" => ~w(states transitions direction title labelWidth),
    "ERDiagram" => ~w(entities relationships direction title labelWidth)
  }
  @keys Map.new(
          ~w(id label shape from to style arrow kind technology description external boundary parent participant participants position events branches group direction name type keys comment attributes from_cardinality to_cardinality identifying)a,
          &{Atom.to_string(&1), &1}
        )
  @doc "The additive diagram components in the terminal catalog."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The component-specific properties, excluding the shared layout envelope."
  @spec properties() :: map()
  def properties, do: @properties

  @doc "Checks the JSON envelope before invoking the optional diagram library."
  @spec valid_input?(node :: term()) :: boolean()
  def valid_input?(%{"component" => type} = node) when type in @types do
    allowed = ~w(id component width padding align compact) ++ @properties[type]
    Map.keys(node) -- allowed == [] and options?(node) and body?(type, node)
  end

  def valid_input?(_node), do: false

  defp options?(node) do
    layout?(node) and text?(Map.get(node, "title", ""), 128) and
      (not Map.has_key?(node, "labelWidth") or
         (is_integer(node["labelWidth"]) and node["labelWidth"] in 4..24))
  end

  defp layout?(node) do
    Enum.all?(node, fn
      {"id", id} -> is_binary(id) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, id)
      {"width", width} -> is_integer(width) and width in 1..200
      {"padding", padding} -> is_integer(padding) and padding in 0..4
      {"align", align} -> align in ~w(start center end stretch)
      {"compact", compact} -> is_boolean(compact)
      _property -> true
    end)
  end

  defp body?("MermaidDiagram", %{"source" => source}), do: text?(source, 8192)

  defp body?("Flowchart", %{"nodes" => nodes, "edges" => edges} = node),
    do:
      records?(nodes, 16, true) and records?(Map.get(node, "groups", []), 6, true) and
        records?(edges, 32, true) and
        Map.get(node, "direction", "TB") in ~w(TB BT LR RL)

  defp body?("SequenceDiagram", %{"participants" => participants, "events" => events}),
    do: records?(participants, 8, false) and records?(events, 48, true)

  defp body?(
         "C4Diagram",
         %{"level" => level, "elements" => elements, "relationships" => edges} = node
       ),
       do:
         level in ~w(context container component) and records?(elements, 16, false) and
           records?(edges, 32, true) and records?(Map.get(node, "boundaries", []), 6, true)

  defp body?("StateDiagram", %{"states" => states, "transitions" => edges} = node),
    do:
      records?(states, 16, false) and records?(edges, 32, true) and
        Map.get(node, "direction", "TB") in ~w(TB BT LR RL)

  defp body?("ERDiagram", %{"entities" => entities, "relationships" => edges} = node),
    do:
      records?(entities, 16, false) and records?(edges, 32, true) and
        Map.get(node, "direction", "LR") in ~w(TB BT LR RL)

  defp body?(_type, _node), do: false

  defp records?(records, limit, empty?) when is_list(records),
    do:
      length(records) <= limit and (empty? or records != []) and Enum.all?(records, &json?(&1, 0))

  defp records?(_records, _limit, _empty?), do: false
  defp json?(_value, depth) when depth > 12, do: false
  defp json?(value, _depth) when is_binary(value), do: text?(value, 256)

  defp json?(value, depth) when is_map(value),
    do:
      map_size(value) <= 16 and
        Enum.all?(value, fn {key, item} ->
          is_binary(key) and Map.has_key?(@keys, key) and json?(item, depth + 1)
        end)

  defp json?(value, depth) when is_list(value),
    do: length(value) <= 48 and Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, _depth), do: is_boolean(value) or is_nil(value)

  defp text?(value, bytes),
    do:
      is_binary(value) and byte_size(value) <= bytes and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x08\x0b-\x1f\x7f]/, value)

  @doc "Whether this host includes the optional native diagram implementation."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Lemieux.Extensions.A2UI.Diagram.Compiler)

  @doc "Prepares bounded frame variants and a complete semantic text fallback."
  @spec prepare(node :: map()) :: {:ok, map()} | {:error, String.t()} | :error
  def prepare(node) do
    with true <- valid_input?(node),
         {:module, compiler} <- Code.ensure_loaded(Lemieux.Extensions.A2UI.Diagram.Compiler) do
      # Runtime dispatch keeps this optional adapter compilable in hosts that
      # omit :ascii. Its implementation is absent in those dependency builds.
      compiler.prepare(node)
    else
      false -> {:error, "Invalid diagram input or exceeded diagram limits."}
      {:error, _missing} -> :error
    end
  end

  @doc "Selects a whole cached variant without doing layout or drawing."
  @spec select(prepared :: map(), width :: pos_integer()) :: map() | nil
  def select(prepared, width), do: Enum.find(prepared.variants, &(&1.cols <= width))
end
