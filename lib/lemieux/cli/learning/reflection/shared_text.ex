defmodule Lemieux.CLI.Learning.Reflection.SharedText do
  @moduledoc """
  Lossless sharing of repeated public text in a reflection record.

  A combined profile/asset trace exceeded the reflector's 1 MiB wire limit.
  Identical bytes need not repeat their storage; each occurrence and its place
  in every trajectory still matters. References preserve those positions and keep
  each distinct text once. Expansion must reproduce the original digest and
  canonical encoding; unused text and forged references are rejected.

  The wire limit remains the reflector's. Expansion has a separate 8 MiB
  ceiling, checked while decoding, so references cannot create an unbounded
  source. This codec carries data and integrity metadata, never authority.
  """
  alias Lemieux.Contract

  @encoding "lossless_shared_text/v1"
  @fields ~w(text_encoding text_table observation_table raw_record_sha256 raw_record_bytes)
  @maximum 8_388_608
  @minimum 128

  @spec encoding() :: String.t()
  def encoding, do: @encoding

  @spec maximum_expanded_bytes() :: pos_integer()
  def maximum_expanded_bytes, do: @maximum

  @spec compact(record :: map()) :: map()
  def compact(record) do
    bytes = Contract.encode!(record)

    if byte_size(bytes) <= @maximum and not Enum.any?(@fields, &Map.has_key?(record, &1)) do
      texts =
        record
        |> count(%{})
        |> Enum.filter(fn {text, occurrences} ->
          byte_size(text) >= @minimum and occurrences > 1
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      keys = texts |> Enum.with_index() |> Map.new(fn {text, index} -> {text, "t#{index}"} end)
      table = Map.new(keys, fn {text, key} -> {key, text} end)

      observations =
        record
        |> observations(%{})
        |> Enum.filter(fn {_digest, {_value, count}} -> count > 1 end)
        |> Enum.sort()

      observation_keys =
        observations
        |> Enum.with_index()
        |> Map.new(fn {{digest, _}, index} -> {digest, "o#{index}"} end)

      observation_table =
        Map.new(observations, fn {digest, {value, _count}} ->
          {observation_keys[digest], encode(value, keys, %{})}
        end)

      encoded =
        record
        |> encode(keys, observation_keys)
        |> Map.merge(%{
          "text_encoding" => @encoding,
          "text_table" => table,
          "observation_table" => observation_table,
          "raw_record_sha256" => Contract.digest(record),
          "raw_record_bytes" => byte_size(bytes)
        })

      if (texts != [] or observations != []) and
           byte_size(Contract.encode!(encoded)) < byte_size(bytes),
         do: encoded,
         else: record
    else
      record
    end
  end

  @spec expand(record :: map()) :: {:ok, map()} | {:error, atom()}
  def expand(
        %{
          "text_encoding" => @encoding,
          "text_table" => texts,
          "observation_table" => observations
        } = record
      )
      when is_map(texts) and is_map(observations) do
    table = %{texts: texts, observations: observations, observation_refs?: true}

    with size when is_integer(size) and size in 0..@maximum <- record["raw_record_bytes"],
         {:ok, original, ^size} <- decode(Map.drop(record, @fields), table),
         true <- Contract.digest(original) == record["raw_record_sha256"],
         true <- compact(original) == record do
      {:ok, original}
    else
      _invalid -> {:error, :invalid_shared_text}
    end
  end

  def expand(record) when is_map(record) do
    if Enum.any?(@fields, &Map.has_key?(record, &1)),
      do: {:error, :invalid_shared_text},
      else: {:ok, record}
  end

  def expand(_invalid), do: {:error, :invalid_shared_text}

  defp count(value, counts) when is_binary(value),
    do: Map.update(counts, value, 1, &(&1 + 1))

  defp count(value, counts) when is_map(value),
    do: Enum.reduce(value, counts, fn {_, item}, acc -> count(item, acc) end)

  defp count(value, counts) when is_list(value), do: Enum.reduce(value, counts, &count/2)
  defp count(_value, counts), do: counts

  defp observations(%{"transcript" => entries, "source_observation_sha256" => _} = value, counts)
       when is_list(entries) do
    Map.update(counts, Contract.digest(value), {value, 1}, fn {original, count} ->
      {original, count + 1}
    end)
  end

  defp observations(value, counts) when is_map(value),
    do: Enum.reduce(value, counts, fn {_, item}, acc -> observations(item, acc) end)

  defp observations(value, counts) when is_list(value),
    do: Enum.reduce(value, counts, &observations/2)

  defp observations(_value, counts), do: counts

  defp encode(value, keys, _observations) when is_binary(value) do
    case Map.fetch(keys, value) do
      {:ok, key} -> %{"$text" => key}
      :error -> value
    end
  end

  defp encode(
         %{"transcript" => entries, "source_observation_sha256" => _} = value,
         keys,
         observations
       )
       when is_list(entries) do
    case Map.fetch(observations, Contract.digest(value)) do
      {:ok, key} -> %{"$observation" => key}
      :error -> encode_object(value, keys, observations)
    end
  end

  defp encode(value, keys, observations) when is_map(value),
    do: encode_object(value, keys, observations)

  defp encode(value, keys, observations) when is_list(value),
    do: Enum.map(value, &encode(&1, keys, observations))

  defp encode(value, _keys, _observations), do: value

  defp encode_object(value, keys, observations) do
    pairs =
      value
      |> Enum.sort()
      |> Enum.map(fn {key, item} -> {key, encode(item, keys, observations)} end)

    if Enum.any?(~w($text $object $observation), &Map.has_key?(value, &1)),
      do: %{"$object" => Enum.map(pairs, fn {key, item} -> [key, item] end)},
      else: Map.new(pairs)
  end

  defp decode(%{"$text" => key} = value, table) when map_size(value) == 1 do
    with {:ok, text} when is_binary(text) <- Map.fetch(table.texts, key), do: sized(text)
  end

  defp decode(%{"$observation" => key} = value, %{observation_refs?: true} = table)
       when map_size(value) == 1 do
    with {:ok, observation} <- Map.fetch(table.observations, key) do
      decode(observation, %{table | observation_refs?: false})
    end
  end

  defp decode(%{"$observation" => _} = value, _table) when map_size(value) == 1,
    do: {:error, :invalid_shared_text}

  defp decode(%{"$object" => pairs} = value, table) when map_size(value) == 1 do
    with true <- is_list(pairs),
         true <- Enum.all?(pairs, &match?([key, _] when is_binary(key), &1)),
         tuples = Enum.map(pairs, fn [key, item] -> {key, item} end),
         true <- length(tuples) == MapSet.size(MapSet.new(tuples, &elem(&1, 0))) do
      decode_object(tuples, table)
    else
      _invalid -> {:error, :invalid_shared_text}
    end
  end

  defp decode(value, table) when is_map(value), do: decode_object(Map.to_list(value), table)

  defp decode(value, table) when is_list(value) do
    initial = {:ok, [], 2 + max(0, length(value) - 1)}

    case Enum.reduce_while(value, initial, &decode_list_item(&1, &2, table)) do
      {:ok, items, size} -> {:ok, Enum.reverse(items), size}
      error -> error
    end
  end

  defp decode(value, _table)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: sized(value)

  defp decode(_value, _table), do: {:error, :invalid_shared_text}

  defp decode_list_item(item, {:ok, items, size}, table) do
    with {:ok, decoded, bytes} <- decode(item, table),
         true <- size + bytes <= @maximum do
      {:cont, {:ok, [decoded | items], size + bytes}}
    else
      _invalid -> {:halt, {:error, :invalid_shared_text}}
    end
  end

  defp decode_object(pairs, table) do
    initial = {:ok, %{}, 2 + max(0, length(pairs) - 1)}

    Enum.reduce_while(pairs, initial, fn {key, item}, {:ok, values, size} ->
      with true <- is_binary(key),
           {:ok, decoded, bytes} <- decode(item, table),
           total = size + byte_size(JSON.encode!(key)) + 1 + bytes,
           true <- total <= @maximum do
        {:cont, {:ok, Map.put(values, key, decoded), total}}
      else
        _invalid -> {:halt, {:error, :invalid_shared_text}}
      end
    end)
  end

  defp sized(value) do
    size = byte_size(JSON.encode!(value))
    if size <= @maximum, do: {:ok, value, size}, else: {:error, :invalid_shared_text}
  end
end
