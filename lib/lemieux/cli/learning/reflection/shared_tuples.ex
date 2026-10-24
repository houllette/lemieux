defmodule Lemieux.CLI.Learning.Reflection.SharedTuples do
  @moduledoc """
  Lossless readable tuple references for complete public reflection records.

  Coding observations repeat source bodies at different printed line numbers.
  Whole-line sharing retained those bytes but still exceeded the frozen wire
  bound. This format shares the exact body and retains each original number,
  tab, newline and occurrence. Short numeric references also remove dictionary
  object/key overhead. Literal arrays in the tag namespace are escaped.

  Reconstruction first restores the original canonical plain/v1/v2 record,
  then uses its existing decoder. Independent intermediate and expanded limits,
  original digest and canonical re-encoding reject amplification, altered or
  injected dictionaries and ambiguous escapes. References convey data only.
  """
  alias Lemieux.CLI.Learning.Reflection.SharedValues
  alias Lemieux.Contract

  @encoding "lossless_shared_tuples/v3"
  @maximum 8_388_608
  # Restoring plain data temporarily nests it beside the empty legacy tables.
  # That fixed wrapper must not reject an original at the exact expanded cap.
  # The final reconstructed source still has the independent 8 MiB ceiling.
  @intermediate_limit @maximum + 1024
  @legacy ~w(text_encoding text_table value_table schema_table observation_table raw_record_sha256 raw_record_bytes)
  @fields ~w(text_encoding base_encoding text_table value_table schema_table observation_table line_table record raw_record_sha256 raw_record_bytes reference_legend)
  @legend "[-1,n]: text_table[n]; [-2,n]: value_table[n]; [-3,n,...]: schema_table[n] row; [-4,...]: exact text join; [-5,pairs]: literal object; [-6,items]: literal array; [-7,n]: observation_table[n]; [-8,pieces]: exact inline text; [-9,line,n]: decimal line number, tab and exact line_table[n] body."

  @spec encoding() :: String.t()
  def encoding, do: @encoding
  @spec maximum_expanded_bytes() :: pos_integer()
  def maximum_expanded_bytes, do: @maximum

  @spec compact(record :: map()) :: map()
  def compact(record) do
    base = SharedValues.compact(record)

    if byte_size(Contract.encode!(record)) <= @maximum and
         not Enum.any?(@fields, &Map.has_key?(record, &1)) do
      tuple = %{
        "record" => encode(Map.drop(base, @legacy)),
        "text_table" => table(base["text_table"]),
        "value_table" => Enum.map(table(base["value_table"]), &encode/1),
        "schema_table" => table(base["schema_table"]),
        "observation_table" => Enum.map(table(base["observation_table"]), &encode/1)
      }

      lines = line_dictionary(tuple)
      ids = lines |> Enum.with_index() |> Map.new()

      candidate =
        tuple
        |> pack_lines(ids)
        |> Map.merge(%{
          "text_encoding" => @encoding,
          "base_encoding" => base["text_encoding"] || "plain_json",
          "line_table" => lines,
          "raw_record_sha256" => Contract.digest(record),
          "raw_record_bytes" => byte_size(Contract.encode!(record)),
          "reference_legend" => @legend
        })

      Enum.min_by([base, candidate], &byte_size(Contract.encode!(&1)))
    else
      base
    end
  end

  @spec expand(record :: map()) :: {:ok, map()} | {:error, atom()}
  def expand(%{"text_encoding" => @encoding} = record) do
    with true <- Enum.sort(Map.keys(record)) == Enum.sort(@fields),
         size when is_integer(size) and size in 0..@maximum <- record["raw_record_bytes"],
         lines when is_list(lines) <- record["line_table"],
         true <- Enum.all?(lines, &is_binary/1),
         true <- byte_size(Contract.encode!(record)) <= @maximum,
         {:ok, restored, _bytes} <-
           decode(
             Map.take(record, ~w(record text_table value_table schema_table observation_table)),
             lines
           ),
         true <- is_map(restored["record"]),
         true <-
           Enum.all?(
             ~w(text_table value_table schema_table observation_table),
             &is_list(restored[&1])
           ),
         {:ok, base} <- restore_base(restored, record),
         {:ok, original} <- SharedValues.expand(base),
         true <- byte_size(Contract.encode!(original)) == size,
         true <- Contract.digest(original) == record["raw_record_sha256"],
         true <- compact(original) == record do
      {:ok, original}
    else
      _invalid -> {:error, :invalid_shared_tuples}
    end
  end

  def expand(record), do: SharedValues.expand(record)

  @doc "Indexes actual tuple containers and shared text bodies without expanding their references."
  @spec citation_index(record :: map()) :: [map()]
  def citation_index(record) do
    entries = walk(Map.take(record, ~w(record value_table observation_table)), "", record)

    texts =
      Enum.flat_map(~w(text_table line_table), fn name ->
        record[name]
        |> Enum.with_index()
        |> Enum.map(fn {_text, n} ->
          %{"pointer" => "/#{name}/#{n}", "type" => "shared_text", "entry_id" => "#{name}/#{n}"}
        end)
      end)

    Enum.uniq_by(entries ++ texts, & &1["pointer"])
  end

  defp walk(value, prefix, record) when is_map(value) or is_list(value) do
    entry = indexed(shape(value, record), prefix)

    children =
      if is_map(value),
        do: Map.to_list(value),
        else: Enum.with_index(value) |> Enum.map(fn {child, n} -> {to_string(n), child} end)

    entry ++
      Enum.flat_map(children, fn {key, child} ->
        escaped = key |> String.replace("~", "~0") |> String.replace("/", "~1")
        walk(child, prefix <> "/" <> escaped, record)
      end)
  end

  defp walk(_value, _prefix, _record), do: []

  defp shape([-2, n], record) when is_integer(n) and n >= 0,
    do: row_shape(Enum.at(record["value_table"], n), record)

  defp shape(value, record), do: row_shape(value, record)

  defp row_shape([-3, schema | values], record) when is_integer(schema) and schema >= 0 do
    case Enum.at(record["schema_table"], schema) do
      keys when is_list(keys) and length(keys) == length(values) ->
        Map.new(Enum.zip(keys, values))

      _invalid ->
        %{}
    end
  end

  defp row_shape(value, _record), do: value

  defp indexed(%{"type" => type, "id" => id} = value, prefix)
       when is_binary(type) and is_binary(id),
       do: [
         %{"pointer" => prefix, "type" => type, "entry_id" => id, "original_seq" => value["seq"]}
       ]

  defp indexed(_value, _prefix), do: []

  defp table(nil), do: []

  defp table(entries) do
    entries
    |> Enum.sort_by(fn {key, _} -> key |> String.slice(1..-1//1) |> String.to_integer() end)
    |> Enum.map(&elem(&1, 1))
  end

  defp encode(%{"$text" => "t" <> id} = value) when map_size(value) == 1,
    do: reference(-1, id, value)

  defp encode(%{"$value" => "v" <> id} = value) when map_size(value) == 1,
    do: reference(-2, id, value)

  defp encode(%{"$observation" => "o" <> id} = value) when map_size(value) == 1,
    do: reference(-7, id, value)

  defp encode(%{"$row" => ["s" <> id | items]} = value) when map_size(value) == 1 do
    case index(id) do
      {:ok, n} -> [-3, n | Enum.map(items, &encode/1)]
      :error -> encode_map(value)
    end
  end

  defp encode(%{"$join" => pieces} = value) when map_size(value) == 1 and is_list(pieces),
    do: [-4 | Enum.map(pieces, &encode/1)]

  defp encode(%{"$object" => pairs} = value) when map_size(value) == 1 and is_list(pairs),
    do: [-5, Enum.map(pairs, &encode/1)]

  defp encode(value) when is_map(value), do: encode_map(value)

  defp encode(value) when is_list(value) do
    items = Enum.map(value, &encode/1)
    if match?([tag | _] when tag in -9..-1, value), do: [-6, items], else: items
  end

  defp encode(value), do: value
  defp encode_map(value), do: Map.new(value, fn {key, item} -> {key, encode(item)} end)

  defp reference(tag, id, value) do
    case index(id) do
      {:ok, n} -> [tag, n]
      :error -> encode_map(value)
    end
  end

  defp index(id) do
    case Integer.parse(id) do
      {n, ""} when n in 0..100_000 -> if Integer.to_string(n) == id, do: {:ok, n}, else: :error
      _invalid -> :error
    end
  end

  defp line_dictionary(tuple) do
    tuple
    |> leaves()
    |> Enum.flat_map(&String.split(&1, ~r/(?<=\n)/u, trim: true))
    |> Enum.reduce(%{}, &count_line/2)
    |> Enum.filter(fn {body, n} ->
      n > 1 and byte_size(body) >= 32 and (n - 1) * byte_size(JSON.encode!(body)) > n * 12 + 16
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp leaves(value) when is_binary(value), do: [value]

  defp leaves(value) when is_map(value),
    do: Enum.flat_map(value, fn {_, item} -> leaves(item) end)

  defp leaves(value) when is_list(value), do: Enum.flat_map(value, &leaves/1)
  defp leaves(_value), do: []

  defp count_line(line, counts) do
    case numbered(line) do
      {_number, body} -> Map.update(counts, body, 1, &(&1 + 1))
      nil -> counts
    end
  end

  defp numbered(line) do
    case Regex.run(~r/\A([0-9]{1,9})\t(.*)\z/su, line) do
      [_, number, body] ->
        n = String.to_integer(number)
        if Integer.to_string(n) == number, do: {n, body}

      _invalid ->
        nil
    end
  end

  defp pack_lines(value, ids) when is_binary(value) do
    pieces =
      value
      |> String.split(~r/(?<=\n)/u, trim: true)
      |> Enum.reduce([], &line_piece(&1, &2, ids))
      |> Enum.reverse()

    if Enum.any?(pieces, &is_list/1), do: [-8, pieces], else: value
  end

  defp pack_lines(value, ids) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, pack_lines(item, ids)} end)

  defp pack_lines(value, ids) when is_list(value), do: Enum.map(value, &pack_lines(&1, ids))
  defp pack_lines(value, _ids), do: value

  defp line_piece(line, pieces, ids) do
    case numbered(line) do
      {n, body} ->
        case Map.fetch(ids, body) do
          {:ok, id} -> [[-9, n, id] | pieces]
          :error -> literal_piece(line, pieces)
        end

      nil ->
        literal_piece(line, pieces)
    end
  end

  defp literal_piece(line, [prior | rest]) when is_binary(prior), do: [prior <> line | rest]
  defp literal_piece(line, rest), do: [line | rest]

  defp decode([-1, n], _lines) when n in 0..100_000, do: sized(%{"$text" => "t#{n}"})
  defp decode([-2, n], _lines) when n in 0..100_000, do: sized(%{"$value" => "v#{n}"})
  defp decode([-7, n], _lines) when n in 0..100_000, do: sized(%{"$observation" => "o#{n}"})

  defp decode([-3, n | items], lines) when n in 0..100_000 do
    with {:ok, values, _size} <- decode_list(items, lines),
         do: sized(%{"$row" => ["s#{n}" | values]})
  end

  defp decode([-4 | pieces], lines) do
    with {:ok, values, _size} <- decode_list(pieces, lines), do: sized(%{"$join" => values})
  end

  defp decode([-5, pairs], lines) when is_list(pairs) do
    with {:ok, values, _size} <- decode_list(pairs, lines), do: sized(%{"$object" => values})
  end

  defp decode([-6, items], lines) when is_list(items), do: decode_list(items, lines)

  defp decode([-8, pieces], lines) when is_list(pieces) do
    case Enum.reduce_while(pieces, {:ok, [], 2}, &join_piece(&1, &2, lines)) do
      {:ok, values, size} -> {:ok, values |> Enum.reverse() |> IO.iodata_to_binary(), size}
      error -> error
    end
  end

  defp decode([tag | _], _lines) when tag in -9..-1, do: {:error, :invalid_shared_tuples}
  defp decode(value, lines) when is_list(value), do: decode_list(value, lines)

  defp decode(value, lines) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}, 2 + max(0, map_size(value) - 1)}, fn {key, item},
                                                                             {:ok, result, size} ->
      with true <- is_binary(key),
           {:ok, decoded, bytes} <- decode(item, lines),
           total = size + byte_size(JSON.encode!(key)) + 1 + bytes,
           true <- total <= @intermediate_limit do
        {:cont, {:ok, Map.put(result, key, decoded), total}}
      else
        _invalid -> {:halt, {:error, :invalid_shared_tuples}}
      end
    end)
  end

  defp decode(value, _lines)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: sized(value)

  defp decode(_value, _lines), do: {:error, :invalid_shared_tuples}

  defp decode_list(items, lines) do
    initial = {:ok, [], 2 + max(0, length(items) - 1)}

    case Enum.reduce_while(items, initial, &decode_item(&1, &2, lines)) do
      {:ok, values, size} -> {:ok, Enum.reverse(values), size}
      error -> error
    end
  end

  defp decode_item(item, {:ok, values, size}, lines) do
    with {:ok, decoded, bytes} <- decode(item, lines),
         true <- size + bytes <= @intermediate_limit do
      {:cont, {:ok, [decoded | values], size + bytes}}
    else
      _invalid -> {:halt, {:error, :invalid_shared_tuples}}
    end
  end

  defp join_piece(piece, {:ok, pieces, size}, lines) do
    with {:ok, text} <- line_text(piece, lines),
         total = size + byte_size(JSON.encode!(text)) - 2,
         true <- total <= @intermediate_limit do
      {:cont, {:ok, [text | pieces], total}}
    else
      _invalid -> {:halt, {:error, :invalid_shared_tuples}}
    end
  end

  defp line_text(text, _lines) when is_binary(text), do: {:ok, text}

  defp line_text([-9, number, id], lines) when number in 0..999_999_999 and id in 0..100_000 do
    case Enum.at(lines, id) do
      body when is_binary(body) -> {:ok, Integer.to_string(number) <> "\t" <> body}
      _invalid -> {:error, :invalid_shared_tuples}
    end
  end

  defp line_text(_invalid, _lines), do: {:error, :invalid_shared_tuples}

  defp sized(value) do
    size = byte_size(JSON.encode!(value))
    if size <= @intermediate_limit, do: {:ok, value, size}, else: {:error, :invalid_shared_tuples}
  end

  defp restore_base(restored, %{"base_encoding" => "plain_json"}), do: {:ok, restored["record"]}

  defp restore_base(restored, %{"base_encoding" => encoding} = record)
       when encoding in ["lossless_shared_text/v1", "lossless_shared_values/v2"] do
    fields =
      if encoding == "lossless_shared_text/v1",
        do: [{"text_table", "t"}, {"observation_table", "o"}],
        else: [{"text_table", "t"}, {"value_table", "v"}, {"schema_table", "s"}]

    base = Map.merge(restored["record"], Map.take(record, ~w(raw_record_sha256 raw_record_bytes)))

    tables =
      Map.new(fields, fn {field, prefix} ->
        {field,
         restored[field]
         |> Enum.with_index()
         |> Map.new(fn {value, n} -> {prefix <> to_string(n), value} end)}
      end)

    {:ok, base |> Map.merge(tables) |> Map.put("text_encoding", encoding)}
  end

  defp restore_base(_restored, _record), do: {:error, :invalid_shared_tuples}
end
