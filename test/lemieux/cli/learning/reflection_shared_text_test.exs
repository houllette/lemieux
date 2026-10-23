defmodule Lemieux.CLI.Learning.Reflection.SharedTextTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Learning.Reflection.SharedText
  alias Lemieux.Contract

  test "sharing preserves every occurrence, unique value and reserved-looking object" do
    first = String.duplicate("alpha λ\n", 50)
    second = String.duplicate("beta \"quoted\"\\\n", 50)

    record = %{
      "original" => %{
        "transcript" => [second, first, second, first],
        "literal" => %{"$text" => "t0"},
        "nested" => %{"$object" => [["key", 3]]},
        "λ/key~\"" => "This unique occurrence must survive."
      }
    }

    encoded = SharedText.compact(record)
    assert encoded["text_table"] == %{"t0" => first, "t1" => second}

    assert encoded["original"]["transcript"] ==
             Enum.map(~w(t1 t0 t1 t0), &%{"$text" => &1})

    assert encoded["raw_record_sha256"] == Contract.digest(record)
    assert {:ok, ^record} = SharedText.expand(encoded)
    assert SharedText.compact(encoded) == encoded
  end

  test "altered text, missing references, unused injected text and mismatched source refuse" do
    text = String.duplicate("source bytes ", 100)
    encoded = SharedText.compact(%{"original" => [text, text, text]})

    invalid = [
      put_in(encoded, ["text_table", "t0"], text <> "altered"),
      put_in(encoded, ["original"], [%{"$text" => "missing"}]),
      put_in(encoded, ["text_table", "unused"], "unbound instructions"),
      Map.put(encoded, "raw_record_bytes", 0),
      Map.put(encoded, "raw_record_sha256", Contract.sha256("forged")),
      Map.put(encoded, "text_encoding", "unknown/v1")
    ]

    for record <- invalid, do: assert({:error, :invalid_shared_text} == SharedText.expand(record))
  end

  test "a compact representation cannot authorize expansion beyond the separate bound" do
    text = String.duplicate("x", 4096)
    repetitions = div(SharedText.maximum_expanded_bytes(), byte_size(text)) + 1
    original = %{"original" => List.duplicate(text, repetitions)}

    encoded = %{
      "text_encoding" => SharedText.encoding(),
      "text_table" => %{"t0" => text},
      "observation_table" => %{},
      "original" => List.duplicate(%{"$text" => "t0"}, repetitions),
      "raw_record_sha256" => Contract.digest(original),
      "raw_record_bytes" => byte_size(Contract.encode!(original))
    }

    assert byte_size(Contract.encode!(encoded)) < Reflection.source_limit()
    assert encoded["raw_record_bytes"] > SharedText.maximum_expanded_bytes()
    assert {:error, :invalid_shared_text} = SharedText.expand(encoded)
  end

  test "shared observations preserve every position and expose real citation pointers" do
    observation = %{
      "source_observation_sha256" => Contract.sha256("source"),
      "transcript" => [
        %{
          "id" => "entry",
          "type" => "tool_result",
          "seq" => 42,
          "payload" => %{"output" => String.duplicate("complete", 100)}
        }
      ],
      "literal" => %{"$observation" => "o0"}
    }

    record = %{
      "original" => observation,
      "selected" => observation,
      "probes" => [%{"observation" => observation}]
    }

    encoded = SharedText.compact(record)
    assert encoded["original"] == %{"$observation" => "o0"}
    assert encoded["selected"] == encoded["original"]
    assert {:ok, ^record} = SharedText.expand(encoded)

    assert Enum.any?(
             Reflection.citation_index(encoded),
             &(&1["pointer"] == "/observation_table/o0/transcript/0")
           )

    cyclic = put_in(encoded, ["observation_table", "o0"], %{"$observation" => "o0"})
    assert {:error, :invalid_shared_text} = SharedText.expand(cyclic)
    unused = put_in(encoded, ["observation_table", "unused"], encoded["observation_table"]["o0"])
    assert {:error, :invalid_shared_text} = SharedText.expand(unused)
  end
end
