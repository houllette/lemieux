defmodule Lemieux.Contract do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Canonical JSON and integrity helpers for harness-learning contracts.

  Cross-system objects are JSON-shaped maps whose digests are calculated from
  the standard library encoder. Elixir's encoder orders object keys, so the
  same semantic map has the same bytes regardless of insertion order. Keeping
  this rule in one module prevents each contract from inventing subtly
  different exclusions or hexadecimal casing.

  The label covers calling this module directly. Supported modules that
  digest through it, such as `Lemieux.Extension.Profile`, are not
  experimental themselves.
  """

  @doc "Returns a lowercase SHA-256 digest for bytes."
  @spec sha256(bytes :: iodata()) :: String.t()
  def sha256(bytes) do
    :sha256
    |> :crypto.hash(IO.iodata_to_binary(bytes))
    |> Base.encode16(case: :lower)
  end

  @doc "Returns the canonical digest of a JSON-shaped map after dropping keys."
  @spec digest(map :: map(), excluded_keys :: [String.t()]) :: String.t()
  def digest(map, excluded_keys \\ []) when is_map(map) and is_list(excluded_keys) do
    map
    |> Map.drop(excluded_keys)
    |> JSON.encode!()
    |> sha256()
  end

  @doc "Encodes a JSON-shaped map using the canonical encoder."
  @spec encode!(map :: map()) :: String.t()
  def encode!(map) when is_map(map), do: JSON.encode!(map)

  @doc "Decodes a JSON object without creating atoms from external keys."
  @spec decode(binary :: String.t()) :: {:ok, map()} | {:error, term()}
  def decode(binary) when is_binary(binary) do
    case JSON.decode(binary) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _other} -> {:error, :expected_json_object}
      {:error, reason} -> {:error, {:invalid_json, Lemieux.JSON.describe_error(reason)}}
    end
  end

  @doc "Checks a schema version without guessing how an unknown object works."
  @spec verify_version(map :: map(), key :: String.t(), expected :: pos_integer()) ::
          :ok | {:error, term()}
  def verify_version(map, key, expected)
      when is_map(map) and is_binary(key) and is_integer(expected) and expected > 0 do
    case Map.fetch(map, key) do
      {:ok, ^expected} -> :ok
      {:ok, version} -> {:error, {:unsupported_version, version}}
      :error -> {:error, :missing_schema_version}
    end
  end

  @doc "Checks a digest field over every other field except explicit exclusions."
  @spec verify_digest(map :: map(), digest_key :: String.t(), excluded_keys :: [String.t()]) ::
          :ok | {:error, :missing_digest | :digest_mismatch}
  def verify_digest(map, digest_key, excluded_keys \\ [])
      when is_map(map) and is_binary(digest_key) and is_list(excluded_keys) do
    case Map.get(map, digest_key) do
      expected when is_binary(expected) and byte_size(expected) == 64 ->
        actual = digest(map, Enum.uniq([digest_key | excluded_keys]))
        if secure_equal?(actual, expected), do: :ok, else: {:error, :digest_mismatch}

      _missing ->
        {:error, :missing_digest}
    end
  end

  @doc "Converts supported Elixir values to a string-keyed JSON shape."
  @spec json(value :: term()) :: term()
  def json(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
      do: value

  def json(value) when is_atom(value), do: Atom.to_string(value)

  def json(%_struct{} = value), do: value |> Map.from_struct() |> json()

  def json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  def json(value) when is_list(value), do: Enum.map(value, &json/1)
  def json(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json/1)
  def json(_value), do: "[not serializable]"

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
