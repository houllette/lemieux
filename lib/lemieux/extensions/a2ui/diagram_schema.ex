defmodule Lemieux.Extensions.A2UI.DiagramSchema do
  @moduledoc false

  @spec schemas() :: map()
  def schemas do
    %{
      "MermaidDiagram" => component("MermaidDiagram", ~w(source), %{"source" => text(8192)}),
      "Flowchart" =>
        component("Flowchart", ~w(nodes edges), %{
          "nodes" => array(graph_node(), 16),
          "groups" => array(group(), 6),
          "edges" => array(edge(), 32),
          "direction" => enum(~w(TB BT LR RL))
        }),
      "SequenceDiagram" =>
        component("SequenceDiagram", ~w(participants events), %{
          "participants" => array(participant(), 8, 1),
          "events" => array(%{"$ref" => "#/$defs/event"}, 48)
        })
        |> Map.put("$defs", %{"event" => event(), "branch" => branch()}),
      "C4Diagram" =>
        component("C4Diagram", ~w(level elements relationships), %{
          "level" => enum(~w(context container component)),
          "elements" => array(element(), 16, 1),
          "relationships" => array(edge(), 32),
          "boundaries" => array(boundary(), 6)
        }),
      "StateDiagram" =>
        component("StateDiagram", ~w(states transitions), %{
          "states" => array(state(), 16, 1),
          "transitions" => array(edge(), 32),
          "direction" => enum(~w(TB BT LR RL))
        }),
      "ERDiagram" =>
        component("ERDiagram", ~w(entities relationships), %{
          "entities" => array(entity(), 16, 1),
          "relationships" => array(er_edge(), 32),
          "direction" => enum(~w(TB BT LR RL))
        })
    }
  end

  @spec preview() :: map()
  def preview do
    definitions = schemas()
    sequence = definitions["SequenceDiagram"]

    definitions =
      Map.delete(definitions, "SequenceDiagram")
      |> Map.put("SequenceDiagram", Map.delete(sequence, "$defs"))

    %{
      "oneOf" => Enum.map(Map.keys(definitions) |> Enum.sort(), &%{"$ref" => "#/$defs/#{&1}"}),
      "$defs" => Map.merge(definitions, sequence["$defs"])
    }
  end

  defp component(type, required, properties) do
    common = %{
      "component" => %{"const" => type},
      "id" => %{"type" => "string", "pattern" => "^[a-zA-Z0-9_-]{1,64}$"},
      "title" => text(128),
      "labelWidth" => %{"type" => "integer", "minimum" => 4, "maximum" => 24},
      "width" => %{"type" => "integer", "minimum" => 1, "maximum" => 200},
      "padding" => %{"type" => "integer", "minimum" => 0, "maximum" => 4},
      "align" => enum(~w(start center end stretch)),
      "compact" => %{"type" => "boolean"}
    }

    object(["component" | required], Map.merge(common, properties))
  end

  defp graph_node,
    do:
      object(~w(id), %{
        "id" => id(),
        "label" => text(256),
        "shape" => enum(~w(rectangle rounded diamond)),
        "group" => id()
      })

  defp group,
    do:
      object(~w(id), %{
        "id" => id(),
        "label" => text(256),
        "parent" => id(),
        "direction" => enum(~w(TB BT LR RL))
      })

  defp state,
    do:
      object(~w(id), %{
        "id" => id(),
        "label" => text(256),
        "parent" => id(),
        "kind" => enum(~w(state initial final choice composite))
      })

  defp entity,
    do:
      object(~w(id), %{"id" => id(), "label" => text(256), "attributes" => array(attribute(), 16)})

  defp attribute,
    do:
      object(~w(name), %{
        "name" => text(64),
        "type" => text(128),
        "keys" => Map.put(array(enum(~w(pk fk uk)), 3), "uniqueItems", true),
        "comment" => text(256)
      })

  defp er_edge,
    do:
      object(~w(from to), %{
        "id" => id(),
        "from" => id(),
        "to" => id(),
        "label" => text(256),
        "from_cardinality" => enum(~w(one zero_or_one one_or_more zero_or_more)),
        "to_cardinality" => enum(~w(one zero_or_one one_or_more zero_or_more)),
        "identifying" => %{"type" => "boolean"}
      })

  defp edge,
    do:
      object(~w(from to), %{
        "id" => id(),
        "from" => id(),
        "to" => id(),
        "label" => text(256),
        "style" => enum(~w(solid dashed)),
        "arrow" => %{"type" => "boolean"}
      })

  defp participant,
    do:
      object(~w(id), %{"id" => id(), "label" => text(256), "kind" => enum(~w(participant actor))})

  defp element,
    do:
      object(~w(id), %{
        "id" => id(),
        "label" => text(256),
        "kind" => enum(~w(person system container component database queue)),
        "technology" => text(256),
        "description" => text(256),
        "external" => %{"type" => "boolean"},
        "boundary" => id()
      })

  defp boundary, do: object(~w(id), %{"id" => id(), "label" => text(256), "parent" => id()})

  defp event do
    object([], %{
      "id" => id(),
      "kind" => enum(~w(message loop alt opt par critical break note activate deactivate)),
      "from" => id(),
      "to" => id(),
      "label" => text(256),
      "style" => enum(~w(solid dashed)),
      "arrow" => %{"type" => "boolean"},
      "participant" => id(),
      "participants" => array(id(), 2, 1),
      "position" => enum(~w(left right over)),
      "events" => array(%{"$ref" => "#/$defs/event"}, 48),
      "branches" => array(%{"$ref" => "#/$defs/branch"}, 4)
    })
  end

  defp branch,
    do: object([], %{"label" => text(256), "events" => array(%{"$ref" => "#/$defs/event"}, 48)})

  defp id, do: %{"type" => "string", "pattern" => "^[A-Za-z_][A-Za-z0-9_-]{0,63}$"}
  defp text(max), do: %{"type" => "string", "maxLength" => max}
  defp enum(values), do: %{"type" => "string", "enum" => values}

  defp array(items, max, min \\ 0),
    do: %{"type" => "array", "items" => items, "minItems" => min, "maxItems" => max}

  defp object(required, properties),
    do: %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => required,
      "properties" => properties
    }
end
