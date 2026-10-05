defmodule Lemieux.Harness.Safe do
  @moduledoc false

  alias Lemieux.Contract

  @unsafe_keys MapSet.new(~w(api_key api_keys authorization credential credentials cookie cookies
                    base_url endpoint headers http_options password proxy secret token
                    transport transport_options))

  @doc "Returns string-keyed request parameters with unsafe transport material omitted."
  @spec request_params(params :: map() | keyword()) :: map()
  def request_params(params) when is_list(params), do: params |> Map.new() |> request_params()

  def request_params(params) when is_map(params) do
    params
    |> Enum.reject(fn {key, _value} -> unsafe_key?(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), safe_json(value)} end)
  end

  @doc "Returns true when a key names credential or transport configuration."
  @spec unsafe_key?(key :: atom() | String.t()) :: boolean()
  def unsafe_key?(key) do
    normalized =
      key
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    MapSet.member?(@unsafe_keys, normalized) or credential_key?(normalized)
  end

  defp credential_key?(key) do
    String.contains?(key, ["authorization", "credential", "password", "secret", "cookie"]) or
      String.ends_with?(key, ["_api_key", "_access_key", "_private_key", "_token"]) or
      String.starts_with?(key, ["api_key_", "access_key_", "private_key_", "token_"])
  end

  defp safe_json(value) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> unsafe_key?(key) end)
    |> Map.new(fn {key, item} -> {to_string(key), safe_json(item)} end)
  end

  defp safe_json(value) when is_list(value), do: Enum.map(value, &safe_json/1)
  defp safe_json(value), do: Contract.json(value)
end
