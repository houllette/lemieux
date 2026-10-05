defmodule Lemieux.Compaction.Price do
  @moduledoc """
  A host-supplied price curve for compaction before a whole-request price cliff.

  Some models charge a higher rate for *all* input and output once a request
  crosses a threshold. Lemieux cannot infer a host route's tariff from a model
  name, and prices change, so the host supplies bands keyed by resolved model.
  Each band has `:up_to` (or `nil` for infinity), `:input_per_million`, and
  `:output_per_million`. Optional `:cached_input_per_million` prices cache
  reads. Only a projected move into a cheaper band with positive net savings
  can trigger; unknown prices never count as free.

  Keep catalog lookup outside this pure decision module. If LLMDB publishes
  complete conditional tariffs, the ReqLLM provider or host should translate
  the resolved route's full-request rates into these bands before calling it.
  A model's flat base `cost` cannot establish a price cliff, and a direct
  provider tariff cannot establish what a gateway charges.

  The forecast is a decision aid, not billing. The provider's actual usage and
  cost remain the accounting authority after both requests complete.
  """

  @type band :: %{
          required(:up_to) => pos_integer() | nil,
          required(:input_per_million) => number(),
          required(:output_per_million) => number(),
          optional(:cached_input_per_million) => number()
        }

  @doc "Returns a positive savings projection when compaction crosses a price band."
  @spec evaluate(pos_integer(), pos_integer(), pos_integer(), pos_integer(), map(), keyword()) ::
          {:compact, map()} | :continue
  def evaluate(before, after_tokens, summary_input, summary_output, prices, opts \\ []) do
    model = Keyword.fetch!(opts, :model)
    summary_model = Keyword.get(opts, :summary_model, model)
    output = Keyword.get(opts, :expected_output_tokens, 0)
    cached = Keyword.get(opts, :cached_input_tokens, 0)
    minimum = Keyword.get(opts, :minimum_savings_usd, 0.0)

    with {:ok, before_band} <- band(prices, model, before),
         {:ok, after_band} <- band(prices, model, after_tokens),
         {:ok, summary_band} <- band(prices, summary_model, summary_input),
         true <- before_band.up_to != after_band.up_to,
         true <- after_tokens < before,
         before_cost <- cost(before_band, before, min(cached, before), output),
         after_cost <- cost(after_band, after_tokens, 0, output),
         summary_cost <- cost(summary_band, summary_input, 0, summary_output),
         savings <- before_cost - after_cost - summary_cost,
         true <- savings > minimum do
      {:compact,
       %{
         before_input_tokens: before,
         after_input_tokens: after_tokens,
         summary_input_tokens: summary_input,
         summary_output_tokens: summary_output,
         projected_savings_usd: savings,
         projected_summary_cost_usd: summary_cost
       }}
    else
      _other -> :continue
    end
  end

  defp band(prices, model, tokens) do
    selected = prices |> Map.get(model, []) |> Enum.find(&eligible_band?(&1, tokens))
    if valid_band?(selected), do: {:ok, selected}, else: :unknown
  end

  defp eligible_band?(%{up_to: nil}, _tokens), do: true

  defp eligible_band?(%{up_to: limit}, tokens) when is_integer(limit) and limit > 0,
    do: tokens <= limit

  defp eligible_band?(_invalid, _tokens), do: false

  defp valid_band?(%{input_per_million: input, output_per_million: output} = band) do
    valid_rate?(input) and valid_rate?(output) and
      valid_rate?(Map.get(band, :cached_input_per_million, input))
  end

  defp valid_band?(_invalid), do: false
  defp valid_rate?(rate), do: is_number(rate) and rate >= 0

  defp cost(band, input, cached, output) do
    cached_rate = Map.get(band, :cached_input_per_million, band.input_per_million)

    ((input - cached) * band.input_per_million + cached * cached_rate +
       output * band.output_per_million) / 1_000_000
  end
end
