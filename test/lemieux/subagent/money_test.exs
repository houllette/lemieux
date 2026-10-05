defmodule Lemieux.Subagent.MoneyTest do
  use ExUnit.Case, async: true

  alias Lemieux.Subagent.Money

  test "dollars round up to the micro, because a cap is a cap" do
    assert Money.to_micros(0.1) == 100_000
    assert Money.to_micros(0) == 0

    # A price finer than a micro-dollar rounds up rather than down: rounding
    # down would let a tree spend fractionally past its ceiling on every child.
    assert Money.to_micros(0.0000004) == 1
  end

  test "an unmeasured price is unknown, never zero" do
    assert Money.to_micros(nil) == :unknown
    assert Money.to_micros("0.10") == :unknown
    assert Money.to_micros(-1) == :unknown
    assert Money.to_usd(:unknown) == nil
  end

  test "integers add exactly where floats do not" do
    hundred = List.duplicate(Money.to_micros(0.1), 100)

    assert Money.sum(hundred) == 10_000_000
    assert Money.to_usd(Money.sum(hundred)) == 10.0

    # The same sum in floats does not land on ten, which is the whole reason
    # admission counts in integers.
    refute Enum.sum(List.duplicate(0.1, 100)) == 10.0
  end

  test "an unmeasured child consumes its whole reservation" do
    reserved = Money.to_micros(0.1)

    assert Money.charge(0.02, reserved) == 20_000
    assert Money.charge(nil, reserved) == reserved
    assert Money.charge("free", reserved) == reserved
  end

  test "a round trip through dollars is exact for anything a provider prices" do
    for usd <- [0.0, 0.000001, 0.02, 1.5, 137.25] do
      assert usd |> Money.to_micros() |> Money.to_usd() == usd
    end
  end
end
