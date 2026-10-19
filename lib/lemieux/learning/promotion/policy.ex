defmodule Lemieux.Learning.Promotion.Policy do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Immutable bounds for a named host promotion actor. Integrity is not authority:
  callers obtain this policy anew from their host on every operation. A policy
  copied from a transcript, repository or proposal cannot authorize itself.
  """
  alias Lemieux.Contract
  @fields ~w(id actor scope capabilities trust maximum_bytes ttl_ms expires_at canary)
  @capabilities ~w(retain task_local canary)

  @doc "Freezes finite, explicit automatic-promotion bounds."
  @spec new(attrs :: map()) :: {:ok, map()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with true <- Enum.sort(Map.keys(attrs)) == Enum.sort(@fields),
         true <- text?(attrs["id"]) and text?(attrs["actor"]),
         %{"id" => scope} <- attrs["scope"],
         true <- text?(scope),
         caps when is_list(caps) and caps != [] <- attrs["capabilities"],
         true <- Enum.all?(caps, &(&1 in @capabilities)),
         true <- attrs["trust"] in ~w(personal repository),
         true <- attrs["maximum_bytes"] in 1..16_384,
         true <- attrs["ttl_ms"] in 1..86_400_000,
         {:ok, _, 0} <- DateTime.from_iso8601(attrs["expires_at"]),
         %{"percent" => percent, "salt" => salt, "minimum_observations" => minimum} <-
           attrs["canary"],
         true <- percent in 1..100 and minimum in 1..32 and text?(salt) do
      {:ok, seal(Map.put(attrs, "schema_version", 1))}
    else
      _invalid -> {:error, :invalid_promotion_policy}
    end
  rescue
    _invalid -> {:error, :invalid_promotion_policy}
  end

  def new(_invalid), do: {:error, :invalid_promotion_policy}

  @doc "Checks policy bytes; this does not grant permission."
  @spec verify(policy :: map()) :: :ok | {:error, term()}
  def verify(%{"schema_version" => 1} = policy) do
    with :ok <- Contract.verify_digest(policy, "sha256"),
         {:ok, ^policy} <- new(Map.drop(policy, ~w(schema_version sha256))),
         do: :ok
  end

  def verify(_invalid), do: {:error, :invalid_promotion_policy}

  @doc "Checks fresh host authority, scope, expiry and a declared capability."
  @spec authorize(context :: map(), capability :: String.t()) :: :ok | {:error, term()}
  def authorize(context, capability) do
    with :ok <- verify(context.policy),
         true <- context[:revoked] != true,
         true <- context.scope == context.policy["scope"],
         true <- capability in context.policy["capabilities"],
         {:ok, expires, 0} <- DateTime.from_iso8601(context.policy["expires_at"]),
         true <- DateTime.compare(context.now, expires) == :lt do
      :ok
    else
      _refused -> {:error, :promotion_not_authorized}
    end
  rescue
    _invalid -> {:error, :promotion_not_authorized}
  end

  @doc "The named actor recorded by ordinary asset approval."
  @spec actor(policy :: map()) :: map()
  def actor(policy),
    do: %{
      "type" => "policy",
      "id" => policy["actor"],
      "policy_id" => policy["id"],
      "policy_sha256" => policy["sha256"]
    }

  defp text?(value),
    do: is_binary(value) and byte_size(value) in 1..256 and String.trim(value) != ""

  defp seal(map), do: Map.put(map, "sha256", Contract.digest(map))
end
