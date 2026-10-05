defmodule Shop.Auth.Keys do
  @moduledoc "Signing key lookup by key id."

  def lookup(kid) do
    case :ets.lookup(:shop_keys, kid) do
      [{^kid, key}] -> {:ok, key}
      [] -> {:error, :unknown_key}
    end
  end
end
