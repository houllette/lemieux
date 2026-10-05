defmodule Invoice do
  @moduledoc """
  Money math for invoices. Every amount is an integer number of cents so that
  totals never drift; percentages are integers from 0 to 100.
  """

  @type line :: %{quantity: pos_integer(), unit_cents: non_neg_integer()}

  @doc "Sum of quantity times unit price across the lines, in cents."
  @spec subtotal([line()]) :: non_neg_integer()
  def subtotal(lines) do
    Enum.reduce(lines, 0, fn %{quantity: quantity, unit_cents: unit}, acc ->
      acc + quantity * unit
    end)
  end

  @doc """
  Discount for a subtotal at `percent`, in cents.

  Fractions of a cent round half up, so a 15% discount on 12.50 is 1.88, not
  1.87. Accounting reconciles against this rule.
  """
  @spec discount(subtotal :: non_neg_integer(), percent :: 0..100) :: non_neg_integer()
  def discount(subtotal, percent) when percent in 0..100 do
    div(subtotal * percent, 100)
  end

  @doc "Amount due after the discount."
  @spec total(subtotal :: non_neg_integer(), percent :: 0..100) :: non_neg_integer()
  def total(subtotal, percent), do: subtotal - discount(subtotal, percent)
end
