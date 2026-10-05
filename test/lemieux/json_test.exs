defmodule Lemieux.JSONTest do
  use ExUnit.Case, async: true

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
