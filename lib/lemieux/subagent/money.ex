defmodule Lemieux.Subagent.Money do
  @moduledoc """
  Dollars as integer micro-dollars, for the one place that has to add them up.

  Admission reserves against a tree budget, charges measured usage back, and
  reports what is left. Doing that in floats is a slow leak: `0.1 + 0.2` is
  not `0.3`, a reservation released is not exactly the reservation taken, and
  after a few hundred children the remaining budget is a number nobody can
  reconcile against a provider invoice. The errors are tiny and they are
  always in the same direction as whichever operation ran more often.

  A micro-dollar — one millionth of a dollar — is finer than any provider
  prices to, so rounding to it loses nothing real, and integers add exactly.
  Rounding is **up** at the boundary: a reservation that rounded down would
  let a tree spend fractionally more than its cap, and the cap is the point.

  Unknown stays unknown. A provider that reports no price has not reported
  zero, and `to_micros/1` answers `:unknown` for it rather than `0`; the
  caller decides what an unmeasured child costs, which for admission is its
  whole reservation rather than nothing.
  """

  @micros_per_dollar 1_000_000

  @typedoc "An exact amount in micro-dollars, or an amount nobody measured."
  @type micros :: non_neg_integer() | :unknown

  @doc """
  Converts dollars to micro-dollars, rounding up.

  Returns `:unknown` for anything that is not a non-negative number, which
  includes `nil` — the shape a provider that priced nothing reports.
  """
  @spec to_micros(usd :: term()) :: micros()
  def to_micros(usd) when is_number(usd) and usd >= 0,
    do: ceil(usd * @micros_per_dollar)

  def to_micros(_usd), do: :unknown

  @doc "Converts micro-dollars back to dollars for reporting."
  @spec to_usd(micros :: micros()) :: float() | nil
  def to_usd(micros) when is_integer(micros), do: micros / @micros_per_dollar
  def to_usd(_micros), do: nil

  @doc """
  What a finished child is charged against its root's budget.

  A measured cost is charged exactly; an unmeasured one consumes the whole
  reservation. Charging an unmeasured child nothing would make a tree of
  unpriced children free, which is how a budget stops bounding anything.
  """
  @spec charge(actual :: term(), reserved :: non_neg_integer()) :: non_neg_integer()
  def charge(actual, reserved) when is_integer(reserved) and reserved >= 0 do
    case to_micros(actual) do
      :unknown -> reserved
      micros -> micros
    end
  end

  @doc "Sums amounts exactly, treating an unknown as its own reservation."
  @spec sum(amounts :: [non_neg_integer()]) :: non_neg_integer()
  def sum(amounts) when is_list(amounts), do: Enum.sum(amounts)
end
