defmodule LemieuxSystemOneCompaction.Evaluation do
  @moduledoc """
  Offline threshold sweeps and explicit route-cost arithmetic for scorer trials.

  A sweep reuses bounded score observations; it never asks the scorer again. A
  `must_keep` label is an evaluator's proxy for risky elision, not a substitute
  for a paired model continuation and mechanical task grader. Price comparisons
  account for cache reads, cache writes, SDK calls and every supplied future
  turn. Missing usage and ambiguous cache conventions remain errors rather than
  becoming zero-cost requests.

  Tariffs are host inputs. The band covering the *full* input token count sets
  all rates for that request, as with whole-request long-context pricing. These
  calculations are estimates; provider-reported charges and actual invoices
  remain separate evidence.
  """

  @typedoc "String-keyed usage or price data, suitable for JSON reports."
  @type data :: map()

  @doc "Sweeps keep-probability thresholds without repeating SDK calls."
  @spec sweep(evaluations :: [data()], thresholds :: [number()], opts :: keyword()) ::
          {:ok, [data()]} | {:error, atom()}
  def sweep(evaluations, thresholds, opts \\ [])

  def sweep(evaluations, thresholds, opts)
      when is_list(evaluations) and is_list(thresholds) and is_list(opts) do
    minimum = Keyword.get(opts, :min_saved_tokens, 1)

    with :ok <- validate_thresholds(thresholds),
         :ok <- validate_minimum(minimum),
         {:ok, groups} <- validate_evaluations(evaluations) do
      {:ok, Enum.map(thresholds, &sweep_threshold(groups, &1, minimum))}
    end
  end

  def sweep(_evaluations, _thresholds, _opts), do: {:error, :invalid_sweep}

  @doc "Prices one complete request using a host-supplied ordered tariff."
  @spec price(usage :: data(), tiers :: [data()]) :: {:ok, data()} | {:error, atom()}
  def price(usage, tiers) when is_map(usage) and is_list(tiers) do
    with {:ok, counts} <- usage_counts(usage),
         {:ok, tier} <- tier_for(counts.full, tiers) do
      input_rate = tier["input_per_million"]
      read_rate = Map.get(tier, "cached_input_per_million", input_rate)
      write_rate = Map.get(tier, "cache_write_per_million", input_rate)

      cost =
        (counts.uncached * input_rate + counts.read * read_rate +
           counts.write * write_rate + counts.output * tier["output_per_million"]) / 1_000_000

      {:ok,
       %{
         "full_input_tokens" => counts.full,
         "uncached_input_tokens" => counts.uncached,
         "cache_read_tokens" => counts.read,
         "cache_write_tokens" => counts.write,
         "tier_up_to" => tier["up_to"],
         "cost_usd" => cost
       }}
    end
  end

  def price(_usage, _tiers), do: {:error, :invalid_price_input}

  @doc "Compares provider requests and all scorer calls over paired trial horizons."
  @spec compare(
          baseline :: [data()],
          projected :: [data()],
          sdk :: [data()],
          provider_tiers :: [data()],
          sdk_rates :: data()
        ) :: {:ok, data()} | {:error, atom()}
  def compare(baseline, projected, sdk, provider_tiers, sdk_rates)
      when is_list(baseline) and is_list(projected) and is_list(sdk) and
             is_list(provider_tiers) and is_map(sdk_rates) do
    sdk_tiers = [Map.put(sdk_rates, "up_to", nil)]

    with true <- baseline != [] and projected != [],
         {:ok, baseline_cost} <- price_all(baseline, provider_tiers),
         {:ok, projected_cost} <- price_all(projected, provider_tiers),
         {:ok, sdk_cost} <- price_all(sdk, sdk_tiers) do
      {:ok,
       %{
         "baseline_requests" => length(baseline),
         "projected_requests" => length(projected),
         "baseline_cost_usd" => baseline_cost,
         "projected_provider_cost_usd" => projected_cost,
         "sdk_cost_usd" => sdk_cost,
         "net_savings_usd" => baseline_cost - projected_cost - sdk_cost
       }}
    else
      false -> {:error, :unpaired_horizon}
      {:error, _reason} = error -> error
    end
  end

  def compare(_baseline, _projected, _sdk, _provider_tiers, _sdk_rates),
    do: {:error, :invalid_comparison}

  defp validate_thresholds([]), do: {:error, :invalid_thresholds}

  defp validate_thresholds(thresholds) do
    if Enum.all?(thresholds, &(is_number(&1) and &1 >= 0 and &1 <= 1)),
      do: :ok,
      else: {:error, :invalid_thresholds}
  end

  defp validate_minimum(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_minimum(_value), do: {:error, :invalid_minimum}

  defp validate_evaluations(evaluations) do
    Enum.reduce_while(evaluations, {:ok, []}, fn evaluation, {:ok, groups} ->
      case validate_candidates(evaluation) do
        {:ok, candidates} -> {:cont, {:ok, [candidates | groups]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, Enum.reverse(groups)}
      error -> error
    end
  end

  defp validate_candidates(%{"candidates" => candidates}) when is_list(candidates) do
    if Enum.all?(candidates, &valid_candidate?/1),
      do: {:ok, candidates},
      else: {:error, :invalid_candidate}
  end

  defp validate_candidates(_evaluation), do: {:error, :invalid_evaluation}

  defp valid_candidate?(candidate) when is_map(candidate) do
    probability = candidate["keep_probability"]
    saved = candidate["estimated_saved_tokens"]

    is_number(probability) and probability >= 0 and probability <= 1 and
      is_integer(saved) and saved >= 0 and candidate["must_keep"] in [nil, true, false]
  end

  defp valid_candidate?(_candidate), do: false

  defp sweep_threshold(groups, threshold, minimum) do
    totals =
      Enum.reduce(groups, %{selected: 0, false_elisions: 0, unknown: 0, saved: 0}, fn group,
                                                                                      totals ->
        selected = Enum.filter(group, &(&1["keep_probability"] < threshold))
        saved = Enum.sum(Enum.map(selected, & &1["estimated_saved_tokens"]))
        selected = if saved >= minimum, do: selected, else: []

        %{
          selected: totals.selected + length(selected),
          false_elisions:
            totals.false_elisions + Enum.count(selected, &(&1["must_keep"] == true)),
          unknown: totals.unknown + Enum.count(selected, &is_nil(&1["must_keep"])),
          saved: totals.saved + if(selected == [], do: 0, else: saved)
        }
      end)

    %{
      "threshold" => threshold,
      "selected" => totals.selected,
      "false_elisions" => totals.false_elisions,
      "unknown_labels" => totals.unknown,
      "estimated_saved_tokens" => totals.saved
    }
  end

  defp usage_counts(usage) do
    input = usage["input_tokens"]
    output = usage["output_tokens"]
    read = Map.get(usage, "cache_read_tokens", 0)
    write = Map.get(usage, "cache_write_tokens", 0)
    includes = usage["input_includes_cached"]

    cond do
      not Enum.all?([input, output, read, write], &non_negative_number?/1) ->
        {:error, :incomplete_usage}

      read + write > 0 and includes not in [true, false, "true", "false"] ->
        {:error, :ambiguous_cache_usage}

      includes in [true, "true"] and read + write > input ->
        {:error, :invalid_cache_usage}

      includes in [true, "true"] ->
        {:ok,
         %{full: input, uncached: input - read - write, read: read, write: write, output: output}}

      true ->
        {:ok,
         %{
           full: input + read + write,
           uncached: input,
           read: read,
           write: write,
           output: output
         }}
    end
  end

  defp tier_for(full_input, tiers) do
    with :ok <- validate_tiers(tiers),
         %{} = tier <- Enum.find(tiers, &(&1["up_to"] == nil or full_input <= &1["up_to"])) do
      {:ok, tier}
    else
      nil -> {:error, :missing_price_tier}
      {:error, _reason} = error -> error
    end
  end

  defp validate_tiers([]), do: {:error, :invalid_price_tiers}

  defp validate_tiers(tiers) do
    valid? =
      Enum.reduce_while(tiers, -1, fn tier, previous ->
        validate_tier(tier, previous)
      end)

    if valid? == false, do: {:error, :invalid_price_tiers}, else: :ok
  end

  defp validate_tier(tier, previous) when is_map(tier) and previous != :infinity do
    up_to = tier["up_to"]

    rates =
      ~w(input_per_million output_per_million cached_input_per_million cache_write_per_million)

    valid_rates? =
      Enum.all?(rates, fn key ->
        not Map.has_key?(tier, key) or non_negative_number?(tier[key])
      end)

    required? = Enum.all?(~w(input_per_million output_per_million), &Map.has_key?(tier, &1))

    cond do
      not valid_rates? or not required? -> {:halt, false}
      is_integer(up_to) and up_to > previous -> {:cont, up_to}
      is_nil(up_to) -> {:cont, :infinity}
      true -> {:halt, false}
    end
  end

  defp validate_tier(_tier, _previous), do: {:halt, false}

  defp non_negative_number?(value), do: is_number(value) and value >= 0

  defp price_all(usages, tiers) do
    Enum.reduce_while(usages, {:ok, 0.0}, fn usage, {:ok, total} ->
      case price(usage, tiers) do
        {:ok, %{"cost_usd" => cost}} -> {:cont, {:ok, total + cost}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end
end
