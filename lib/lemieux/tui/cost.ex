defmodule Lemieux.TUI.Cost do
  @moduledoc "Compact display-only USD totals. Accounting keeps its original precision."

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Estimate

  @doc "Formats the session total, preserving incomplete and estimated accounting."
  @spec format(conversation :: Conversation.t()) :: String.t()
  def format(%Conversation{estimated_usd: {_amount, _scale}} = conversation) do
    if conversation.estimate_unknown_reasons == [] and
         conversation.estimated_requests >= conversation.unmeasured_requests do
      measured = decimal(conversation.measured_spent_usd)
      total = Estimate.add(conversation.estimated_usd, measured)
      "cost: ~" <> money(total)
    else
      "cost: unknown"
    end
  end

  def format(%Conversation{estimate_unknown_reasons: [_ | _]}), do: "cost: unknown"

  def format(%Conversation{spent_usd: amount, cost_bases: bases}) when is_number(amount) do
    marker = if "api_equivalent" in bases, do: "~", else: ""
    "cost: " <> marker <> money(amount)
  end

  def format(%Conversation{}), do: "cost: unknown"

  defp money({amount, scale}) do
    divisor = Integer.pow(10, scale)
    cents = div(amount * 100 + divisor - 1, divisor)
    dollars(cents)
  end

  # Multiply the shortest decimal representation as integers. Multiplying a
  # float first makes an exact $0.07 look like a fractional cent; rounding
  # with an epsilon instead discards sufficiently small real fractions.
  defp money(amount), do: amount |> decimal() |> money()

  defp decimal(amount) when is_integer(amount), do: {amount, 0}

  defp decimal(amount) do
    {mantissa, exponent} =
      case String.split(Float.to_string(amount), "e") do
        [mantissa] -> {mantissa, 0}
        [mantissa, exponent] -> {mantissa, String.to_integer(exponent)}
      end

    {:ok, {digits, scale}} = Estimate.parse(mantissa)

    if scale >= exponent,
      do: {digits, scale - exponent},
      else: {digits * Integer.pow(10, exponent - scale), 0}
  end

  defp dollars(cents),
    do: "$#{div(cents, 100)}." <> String.pad_leading(Integer.to_string(rem(cents, 100)), 2, "0")
end
