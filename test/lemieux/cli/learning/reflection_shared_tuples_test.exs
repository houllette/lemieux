defmodule Lemieux.CLI.Learning.ReflectionSharedTuplesTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Learning.Reflection.SharedText
  alias Lemieux.CLI.Learning.Reflection.SharedTuples
  alias Lemieux.CLI.Learning.Reflection.SharedValues
  alias Lemieux.Contract

  # The corruption cases all start from the same immutable wire record. Build
  # it once: repeatedly compacting its 15,600 source lines tests no additional
  # behavior and used to dominate those otherwise small validation cases.
  setup_all do
    original = record()
    %{original: original, encoded: SharedTuples.compact(original)}
  end

  test "a source at the exact expanded limit is not rejected for its intermediate envelope" do
    output = for n <- 1..8000, into: "", do: "#{n}\t" <> String.duplicate("a", 1000) <> " λ\n"
    base = %{"original" => %{"output" => output, "padding" => ""}}
    padding = SharedTuples.maximum_expanded_bytes() - byte_size(Contract.encode!(base))
    original = put_in(base, ["original", "padding"], String.duplicate("p", padding))
    assert byte_size(Contract.encode!(original)) == SharedTuples.maximum_expanded_bytes()
    encoded = SharedTuples.compact(original)
    assert byte_size(Contract.encode!(encoded)) < Reflection.source_limit()
    assert {:ok, ^original} = SharedTuples.expand(encoded)
  end

  test "numbered outputs preserve every original byte and position within the existing wire bound",
       %{original: original, encoded: encoded} do
    assert byte_size(Contract.encode!(SharedValues.compact(original))) > Reflection.source_limit()
    assert encoded["text_encoding"] == SharedTuples.encoding()
    assert byte_size(Contract.encode!(encoded)) < Reflection.source_limit()
    assert {:ok, ^original} = SharedTuples.expand(encoded)
    assert encoded["line_table"] != []
    assert encoded["raw_record_sha256"] == Contract.digest(original)

    index = SharedTuples.citation_index(encoded)
    assert Enum.any?(index, &(&1["entry_id"] == "entry-240"))
    assert Enum.any?(index, &(&1["type"] == "shared_text"))

    for item <- index do
      value =
        item["pointer"]
        |> String.trim_leading("/")
        |> String.split("/")
        |> Enum.reduce(encoded, fn key, value ->
          key = key |> String.replace("~1", "/") |> String.replace("~0", "~")

          if is_list(value),
            do: Enum.fetch!(value, String.to_integer(key)),
            else: Map.fetch!(value, key)
        end)

      assert is_list(value) or is_map(value) or is_binary(value)
    end
  end

  test "legacy encodings retain their original canonical readers", %{original: record} do
    text = String.duplicate("complete original λ observation\n", 50)
    original = %{"original" => %{"a" => text, "b" => text}}
    legacy = SharedText.compact(original)
    assert {:ok, ^original} = SharedTuples.expand(legacy)
    assert SharedText.compact(original) == legacy
    v2 = SharedValues.compact(record)
    assert v2["text_encoding"] == "lossless_shared_values/v2"
    assert {:ok, expanded} = SharedTuples.expand(v2)
    assert expanded == record
  end

  test "literal tags, reserved objects, line prefixes and Unicode are not interpreted as references",
       %{original: record} do
    literal = %{
      "tags" => Enum.map(-9..-1, &[&1, ["literal", 42]]),
      "object" => %{"$text" => "t0", "$row" => ["s0", "literal"]},
      "lines" => "01\tleading zero\n1\tλ\r\n0\tzero\n-1\tnegative\n\n\\\"\n"
    }

    original = Map.put(record, "literal", literal)
    assert {:ok, ^original} = SharedTuples.expand(SharedTuples.compact(original))
  end

  test "altered, missing, cyclic and unused dictionaries refuse expansion", %{encoded: encoded} do
    assert encoded["line_table"] != []

    invalid = [
      Map.put(encoded, "base_encoding", "unknown"),
      Map.put(encoded, "record", 42),
      Map.put(encoded, "text_table", %{}),
      Map.put(encoded, "line_table", 42),
      Map.put(encoded, "line_table", []),
      update_in(encoded, ["line_table"], &["changed" | tl(&1)]),
      update_in(encoded, ["line_table"], &(&1 ++ ["unused injected bytes"])),
      Map.put(encoded, "record", [-2, 0]),
      encoded |> Map.put("value_table", [[-2, 0]]) |> Map.put("record", %{"original" => [-2, 0]}),
      Map.put(encoded, "raw_record_bytes", SharedTuples.maximum_expanded_bytes() + 1)
    ]

    for value <- invalid, do: assert({:error, _} = SharedTuples.expand(value))
  end

  test "line references cannot amplify beyond the independent expanded bound", %{encoded: encoded} do
    text = String.duplicate("bounded source λ\n", 2000)

    forged =
      encoded
      |> Map.put("line_table", [text])
      |> Map.put("record", %{"original" => [-8, List.duplicate([-9, 1, 0], 1000)]})

    assert byte_size(text) * 1000 > SharedTuples.maximum_expanded_bytes()
    assert {:error, _} = SharedTuples.expand(forged)
  end

  test "malformed JSON-shaped tables and tuple nodes return errors without raising",
       %{encoded: encoded} do
    for field <- ~w(record text_table value_table schema_table observation_table line_table),
        value <- [nil, false, 0, "not a table", %{}, [-3, -1], [-8, 42]] do
      assert {:error, _} = SharedTuples.expand(Map.put(encoded, field, value))
    end
  end

  defp record do
    %{
      "task_request" => "Inspect the complete numbered observations.",
      "original" => %{
        "transcript" =>
          for n <- 1..240 do
            %{
              "id" => "entry-#{n}",
              "type" => "tool_result",
              "seq" => n,
              "payload" => %{
                "name" => "bash",
                "output" =>
                  for line <- 1..65, into: "" do
                    "#{n * 100 + line}\tpublic source body #{line}: preserve all λ bytes, escaped quotes \\\" and original ordering\n"
                  end
              }
            }
          end
      }
    }
  end
end
