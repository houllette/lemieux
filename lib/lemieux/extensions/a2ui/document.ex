defmodule Lemieux.Extensions.A2UI.Document do
  @moduledoc """
  Validates the read-only terminal subset of A2UI v0.9.1.

  Each fenced stream is its own document. Only an agreed catalog is accepted;
  no identifier causes a fetch. Graph traversal has both a depth and a shared
  visit budget, including repeated references, so a small DAG cannot expand
  exponentially. Unsupported or malformed documents return `:error`; hosts
  retain their original text rather than rendering a partial, misleading UI.
  """
  alias Lemieux.Extensions.A2UI
  alias Lemieux.Extensions.A2UI.Diagram

  @properties %{
    "Column" => ~w(children gap justify height),
    "Row" => ~w(children gap justify height),
    "Text" => ~w(text),
    "ProgressBar" => ~w(value label),
    "Sparkline" => ~w(label values sampleRate unit),
    "BarChart" => ~w(title labels values),
    "Table" => ~w(headers rows),
    "FileTree" => ~w(paths root)
  }
  @layout ~w(width padding align compact)

  @doc "Returns resolved leaf components, in surface/tree order."
  @spec decode(source :: String.t()) :: {:ok, [map()]} | :error
  def decode(source) do
    with {:ok, trees} <- layout(source), do: {:ok, Enum.flat_map(trees, &leaves/1)}
  end

  @doc "Returns resolved surface roots, preserving containers and their layout properties."
  @spec layout(source :: String.t()) :: {:ok, [map()]} | :error
  def layout(source) do
    case validate(source) do
      {:ok, trees} -> {:ok, trees}
      {:error, _message} -> :error
    end
  end

  @doc "Validates a complete fence, returning a bounded diagnostic suitable for display."
  @spec validate(source :: String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def validate(source) when is_binary(source) and byte_size(source) <= 16_384 do
    with {:ok, messages} <- messages(source),
         true <- length(messages) in 1..32,
         {:ok, surfaces} <- reduce(messages),
         {:ok, trees, _budget} <- expand_surfaces(surfaces, 32),
         :ok <- diagram_count(trees) do
      {:ok, trees}
    else
      {:error, message} ->
        {:error, message}

      _invalid ->
        {:error,
         "Invalid A2UI JSONL, protocol messages or document limits (32 messages/components)."}
    end
  end

  def validate(_source), do: {:error, "A2UI fence exceeds 16 KiB or is not text."}

  defp diagram_count(trees) do
    count = Enum.count(Enum.flat_map(trees, &leaves/1), &(&1["component"] in Diagram.types()))

    if count <= 4,
      do: :ok,
      else:
        {:error,
         "A2UI fence contains #{count} diagrams; maximum 4. Split the gallery across separate fences."}
  end

  defp leaves(%{"component" => type, "children" => children}) when type in ["Column", "Row"],
    do: Enum.flat_map(children, &leaves/1)

  defp leaves(leaf), do: [leaf]

  defp messages(source) do
    case JSON.decode(source) do
      {:ok, messages} when is_list(messages) ->
        {:ok, messages}

      {:ok, message} when is_map(message) ->
        {:ok, [message]}

      _jsonl ->
        source
        |> String.split("\n", trim: true)
        |> Enum.reduce_while({:ok, []}, &decode_line/2)
    end
  end

  defp decode_line(line, {:ok, acc}) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> {:cont, {:ok, acc ++ [message]}}
      _invalid -> {:halt, :error}
    end
  end

  defp reduce(messages),
    do:
      Enum.reduce_while(Enum.with_index(messages, 1), {:ok, []}, fn {message, index},
                                                                    {:ok, surfaces} ->
        case message(message, surfaces) do
          {:ok, surfaces} ->
            {:cont, {:ok, surfaces}}

          :error ->
            {:halt,
             {:error,
              "Invalid A2UI message #{index}: check v0.9.1, catalog, surface IDs and supported component fields."}}
        end
      end)

  defp message(%{"version" => "v0.9.1"} = message, surfaces) when map_size(message) == 2 do
    [{kind, data}] = Map.delete(message, "version") |> Map.to_list()
    operation(kind, data, surfaces)
  end

  defp message(_message, _surfaces), do: :error

  defp operation("createSurface", %{"surfaceId" => id, "catalogId" => catalog} = data, surfaces) do
    if keys?(data, ~w(surfaceId catalogId)) and identifier?(id) and catalog == A2UI.catalog_id() and
         length(surfaces) < 4 and not Enum.any?(surfaces, &(&1.id == id)),
       do: {:ok, surfaces ++ [%{id: id, components: %{}, data: %{}}]},
       else: :error
  end

  defp operation("deleteSurface", %{"surfaceId" => id} = data, surfaces) do
    if map_size(data) == 1 and Enum.any?(surfaces, &(&1.id == id)),
      do: {:ok, Enum.reject(surfaces, &(&1.id == id))},
      else: :error
  end

  defp operation(
         "updateComponents",
         %{"surfaceId" => id, "components" => components} = data,
         surfaces
       ) do
    with true <- keys?(data, ~w(surfaceId components)),
         true <- is_list(components) and length(components) in 1..32,
         true <- Enum.all?(components, &component?/1),
         {:ok, next} <- update(surfaces, id, &merge_components(&1, components)),
         true <- Enum.sum(Enum.map(next, &map_size(&1.components))) <= 32 do
      {:ok, next}
    else
      _invalid -> :error
    end
  end

  defp operation("updateDataModel", %{"surfaceId" => id} = data, surfaces) do
    with true <- keys?(data, ~w(surfaceId path value)),
         {:ok, path} <- pointer(Map.get(data, "path", "/")),
         {:ok, next} <- update(surfaces, id, &update_model(&1, path, Map.fetch(data, "value"))) do
      {:ok, next}
    else
      _invalid -> :error
    end
  end

  defp operation(_kind, _data, _surfaces), do: :error

  defp merge_components(surface, components) do
    merged = Map.merge(surface.components, Map.new(components, &{&1["id"], &1}))
    {:ok, %{surface | components: merged}}
  end

  defp update_model(surface, path, value) do
    with {:ok, model} <- put_path(surface.data, path, value), do: {:ok, %{surface | data: model}}
  end

  defp update(surfaces, id, fun) do
    case Enum.find_index(surfaces, &(&1.id == id)) do
      nil ->
        :error

      index ->
        with {:ok, surface} <- fun.(Enum.at(surfaces, index)),
             do: {:ok, List.replace_at(surfaces, index, surface)}
    end
  end

  defp component?(%{"id" => id, "component" => type} = component) do
    properties = Map.merge(@properties, Diagram.properties())

    identifier?(id) and Map.has_key?(properties, type) and
      keys?(component, ["id", "component" | @layout ++ Map.get(properties, type, [])])
  end

  defp component?(_component), do: false

  defp expand_surfaces(surfaces, budget),
    do:
      Enum.reduce_while(surfaces, {:ok, [], budget}, fn surface, {:ok, all, budget} ->
        case expand("root", surface, [], budget) do
          {:ok, tree, budget} -> {:cont, {:ok, all ++ [tree], budget}}
          {:error, _message} = error -> {:halt, error}
        end
      end)

  defp expand(id, surface, ancestors, budget) when budget > 0 and length(ancestors) < 8 do
    with false <- id in ancestors,
         component when is_map(component) <- Map.get(surface.components, id),
         {:ok, resolved} <- resolve(component, surface.data),
         true <- valid_layout?(resolved) do
      expand_component(resolved, surface, [id | ancestors], budget - 1)
    else
      _invalid ->
        {:error,
         "Invalid A2UI tree: missing component, cyclic reference, binding or layout for #{safe_id(id)}."}
    end
  end

  defp expand(_id, _surface, _ancestors, _budget),
    do: {:error, "A2UI tree exceeds depth 8 or the shared 32-visit limit."}

  defp expand_component(
         %{"component" => type, "children" => children} = container,
         surface,
         ancestors,
         budget
       )
       when type in ["Column", "Row"] and is_list(children) and length(children) in 1..32 do
    with {:ok, trees, budget} <-
           Enum.reduce_while(
             children,
             {:ok, [], budget},
             &expand_child(&1, &2, surface, ancestors)
           ) do
      {:ok, Map.put(container, "children", trees), budget}
    end
  end

  defp expand_component(leaf, _surface, _ancestors, budget),
    do: if(valid_leaf?(leaf), do: {:ok, leaf, budget}, else: {:error, component_error(leaf)})

  defp expand_child(child, {:ok, leaves, remaining}, surface, ancestors) do
    case expand(child, surface, ancestors, remaining) do
      {:ok, next, remaining} -> {:cont, {:ok, leaves ++ [next], remaining}}
      {:error, _message} = error -> {:halt, error}
    end
  end

  defp component_error(node) do
    type = node["component"]
    message = "Component #{safe_id(node["id"])} (#{type}) has invalid fields or values."

    message =
      if type == "Sparkline",
        do:
          message <>
            " sampleRate must be numeric samples/second (0.001..100), e.g. 0.0167 for one sample/minute; values must be numeric samples.",
        else: message

    if type in Diagram.types(),
      do:
        message <> " Use diagram_preview with componentSchema=\"#{type}\" for its record format.",
      else: message
  end

  defp safe_id(id), do: if(identifier?(id), do: id, else: "unknown")

  defp resolve(component, data),
    do:
      Enum.reduce_while(component, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case binding(value, data) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, :error}
        end
      end)

  defp binding(%{"path" => path} = value, data) when map_size(value) == 1 do
    with {:ok, keys} <- pointer(path), do: fetch_path(data, keys)
  end

  defp binding(value, _data), do: {:ok, value}

  defp pointer("/"), do: {:ok, []}
  defp pointer(""), do: {:ok, []}

  defp pointer("/" <> path) do
    keys = String.split(path, "/")

    if length(keys) <= 8 and
         Enum.all?(keys, &(byte_size(&1) <= 128 and not Regex.match?(~r/~(?![01])/, &1))),
       do: {:ok, Enum.map(keys, &(&1 |> String.replace("~1", "/") |> String.replace("~0", "~")))},
       else: :error
  end

  defp pointer(_path), do: :error
  defp fetch_path(data, []), do: {:ok, data}

  defp fetch_path(data, [key | rest]) when is_map(data),
    do: with({:ok, value} <- Map.fetch(data, key), do: fetch_path(value, rest))

  defp fetch_path(data, [key | rest]) when is_list(data) do
    with {index, ""} when index >= 0 <- Integer.parse(key),
         {:ok, value} <- Enum.fetch(data, index) do
      fetch_path(value, rest)
    else
      _invalid -> :error
    end
  end

  defp fetch_path(_data, _path), do: :error
  defp put_path(_data, [], {:ok, value}), do: {:ok, value}
  defp put_path(_data, [], :error), do: {:ok, %{}}

  defp put_path(data, [key], value) when is_map(data),
    do:
      {:ok,
       case value do
         {:ok, value} -> Map.put(data, key, value)
         :error -> Map.delete(data, key)
       end}

  defp put_path(data, [key | rest], value) when is_map(data) do
    with {:ok, next} <- put_path(Map.get(data, key, %{}), rest, value),
         do: {:ok, Map.put(data, key, next)}
  end

  defp put_path(_data, _path, _value), do: :error

  defp valid_leaf?(%{"component" => "Text", "text" => text}), do: text?(text, 256)

  defp valid_leaf?(%{"component" => "ProgressBar", "label" => label, "value" => value}),
    do: text?(label, 64) and number?(value, 0, 100)

  defp valid_leaf?(
         %{"component" => "Sparkline", "label" => label, "values" => values, "sampleRate" => rate} =
           node
       ),
       do:
         text?(label, 64) and numbers?(values, 128, -1.0e9) and number?(rate, 0.001, 100) and
           text?(Map.get(node, "unit", ""), 16)

  defp valid_leaf?(%{
         "component" => "BarChart",
         "title" => title,
         "labels" => labels,
         "values" => values
       }),
       do:
         text?(title, 64) and texts?(labels, 16, 32) and numbers?(values, 16, 0) and
           length(labels) == length(values)

  defp valid_leaf?(%{"component" => "Table", "headers" => headers, "rows" => rows}),
    do:
      texts?(headers, 8, 64) and is_list(rows) and length(rows) <= 16 and
        Enum.all?(rows, fn row ->
          is_list(row) and length(row) == length(headers) and Enum.all?(row, &cell?/1)
        end)

  defp valid_leaf?(%{"component" => "FileTree", "paths" => paths} = node),
    do: texts?(paths, 128, 256) and text?(Map.get(node, "root", "."), 64)

  defp valid_leaf?(node), do: Diagram.valid_input?(node)

  defp valid_layout?(node) do
    Enum.all?(node, fn {key, value} -> layout_property?(key, value) end)
  end

  defp layout_property?("width", value), do: is_integer(value) and value in 1..200
  defp layout_property?("height", value), do: is_integer(value) and value in 1..40

  defp layout_property?(key, value) when key in ["padding", "gap"],
    do: is_integer(value) and value in 0..4

  defp layout_property?("align", value), do: value in ~w(start center end stretch)
  defp layout_property?("justify", value), do: value in ~w(start center end spaceBetween)
  defp layout_property?("compact", value), do: is_boolean(value)
  defp layout_property?(_key, _value), do: true
  defp keys?(map, keys), do: Enum.all?(Map.keys(map), &(&1 in keys))
  defp identifier?(value), do: is_binary(value) and Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, value)

  defp text?(text, max),
    do:
      is_binary(text) and String.valid?(text) and String.length(text) <= max and
        not Regex.match?(~r/[\x00-\x08\x0b-\x1f\x7f]/, text)

  defp texts?(values, max, chars),
    do: is_list(values) and length(values) in 1..max and Enum.all?(values, &text?(&1, chars))

  defp number?(value, lo, hi), do: is_number(value) and value >= lo and value <= hi

  defp numbers?(values, max, lo),
    do:
      is_list(values) and length(values) in 1..max and Enum.all?(values, &number?(&1, lo, 1.0e9))

  defp cell?(value),
    do: text?(value, 64) or number?(value, -1.0e9, 1.0e9) or is_boolean(value) or is_nil(value)
end
