defmodule Lemieux.CLI.Learning.Reflection.SharedValues do
  @moduledoc """
  Lossless, readable dictionaries for complete public reflection records.

  Whole strings alone left a real combined trace above the frozen source-wire
  bound. Repeated object shapes, complete values and lines inside otherwise
  different outputs also need not repeat their storage. References retain every
  occurrence and order; joined text preserves exact bytes, including newlines.

  Version-one sources keep their original decoder and canonical representation.
  Version two additionally verifies exact reconstruction and its own canonical
  encoding. Cycles, changed tables and unused injected entries refuse expansion.
  The source-wire and lesson-wire policies remain the caller's; expansion is
  separately bounded at 8 MiB. Nothing here conveys host authority or code.
  """

  alias Lemieux.CLI.Learning.Reflection.SharedText
  alias Lemieux.Contract

  @encoding "lossless_shared_values/v2"
  @fields ~w(text_encoding text_table value_table schema_table observation_table raw_record_sha256 raw_record_bytes)
  @reserved ~w($text $value $row $join $object $observation)
  @maximum 8_388_608
  @lines ~r/(?<=\n)/u

  @spec encoding() :: String.t()
  def encoding, do: @encoding

  @spec maximum_expanded_bytes() :: pos_integer()
  def maximum_expanded_bytes, do: @maximum

  @spec compact(record :: map()) :: map()
  def compact(record) do
    bytes = Contract.encode!(record)

    if byte_size(bytes) <= @maximum and not Enum.any?(@fields, &Map.has_key?(record, &1)) do
      counts = collect(record, %{texts: %{}, values: %{}, schemas: %{}})
      tables = dictionaries(counts)

      encoded =
        record
        |> encode(tables, nil)
        |> Map.merge(%{
          "text_encoding" => @encoding,
          "text_table" => invert(tables.texts),
          "value_table" =>
            Map.new(tables.values, fn {digest, key} ->
              {key, encode(elem(counts.values[digest], 0), tables, digest)}
            end),
          "schema_table" => invert(tables.schemas),
          "raw_record_sha256" => Contract.digest(record),
          "raw_record_bytes" => byte_size(bytes)
        })

      Enum.min_by([record, SharedText.compact(record), encoded], &byte_size(Contract.encode!(&1)))
    else
      record
    end
  end

  @spec expand(record :: map()) :: {:ok, map()} | {:error, atom()}
  def expand(%{"text_encoding" => @encoding} = record) do
    with %{} = texts <- record["text_table"],
         %{} = values <- record["value_table"],
         %{} = schemas <- record["schema_table"],
         size when is_integer(size) and size in 0..@maximum <- record["raw_record_bytes"],
         tables = %{texts: texts, values: values, schemas: schemas, active: %{}},
         {:ok, original, ^size} <- decode(Map.drop(record, @fields), tables),
         true <- Contract.digest(original) == record["raw_record_sha256"],
         true <- compact(original) == record do
      {:ok, original}
    else
      _invalid -> {:error, :invalid_shared_values}
    end
  end

  def expand(%{"text_encoding" => "lossless_shared_text/v1"} = record),
    do: SharedText.expand(record)

  def expand(record) when is_map(record) do
    if Enum.any?(@fields, &Map.has_key?(record, &1)),
      do: {:error, :invalid_shared_values},
      else: {:ok, record}
  end

  def expand(_invalid), do: {:error, :invalid_shared_values}

  @doc "Indexes actual encoded entry containers and text fragments without expanding references."
  @spec citation_index(record :: map()) :: [map()]
  def citation_index(record) do
    entries = walk(Map.drop(record, ~w(text_table schema_table)), "", record)

    texts =
      (record["text_table"] || %{})
      |> Enum.sort()
      |> Enum.map(fn {key, _text} ->
        %{"pointer" => "/text_table/" <> key, "type" => "shared_text", "entry_id" => key}
      end)

    Enum.uniq_by(entries ++ texts, & &1["pointer"])
  end

  defp walk(value, prefix, record) when is_map(value) do
    item = shape(value, record)
    entry = indexed_entry(item, prefix)

    children =
      Enum.flat_map(value, fn {key, child} ->
        escaped = key |> String.replace("~", "~0") |> String.replace("/", "~1")
        walk(child, prefix <> "/" <> escaped, record)
      end)

    entry ++ children
  end

  defp walk(value, prefix, record) when is_list(value),
    do:
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {child, n} -> walk(child, prefix <> "/" <> to_string(n), record) end)

  defp walk(_value, _prefix, _record), do: []

  defp shape(%{"$value" => key}, record), do: row_shape(record["value_table"][key] || %{}, record)
  defp shape(value, record), do: row_shape(value, record)

  defp row_shape(%{"$row" => [schema | items]}, record) do
    keys = record["schema_table"][schema] || []
    if length(keys) == length(items), do: Map.new(Enum.zip(keys, items)), else: %{}
  end

  defp row_shape(value, _record), do: value

  defp indexed_entry(%{"type" => type, "id" => id} = entry, prefix)
       when is_binary(type) and is_binary(id),
       do: [
         %{"pointer" => prefix, "type" => type, "entry_id" => id, "original_seq" => entry["seq"]}
       ]

  defp indexed_entry(_value, _prefix), do: []

  defp collect(value, counts) when is_binary(value),
    do: update_in(counts.texts, &Map.update(&1, value, 1, fn n -> n + 1 end))

  defp collect(value, counts) when is_map(value) do
    keys = value |> Map.keys() |> Enum.sort()
    counts = update_in(counts.schemas, &Map.update(&1, keys, 1, fn n -> n + 1 end))

    Enum.reduce(value, collect_value(value, counts), fn {_, child}, acc -> collect(child, acc) end)
  end

  defp collect(value, counts) when is_list(value),
    do: Enum.reduce(value, collect_value(value, counts), &collect/2)

  defp collect(_value, counts), do: counts

  defp collect_value(value, counts) do
    if byte_size(Contract.encode!(%{"value" => value})) >= 96 do
      digest = value_digest(value)
      update_in(counts.values, &Map.update(&1, digest, {value, 1}, fn {v, n} -> {v, n + 1} end))
    else
      counts
    end
  end

  defp dictionaries(counts) do
    whole = MapSet.new(for {text, n} <- counts.texts, n > 1 and byte_size(text) >= 128, do: text)

    fragments =
      counts.texts
      |> Enum.reject(fn {text, _} -> MapSet.member?(whole, text) end)
      |> Enum.reduce(%{}, &count_fragments/2)
      |> Enum.filter(&saving_fragment?/1)
      |> Enum.map(&elem(&1, 0))

    texts = whole |> MapSet.union(MapSet.new(fragments)) |> Enum.sort() |> identifiers("t")

    values =
      counts.values
      |> Enum.filter(fn {_, {_, n}} -> n > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> identifiers("v")

    schemas =
      counts.schemas
      |> Enum.filter(&saving_schema?/1)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> identifiers("s")

    %{texts: texts, values: values, schemas: schemas}
  end

  defp count_fragments({text, n}, counts),
    do: Enum.reduce(lines(text), counts, &Map.update(&2, &1, n, fn count -> count + n end))

  defp saving_fragment?({text, n}),
    do: n > 1 and byte_size(text) >= 32 and (n - 1) * byte_size(JSON.encode!(text)) > n * 20 + 12

  defp saving_schema?({keys, n}),
    do:
      n >= 3 and length(keys) >= 3 and Enum.all?(keys, &is_binary/1) and
        Enum.sum(Enum.map(keys, &(byte_size(JSON.encode!(&1)) + 1))) > 24

  defp identifiers(values, prefix),
    do:
      values |> Enum.with_index() |> Map.new(fn {value, n} -> {value, prefix <> to_string(n)} end)

  defp invert(table), do: Map.new(table, fn {value, key} -> {key, value} end)
  defp lines(text), do: String.split(text, @lines, trim: true)
  defp value_digest(value), do: Contract.digest(%{"value" => value})

  defp encode(value, tables, _skip) when is_binary(value) do
    case Map.fetch(tables.texts, value) do
      {:ok, key} -> %{"$text" => key}
      :error -> encode_fragments(value, tables.texts)
    end
  end

  defp encode(value, tables, skip) when is_map(value) or is_list(value) do
    digest = value_digest(value)

    case Map.fetch(tables.values, digest) do
      {:ok, key} when digest != skip -> %{"$value" => key}
      _literal -> encode_container(value, tables)
    end
  end

  defp encode(value, _tables, _skip), do: value

  defp encode_fragments(text, table) do
    pieces = text |> lines() |> Enum.reduce([], &text_piece(&1, &2, table)) |> Enum.reverse()
    if Enum.any?(pieces, &is_map/1), do: %{"$join" => pieces}, else: text
  end

  defp text_piece(text, pieces, table) do
    case {Map.fetch(table, text), pieces} do
      {{:ok, key}, _} -> [%{"$text" => key} | pieces]
      {:error, [previous | rest]} when is_binary(previous) -> [previous <> text | rest]
      {:error, _} -> [text | pieces]
    end
  end

  defp encode_container(value, tables) when is_list(value),
    do: Enum.map(value, &encode(&1, tables, nil))

  defp encode_container(value, tables) do
    pairs =
      value |> Enum.sort() |> Enum.map(fn {key, item} -> {key, encode(item, tables, nil)} end)

    schema = Map.get(tables.schemas, Enum.map(pairs, &elem(&1, 0)))
    encode_pairs(pairs, schema, Enum.any?(@reserved, &Map.has_key?(value, &1)))
  end

  defp encode_pairs(pairs, _schema, true),
    do: %{"$object" => Enum.map(pairs, fn {key, value} -> [key, value] end)}

  defp encode_pairs(pairs, nil, false), do: Map.new(pairs)

  defp encode_pairs(pairs, schema, false),
    do: %{"$row" => [schema | Enum.map(pairs, &elem(&1, 1))]}

  defp decode(%{"$text" => key} = value, tables) when map_size(value) == 1 do
    with {:ok, text} when is_binary(text) <- Map.fetch(tables.texts, key), do: sized(text)
  end

  defp decode(%{"$value" => key} = value, tables) when map_size(value) == 1 do
    with false <- Map.has_key?(tables.active, key),
         true <- map_size(tables.active) < 128,
         {:ok, item} <- Map.fetch(tables.values, key) do
      decode(item, %{tables | active: Map.put(tables.active, key, true)})
    else
      _invalid -> {:error, :invalid_shared_values}
    end
  end

  defp decode(%{"$row" => [schema | items]} = value, tables) when map_size(value) == 1 do
    with {:ok, keys} when is_list(keys) <- Map.fetch(tables.schemas, schema),
         true <- length(keys) == length(items),
         true <- Enum.all?(keys, &is_binary/1),
         true <- length(keys) == MapSet.size(MapSet.new(keys)) do
      decode_object(Enum.zip(keys, items), tables)
    else
      _invalid -> {:error, :invalid_shared_values}
    end
  end

  defp decode(%{"$join" => pieces} = value, tables)
       when map_size(value) == 1 and is_list(pieces) do
    case Enum.reduce_while(pieces, {:ok, [], 2}, &decode_piece(&1, &2, tables)) do
      {:ok, texts, size} -> {:ok, texts |> Enum.reverse() |> IO.iodata_to_binary(), size}
      error -> error
    end
  end

  defp decode(%{"$object" => pairs} = value, tables) when map_size(value) == 1 do
    with true <- is_list(pairs),
         true <- Enum.all?(pairs, &match?([key, _] when is_binary(key), &1)),
         tuples = Enum.map(pairs, fn [key, item] -> {key, item} end),
         true <- length(tuples) == MapSet.size(MapSet.new(tuples, &elem(&1, 0))) do
      decode_object(tuples, tables)
    else
      _invalid -> {:error, :invalid_shared_values}
    end
  end

  defp decode(value, tables) when is_map(value), do: decode_object(Map.to_list(value), tables)

  defp decode(value, tables) when is_list(value) do
    initial = {:ok, [], 2 + max(0, length(value) - 1)}

    case Enum.reduce_while(value, initial, &decode_item(&1, &2, tables)) do
      {:ok, items, size} -> {:ok, Enum.reverse(items), size}
      error -> error
    end
  end

  defp decode(value, _tables)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: sized(value)

  defp decode(_value, _tables), do: {:error, :invalid_shared_values}

  defp decode_piece(piece, {:ok, texts, size}, tables) do
    with true <- is_binary(piece) or match?(%{"$text" => _}, piece),
         {:ok, text, bytes} when is_binary(text) <- decode(piece, tables),
         true <- size + bytes - 2 <= @maximum do
      {:cont, {:ok, [text | texts], size + bytes - 2}}
    else
      _invalid -> {:halt, {:error, :invalid_shared_values}}
    end
  end

  defp decode_item(item, {:ok, items, size}, tables) do
    with {:ok, decoded, bytes} <- decode(item, tables), true <- size + bytes <= @maximum do
      {:cont, {:ok, [decoded | items], size + bytes}}
    else
      _invalid -> {:halt, {:error, :invalid_shared_values}}
    end
  end

  defp decode_object(pairs, tables) do
    initial = {:ok, %{}, 2 + max(0, length(pairs) - 1)}

    Enum.reduce_while(pairs, initial, fn {key, item}, {:ok, values, size} ->
      with true <- is_binary(key),
           {:ok, decoded, bytes} <- decode(item, tables),
           total = size + byte_size(JSON.encode!(key)) + 1 + bytes,
           true <- total <= @maximum do
        {:cont, {:ok, Map.put(values, key, decoded), total}}
      else
        _invalid -> {:halt, {:error, :invalid_shared_values}}
      end
    end)
  end

  defp sized(value) do
    size = byte_size(JSON.encode!(value))
    if size <= @maximum, do: {:ok, value, size}, else: {:error, :invalid_shared_values}
  end
end
