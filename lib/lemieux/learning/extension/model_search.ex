defmodule Lemieux.Learning.Extension.ModelSearch do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  User-bounded provider, model and reasoning-effort comparisons.

  Discovery uses the actual host provider, including its scoped credentials and
  connection. ReqLLM's configured catalog is not an account entitlement check:
  a benchmark request remains the authority on access, compatibility and cost.
  Hosts with a connection-specific inventory can pass `:available_models` to
  narrow or replace the catalog. Never populate it with an unverified wish list.

  Selection performs no generation and retains no credentials. Explicit effort
  values must be supported by that model; `default` removes an explicit effort.
  Candidates are development variants, never an automatically promoted winner.
  """

  alias Lemieux.Contract
  alias Lemieux.Learning.Extension.Workbench
  alias Lemieux.Provider

  @doc "Returns configured models and their advertised efforts without making model calls."
  @spec inventory(provider :: Provider.t(), opts :: keyword()) :: [map()]
  def inventory(provider, opts \\ []) do
    models =
      Keyword.get_lazy(opts, :available_models, fn -> Provider.available_models(provider) end)

    models
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn model ->
      %{
        "model" => model,
        "efforts" => Enum.uniq(["default" | Provider.reasoning_efforts(provider, model)]),
        "availability" =>
          if(Keyword.has_key?(opts, :available_models),
            do: "host_inventory",
            else: "configured_catalog"
          )
      }
    end)
  end

  @doc "Validates at most 32 explicit model/effort candidates against the host connection."
  @spec select(provider :: Provider.t(), selections :: [map()], opts :: keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def select(provider, selections, opts \\ []) do
    if selections?(selections) do
      catalog = Map.new(inventory(provider, opts), &{&1["model"], &1})
      expand(provider, selections, catalog, Keyword.get(opts, :tools, []))
    else
      {:error, :invalid_model_selection}
    end
  end

  @doc "Atomically adds selected candidates to a workbench; leaves its run selection unchanged."
  @spec add(
          state :: Workbench.t(),
          base :: String.t(),
          provider :: Provider.t(),
          selections :: [map()],
          opts :: keyword()
        ) ::
          {:ok, Workbench.t(), [String.t()]} | {:error, term()}
  def add(state, base, provider, selections, opts \\ []) do
    with {:ok, candidates} <- select(provider, selections, opts),
         names = Enum.map(candidates, &name/1),
         variants =
           Map.new(Enum.zip(names, candidates), fn {name, candidate} ->
             {name,
              %{"base" => base, "overrides" => Map.take(candidate, ["model", "reasoning_effort"])}}
           end),
         {:ok, updated} <- add_new(state, variants) do
      {:ok, updated, names}
    end
  end

  defp add_new(state, variants) do
    fresh = Map.reject(variants, fn {name, value} -> state.project["variants"][name] == value end)
    if map_size(fresh) == 0, do: {:ok, state}, else: Workbench.add_variants(state, fresh)
  end

  defp selections?(items) when is_list(items) and length(items) in 1..32 do
    Enum.all?(items, fn
      %{"model" => model, "efforts" => efforts} = item
      when is_binary(model) and is_list(efforts) ->
        map_size(item) == 2 and length(efforts) in 1..32 and Enum.all?(efforts, &is_binary/1)

      _ ->
        false
    end) and Enum.reduce(items, 0, &(length(&1["efforts"]) + &2)) <= 32
  end

  defp selections?(_items), do: false

  defp expand(provider, selections, catalog, tools) do
    candidates = for item <- selections, effort <- item["efforts"], do: {item["model"], effort}

    if Enum.uniq(candidates) == candidates do
      collect(candidates, provider, catalog, tools)
    else
      {:error, :duplicate_candidates}
    end
  end

  defp collect(candidates, provider, catalog, tools) do
    Enum.reduce_while(candidates, {:ok, []}, fn {model, effort}, {:ok, acc} ->
      case candidate(provider, model, effort, catalog, tools) do
        {:ok, candidate} -> {:cont, {:ok, acc ++ [candidate]}}
        error -> {:halt, error}
      end
    end)
  end

  defp candidate(provider, model, effort, catalog, tools) do
    case Map.fetch(catalog, model) do
      :error -> {:error, {:model_not_available, model}}
      {:ok, entry} -> validate_candidate(provider, model, effort, entry, tools)
    end
  end

  defp validate_candidate(provider, model, effort, entry, tools) do
    cond do
      effort not in entry["efforts"] ->
        {:error, {:effort_not_available, model, effort}}

      Provider.validate_model(provider, model, tools) != :ok ->
        {:error, {:model_not_compatible, model}}

      true ->
        {:ok,
         %{
           "model" => model,
           "reasoning_effort" => effort,
           "availability" => entry["availability"]
         }}
    end
  end

  defp name(candidate) do
    digest = Contract.digest(Map.take(candidate, ["model", "reasoning_effort"]))
    "model-" <> String.slice(digest, 0, 16)
  end
end
