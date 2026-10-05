defmodule Invoice.ParserTest do
  use ExUnit.Case, async: true

  alias Invoice.Parser

  test "parses a single-word item" do
    assert Parser.parse_line("3 x widget @ 250") ==
             {:ok, %{quantity: 3, name: "widget", unit_cents: 250}}
  end

  test "parses item names that contain spaces" do
    assert Parser.parse_line("2 x blue widget @ 250") ==
             {:ok, %{quantity: 2, name: "blue widget", unit_cents: 250}}

    assert Parser.parse_line("1 x left handed smoke shifter @ 1999") ==
             {:ok, %{quantity: 1, name: "left handed smoke shifter", unit_cents: 1999}}
  end

  test "tolerates surrounding whitespace" do
    assert Parser.parse_line("  4 x gasket @ 5  ") ==
             {:ok, %{quantity: 4, name: "gasket", unit_cents: 5}}
  end

  test "rejects malformed lines" do
    assert Parser.parse_line("widget @ 250") == {:error, :invalid_line}
    assert Parser.parse_line("two x widget @ 250") == {:error, :invalid_line}
    assert Parser.parse_line("2 x widget @ cheap") == {:error, :invalid_line}
    assert Parser.parse_line("2 x @ 250") == {:error, :invalid_line}
  end

  test "parse reports the first invalid line number" do
    text = "1 x widget @ 100\n\n2 x blue widget @ 250\nbad line\n"
    assert Parser.parse(text) == {:error, {:invalid_line, 4}}
  end

  test "parse returns every line in order" do
    assert {:ok, [first, second]} = Parser.parse("1 x widget @ 100\n2 x blue widget @ 250\n")
    assert first.name == "widget"
    assert second.name == "blue widget"
  end
end
