if Code.ensure_loaded?(Ascii.Diagram) do
  defmodule Lemieux.Extensions.A2UI.Diagram.Compiler do
    @moduledoc false
    @keys Map.new(
            ~w(id label shape from to style arrow kind technology description external boundary parent participant participants position events branches group direction name type keys comment attributes from_cardinality to_cardinality identifying)a,
            &{Atom.to_string(&1), &1}
          )
    @choices %{
      shape: %{"rectangle" => :rectangle, "rounded" => :rounded, "diamond" => :diamond},
      style: %{"solid" => :solid, "dashed" => :dashed},
      kind:
        Map.new(
          ~w(participant actor person system container component database queue message loop alt opt par critical break note activate deactivate state initial final choice composite)a,
          &{Atom.to_string(&1), &1}
        ),
      position: %{"left" => :left, "right" => :right, "over" => :over},
      direction: %{"TB" => :tb, "BT" => :bt, "LR" => :lr, "RL" => :rl},
      cardinality:
        Map.new(~w(one zero_or_one one_or_more zero_or_more)a, &{Atom.to_string(&1), &1}),
      keys: Map.new(~w(pk fk uk)a, &{Atom.to_string(&1), &1})
    }
    @styles ~w(color border_color label_color line_color)a
    @inks %{
      node: "#58a6ff",
      label: "#c9d1d9",
      edge: "#8b949e",
      edge_label: "#d29922",
      boundary: "#bc8cff",
      lifeline: "#8b949e",
      fragment: "#bc8cff",
      note: "#3fb950",
      activation: "#58a6ff"
    }
    alias Ascii.Diagram, as: Native
    alias Ascii.Diagram.Layout
    alias Ascii.Mermaid

    @doc false
    @spec prepare(node :: map()) :: {:ok, map()} | {:error, String.t()}
    def prepare(node) do
      with {:ok, model} <- build(node),
           :ok <- limits(model),
           :ok <- model_text(model.data),
           :ok <- styles(model.data),
           {:ok, variants} <- variants(model, node) do
        summary = summary(model)
        title = Map.get(node, "title", "")

        {:ok,
         %{
           variants: variants,
           summary: if(title == "", do: summary, else: title <> "\n" <> summary),
           title: title,
           family: Atom.to_string(model.type),
           cells: Enum.sum(Enum.map(variants, & &1.cells))
         }}
      else
        {:error, reason} -> {:error, describe(reason)}
      end
    end

    defp build(%{"component" => "MermaidDiagram", "source" => source}), do: Mermaid.parse(source)

    defp build(%{"component" => "Flowchart"} = node) do
      with {:ok, nodes} <- convert(node["nodes"]),
           {:ok, edges} <- convert(node["edges"]),
           {:ok, groups} <- convert(Map.get(node, "groups", [])),
           do:
             Native.flowchart(nodes, edges,
               direction: direction(Map.get(node, "direction", "TB")),
               groups: groups
             )
    end

    defp build(%{"component" => "SequenceDiagram"} = node) do
      with {:ok, participants} <- convert(node["participants"]),
           {:ok, events} <- convert(node["events"]),
           do: Native.sequence(participants, events)
    end

    defp build(%{"component" => "C4Diagram"} = node) do
      with {:ok, elements} <- convert(node["elements"]),
           {:ok, edges} <- convert(node["relationships"]),
           {:ok, boundaries} <- convert(Map.get(node, "boundaries", [])),
           do: Native.c4(level(node["level"]), elements, edges, boundaries: boundaries)
    end

    defp build(%{"component" => "StateDiagram"} = node) do
      with {:ok, states} <- convert(node["states"]),
           {:ok, edges} <- convert(node["transitions"]),
           do: Native.state(states, edges, direction: direction(Map.get(node, "direction", "TB")))
    end

    defp build(%{"component" => "ERDiagram"} = node) do
      with {:ok, entities} <- convert(node["entities"]),
           {:ok, edges} <- convert(node["relationships"]),
           do: Native.er(entities, edges, direction: direction(Map.get(node, "direction", "LR")))
    end

    defp direction("LR"), do: :lr
    defp direction("RL"), do: :rl
    defp direction("BT"), do: :bt
    defp direction("TB"), do: :tb
    defp level("context"), do: :context
    defp level("container"), do: :container
    defp level("component"), do: :component

    defp convert(value) when is_map(value) do
      Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
        with {:ok, key} <- Map.fetch(@keys, key), {:ok, item} <- convert_field(key, item) do
          {:cont, {:ok, Map.put(acc, key, item)}}
        else
          _invalid -> {:halt, {:error, :invalid_record}}
        end
      end)
    end

    defp convert(value) when is_list(value) do
      Enum.reduce_while(value, {:ok, []}, fn item, {:ok, acc} ->
        case convert(item) do
          {:ok, converted} -> {:cont, {:ok, [converted | acc]}}
          error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end)
    end

    defp convert(value), do: {:ok, value}

    defp convert_field(key, value) when key in [:shape, :style, :kind, :position, :direction],
      do: Map.fetch(@choices[key], value)

    defp convert_field(key, value) when key in [:from_cardinality, :to_cardinality],
      do: Map.fetch(@choices.cardinality, value)

    defp convert_field(:keys, values) when is_list(values) do
      Enum.reduce_while(values, {:ok, []}, fn key, {:ok, keys} ->
        case Map.fetch(@choices.keys, key) do
          {:ok, key} -> {:cont, {:ok, keys ++ [key]}}
          :error -> {:halt, {:error, :invalid_key}}
        end
      end)
    end

    defp convert_field(_key, value), do: convert(value)

    defp model_text(value) when is_map(value) do
      Enum.reduce_while(value, :ok, fn {key, item}, :ok ->
        limit =
          if key in [:id, :from, :to, :boundary, :parent, :participant, :group, :name],
            do: 64,
            else: 256

        result = text_limit(item, limit)

        case result do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp model_text(values) when is_list(values) do
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case model_text(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp model_text(_value), do: :ok

    defp text_limit(value, limit) when is_binary(value),
      do: if(text?(value, limit), do: :ok, else: {:error, :text_limits})

    defp text_limit(value, _limit), do: model_text(value)

    defp limits(%{type: :flowchart, data: data}) do
      with :ok <- graph_limits(data.nodes, data.edges), do: scope_limits(data.groups)
    end

    defp limits(%{type: :state, data: data}) do
      with :ok <- graph_limits(data.states, data.edges),
           do: scope_limits(Enum.filter(data.states, &(&1.kind == :composite)))
    end

    defp limits(%{type: :er, data: data}) do
      with :ok <- graph_limits(data.entities, data.edges),
           true <- Enum.all?(data.entities, &(length(&1.attributes) <= 16)),
           true <- Enum.sum(Enum.map(data.entities, &length(&1.attributes))) <= 64,
           do: :ok,
           else: (_invalid -> {:error, :diagram_limits})
    end

    defp limits(%{type: :c4, data: data}) do
      with :ok <- graph_limits(data.elements, data.edges),
           true <- length(data.boundaries) <= 6,
           do: :ok,
           else: (_error -> {:error, :diagram_limits})
    end

    defp limits(%{type: :sequence, data: data}) do
      with true <- length(data.participants) <= 8,
           {:ok, _left} <- events_limit(data.messages, 48, 0),
           do: :ok,
           else: (_error -> {:error, :diagram_limits})
    end

    defp scope_limits(groups) do
      parents = Map.new(groups, &{&1.id, &1.parent})

      if length(groups) <= 6 and Enum.all?(groups, &(scope_depth(&1.id, parents, 0) <= 4)),
        do: :ok,
        else: {:error, :diagram_limits}
    end

    defp scope_depth(nil, _parents, depth), do: depth
    defp scope_depth(_id, _parents, depth) when depth > 4, do: depth

    defp scope_depth(id, parents, depth),
      do: scope_depth(Map.get(parents, id), parents, depth + 1)

    defp graph_limits(nodes, edges) do
      if length(nodes) <= 16 and length(edges) <= 32, do: :ok, else: {:error, :diagram_limits}
    end

    defp events_limit(_events, left, depth) when left < 0 or depth > 4,
      do: {:error, :diagram_limits}

    defp events_limit(events, left, depth) do
      Enum.reduce_while(events, {:ok, left}, fn event, {:ok, left} ->
        case event_limit(event, left - 1, depth) do
          {:ok, left} -> {:cont, {:ok, left}}
          error -> {:halt, error}
        end
      end)
    end

    defp event_limit(%{events: events, branches: branches}, left, depth)
         when length(branches) <= 4,
         do: events_limit(events ++ Enum.flat_map(branches, & &1.events), left, depth + 1)

    defp event_limit(%{events: _}, _left, _depth), do: {:error, :diagram_limits}
    defp event_limit(_event, left, _depth) when left >= 0, do: {:ok, left}
    defp event_limit(_event, _left, _depth), do: {:error, :diagram_limits}

    defp styles(value) when is_map(value) do
      if Enum.any?(@styles, &(Map.get(value, &1) != nil)),
        do: {:error, :styles},
        else: styles(Map.values(value))
    end

    defp styles(values) when is_list(values) do
      Enum.reduce_while(values, :ok, fn value, :ok ->
        case styles(value) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end

    defp styles(_value), do: :ok

    defp variants(model, node) do
      widths = if node["labelWidth"], do: [node["labelWidth"]], else: [12, 8, 4]

      Enum.reduce_while(widths, {:ok, []}, fn width, {:ok, acc} ->
        case variant(model, width) do
          {:ok, variant} -> {:cont, {:ok, acc ++ [variant]}}
          {:error, {:too_large, _}} -> {:cont, {:ok, acc}}
          error -> {:halt, error}
        end
      end)
      |> then(fn
        {:ok, variants} -> {:ok, Enum.uniq_by(variants, & &1.frame.text)}
        error -> error
      end)
    end

    defp variant(model, label_width) do
      opts = [label_width: label_width, gap_cols: 4, gap_rows: 2, max_cols: 200, max_rows: 100]

      with {:ok, layout} <- Native.layout(model, opts),
           {:ok, frame} <- Layout.frame(layout, opts ++ [theme: @inks]) do
        cells = frame.cols * frame.rows
        {frame, offset} = trim(frame)

        {:ok,
         %{
           cols: frame.cols,
           rows: frame.rows,
           frame: frame,
           layout: layout,
           offset: offset,
           cells: cells
         }}
      end
    end

    # Remove only a rectangular exterior inset, preserving every interior row
    # and cropping palette indices by the same coordinates as the characters.
    defp trim(frame) do
      top = Enum.count(Enum.take_while(frame.lines, &(String.trim(&1) == "")))

      lines =
        frame.lines
        |> Enum.drop(top)
        |> Enum.reverse()
        |> Enum.drop_while(&(String.trim(&1) == ""))
        |> Enum.reverse()

      used = Enum.reject(lines, &(String.trim(&1) == ""))

      left =
        used |> Enum.map(&(byte_size(&1) - byte_size(String.trim_leading(&1, " ")))) |> Enum.min()

      right = used |> Enum.map(&String.length(String.trim_trailing(&1, " "))) |> Enum.max()
      cols = right - left
      rows = length(lines)
      lines = Enum.map(lines, &String.slice(&1, left, cols))
      colors = crop_colors(frame, top, left, cols, rows)

      {%{
         frame
         | lines: lines,
           text: Enum.join(lines, "\n"),
           cols: cols,
           rows: rows,
           colors: colors
       }, {left, top}}
    end

    defp crop_colors(%{colors: nil}, _top, _left, _cols, _rows), do: nil

    defp crop_colors(frame, top, left, cols, rows),
      do:
        for(
          row <- top..(top + rows - 1),
          into: <<>>,
          do: binary_part(frame.colors, row * frame.cols + left, cols)
        )

    defp summary(%{type: :flowchart, data: data}) do
      groups =
        Enum.map(data.groups, fn group ->
          "Group #{group.id}: #{flat(group.label)}#{if group.parent, do: " (inside #{group.parent})", else: ""}#{if group.direction, do: " [#{group.direction |> Atom.to_string() |> String.upcase()}]", else: ""}"
        end)

      nodes =
        Enum.map(data.nodes, fn node ->
          flat(node.label) <> if(node.group, do: " (group #{node.group})", else: "")
        end)

      Enum.join(
        [
          "Nodes: " <> Enum.join(nodes, ", ")
          | groups ++ Enum.map(data.edges, &relationship(&1, labels(data.nodes ++ data.groups)))
        ],
        "\n"
      )
    end

    defp summary(%{type: :state, data: data}) do
      states =
        Enum.map(data.states, fn state ->
          "#{flat(state.label)} [#{state.kind}]#{if state.parent, do: " (inside #{state.parent})", else: ""}"
        end)

      Enum.join(
        ["States" | states ++ Enum.map(data.edges, &relationship(&1, labels(data.states)))],
        "\n"
      )
    end

    defp summary(%{type: :er, data: data}) do
      entities =
        Enum.flat_map(data.entities, fn entity ->
          ["Entity #{flat(entity.label)}" | Enum.map(entity.attributes, &attribute_text/1)]
        end)

      known = labels(data.entities)

      edges =
        Enum.map(data.edges, fn edge ->
          "#{known[edge.from]} (#{cardinality(edge.from_cardinality)}) -- #{known[edge.to]} (#{cardinality(edge.to_cardinality)})#{if edge.label == "", do: "", else: ": " <> flat(edge.label)}#{if edge.identifying, do: " [identifying]", else: " [non-identifying]"}"
        end)

      Enum.join(["ER relationships" | entities ++ edges], "\n")
    end

    defp summary(%{type: :sequence, data: data}),
      do:
        Enum.join(
          [
            "Participants: " <> Enum.map_join(data.participants, ", ", & &1.label)
            | event_text(data.messages, labels(data.participants), "")
          ],
          "\n"
        )

    defp summary(%{type: :c4, data: data}) do
      elements =
        Enum.map(data.elements, fn n ->
          "#{n.label} [#{n.kind}#{if n.external, do: "; external", else: ""}] #{n.technology} #{n.description}#{if n.boundary, do: " (boundary #{n.boundary})", else: ""}"
        end)

      boundaries =
        Enum.map(
          data.boundaries,
          &"Boundary #{&1.id}: #{&1.label}#{if &1.parent, do: " (inside #{&1.parent})", else: ""}"
        )

      Enum.join(
        [
          "C4 #{data.level}"
          | elements ++
              boundaries ++ Enum.map(data.edges, &relationship(&1, labels(data.elements)))
        ],
        "\n"
      )
    end

    defp attribute_text(attribute) do
      fields =
        [
          attribute.type,
          attribute.name,
          Enum.map_join(attribute.keys, ",", &(Atom.to_string(&1) |> String.upcase()))
        ]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join(" ")

      "  " <>
        fields <> if(attribute.comment == "", do: "", else: " - " <> flat(attribute.comment))
    end

    defp cardinality(:one), do: "1"
    defp cardinality(:zero_or_one), do: "0..1"
    defp cardinality(:one_or_more), do: "1..*"
    defp cardinality(:zero_or_more), do: "0..*"
    defp flat(text), do: String.replace(text, "\n", "\\n")

    defp labels(nodes) do
      counts = Enum.frequencies_by(nodes, & &1.label)

      Map.new(
        nodes,
        &{&1.id, if(counts[&1.label] > 1, do: "#{&1.label} [#{&1.id}]", else: flat(&1.label))}
      )
    end

    defp relationship(edge, labels) do
      arrow = if edge.arrow, do: " -> ", else: " -- "

      labels[edge.from] <>
        arrow <>
        labels[edge.to] <>
        if(edge.label == "", do: "", else: ": " <> flat(edge.label)) <>
        if(edge.style == :dashed, do: " [dashed]", else: "")
    end

    defp event_text(events, labels, inset),
      do: Enum.flat_map(events, &event_text_line(&1, labels, inset))

    defp event_text_line(%{from: _} = event, labels, inset),
      do: [inset <> relationship(event, labels)]

    defp event_text_line(%{events: events, branches: branches} = event, labels, inset) do
      branch_lines =
        Enum.flat_map(branches, fn branch ->
          [inset <> "branch: " <> branch.label | event_text(branch.events, labels, inset <> "  ")]
        end)

      [inset <> "#{event.kind}: #{event.label}" | event_text(events, labels, inset <> "  ")] ++
        branch_lines ++ [inset <> "end #{event.kind}"]
    end

    defp event_text_line(%{kind: :note} = event, labels, inset),
      do: [
        inset <>
          "note #{event.position} #{Enum.map_join(event.participants, ", ", &labels[&1])}: #{event.label}"
      ]

    defp event_text_line(event, labels, inset),
      do: [inset <> "#{event.kind} #{labels[event.participant]}"]

    defp text?(value, bytes),
      do:
        byte_size(value) <= bytes and String.valid?(value) and
          not Regex.match?(~r/[\x00-\x08\x0b-\x1f\x7f]/, value)

    defp describe({:syntax, line, column, message}),
      do: "Mermaid line #{line}, column #{column}: #{message}"

    defp describe(:text_limits), do: "Diagram IDs must be <=64 bytes and labels <=256 bytes."

    defp describe(:styles),
      do: "Diagram colours belong to the terminal theme; remove style directives."

    defp describe(:diagram_limits),
      do:
        "Diagram exceeds 16 elements, 32 relationships, 8 participants, 48 events, scope/event depth 4, 6 groups/boundaries, 16 attributes per entity or 64 total attributes."

    defp describe(reason), do: "Invalid diagram: #{inspect(reason)}"
  end
end
