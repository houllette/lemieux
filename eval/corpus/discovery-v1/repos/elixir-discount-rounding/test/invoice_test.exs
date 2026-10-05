defmodule InvoiceTest do
  use ExUnit.Case, async: true

  test "subtotal multiplies quantity by unit price" do
    lines = [%{quantity: 2, unit_cents: 500}, %{quantity: 1, unit_cents: 250}]
    assert Invoice.subtotal(lines) == 1250
  end

  test "whole-cent discounts are exact" do
    assert Invoice.discount(1000, 5) == 50
    assert Invoice.discount(2000, 0) == 0
    assert Invoice.discount(2000, 100) == 2000
  end

  test "half cents round up" do
    assert Invoice.discount(1250, 15) == 188
    assert Invoice.discount(1, 50) == 1
  end

  test "fractions above a half round up and below round down" do
    assert Invoice.discount(999, 10) == 100
    assert Invoice.discount(333, 10) == 33
  end

  test "total subtracts the rounded discount" do
    assert Invoice.total(1250, 15) == 1062
  end
end
