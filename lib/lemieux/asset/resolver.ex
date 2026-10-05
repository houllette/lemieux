defmodule Lemieux.Asset.Resolver do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Deterministic release-to-session asset layering with non-weakenable safety.

  Asset content remains ordered by layer so prompt/workflow consumers can
  decide how to compose their own types. Safety constraints are different:
  the first value established by a lower authority is invariant. A higher
  layer that proposes another value is retained as a conflict for explanation
  and cannot silently replace the invariant.
  """

  alias Lemieux.Asset.Version

  @layers [:release, :host, :tenant, :project, :session]

  @type resolved :: %{
          versions: [Version.t()],
          by_type: %{optional(Version.asset_type()) => [Version.t()]},
          safety: map(),
          conflicts: [map()],
          size_bytes: non_neg_integer(),
          token_count: non_neg_integer()
        }

  @doc "Resolves versions in authority order and enforces aggregate budgets."
  @spec resolve(versions :: [Version.t()], opts :: keyword()) ::
          {:ok, resolved()} | {:error, term()}
  def resolve(versions, opts \\ []) when is_list(versions) and is_list(opts) do
    ordered = Enum.sort_by(versions, &layer_index(&1.layer))
    size = Enum.sum(Enum.map(ordered, & &1.size_bytes))
    tokens = Enum.sum(Enum.map(ordered, & &1.token_count))

    with :ok <- unique_layer_types(ordered),
         :ok <- budget(size, Keyword.get(opts, :max_bytes), :size),
         :ok <- budget(tokens, Keyword.get(opts, :max_tokens), :token) do
      {safety, conflicts} = resolve_safety(ordered)

      {:ok,
       %{
         versions: ordered,
         by_type: Enum.group_by(ordered, & &1.type),
         safety: safety,
         conflicts: conflicts,
         size_bytes: size,
         token_count: tokens
       }}
    end
  end

  defp layer_index(layer), do: Enum.find_index(@layers, &(&1 == layer))

  defp unique_layer_types(versions) do
    keys = Enum.map(versions, &{&1.layer, &1.type})

    if length(keys) == MapSet.size(MapSet.new(keys)),
      do: :ok,
      else: {:error, :duplicate_asset_in_layer}
  end

  defp budget(_actual, nil, _kind), do: :ok
  defp budget(actual, maximum, _kind) when actual <= maximum, do: :ok
  defp budget(actual, maximum, :size), do: {:error, {:size_budget_exceeded, actual, maximum}}
  defp budget(actual, maximum, :token), do: {:error, {:token_budget_exceeded, actual, maximum}}

  defp resolve_safety(versions) do
    versions
    |> Enum.reduce({%{}, []}, fn version, {resolved, conflicts} ->
      Enum.reduce(version.safety, {resolved, conflicts}, &resolve_safety_value/2)
    end)
    |> then(fn {safety, conflicts} -> {safety, Enum.reverse(conflicts)} end)
  end

  defp resolve_safety_value({key, value}, {values, found}) do
    case Map.fetch(values, key) do
      :error -> {Map.put(values, key, value), found}
      {:ok, ^value} -> {values, found}
      {:ok, kept} -> {values, [%{key: key, kept: kept, rejected: value} | found]}
    end
  end
end
