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

  test "chunked display strings preserve UTF-8 bytes and bound escaped line size" do
    for text <- [
          String.duplicate("x", 2100),
          String.duplicate("😀", 700),
          String.duplicate("\"\\\n\t\u0000", 500),
          "e" <> String.duplicate("\u0301", 2400)
        ] do
      value = %{"nested" => [%{"payload" => text, "count" => 7}], "short" => "unchanged"}
      encoded = Lemieux.JSON.encode_readable!(value, strings: :chunks)
      projected = JSON.decode!(encoded)
      assert projected["short"] == "unchanged"
      assert [%{"payload" => %{"$text" => view}, "count" => 7}] = projected["nested"]
      assert view["encoding"] == "utf8_chunks/v1"
      assert Enum.join(view["chunks"]) == text
      assert view["bytes"] == byte_size(text)
      assert view["sha256"] == Lemieux.Contract.sha256(text)
      assert length(view["chunks"]) > 1
      assert Enum.all?(view["chunks"], &String.valid?/1)
      assert Enum.all?(view["chunks"], &(byte_size(JSON.encode!(&1)) <= 512))
      assert Enum.all?(String.split(encoded, "\n"), &(byte_size(&1) < 2000))

      # Display projection never changes the default JSON document contract.
      assert value |> Lemieux.JSON.encode_readable!() |> JSON.decode!() == value
    end
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
