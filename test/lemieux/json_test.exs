defmodule Lemieux.JSONTest do
  use ExUnit.Case, async: true

  test "readable JSON preserves values, escapes and canonical identity" do
    value = %{
      "nested" => [%{}, [], nil, true, false, 12, -1.25],
      "text" => "a quote: \"; a slash: \\; braces: {},[]; a newline:\n日本語"
    }

    readable = Lemieux.JSON.encode_readable!(value)
    assert readable =~ "\n"
    assert JSON.decode!(readable) == value
    assert Lemieux.Contract.digest(JSON.decode!(readable)) == Lemieux.Contract.digest(value)
    assert readable == Lemieux.JSON.encode_readable!(Map.new(Enum.reverse(Enum.to_list(value))))
  end

  # The wording must stay identical to what `JSON.decode!/1` raises, so a
  # person sees the same sentence whether a reader took the raising path or
  # kept the error tuple.
  test "describes each reachable decode error the way JSON.decode!/1 words it" do
    for bad <- ["{", "!", <<?", 0xFF, ?">>] do
      {:error, reason} = JSON.decode(bad)
      raised = assert_raise(JSON.DecodeError, fn -> JSON.decode!(bad) end)

      assert Lemieux.JSON.describe_error(reason) == raised.message
    end
  end

  test "describes an unexpected sequence and falls back to inspect elsewhere" do
    assert Lemieux.JSON.describe_error({:unexpected_sequence, 3, <<0xED, 0xA0>>}) ==
             "unexpected sequence #{inspect(<<0xED, 0xA0>>)} at position (byte offset) 3"

    assert Lemieux.JSON.describe_error(:something_else) == ":something_else"
  end
end
