defmodule Lemieux.CLI.Learning.ReflectionSharedValuesTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Learning.Reflection.SharedText
  alias Lemieux.CLI.Learning.Reflection.SharedValues
  alias Lemieux.Contract

  test "partly repeated outputs and object shapes fit without dropping a trajectory position" do
    original = record(240)
    assert byte_size(Contract.encode!(original)) > Reflection.source_limit()
    assert byte_size(Contract.encode!(SharedText.compact(original))) > Reflection.source_limit()
    encoded = SharedValues.compact(original)
    assert encoded["text_encoding"] == "lossless_shared_values/v2"
    assert byte_size(Contract.encode!(encoded)) < Reflection.source_limit()
    assert {:ok, ^original} = SharedValues.expand(encoded)
    assert encoded["schema_table"] != %{}
    assert encoded["value_table"] != %{}

    index = Reflection.citation_index(encoded)
    assert Enum.any?(index, &(&1["entry_id"] == "entry-240"))
    assert Enum.any?(index, &(&1["type"] == "shared_text"))
    assert Enum.all?(index, &existing_pointer?(encoded, &1["pointer"]))
  end

  test "version one remains readable with its original canonical encoding" do
    text = String.duplicate("complete original observation λ\n", 40)
    original = %{"original" => %{"a" => text, "b" => text}}
    legacy = SharedText.compact(original)
    assert legacy["text_encoding"] == "lossless_shared_text/v1"
    assert {:ok, ^original} = SharedValues.expand(legacy)
    assert SharedText.compact(original) == legacy
  end

  test "reserved dictionaries, empty lines, escapes and repeated values round trip exactly" do
    literal = %{
      "$text" => "not a reference",
      "$value" => "literal",
      "$row" => ["literal"],
      "$join" => ["literal"],
      "$object" => [["literal", "a\r\n\nλ\"\\\n"]],
      "$observation" => "literal"
    }

    original = Map.put(record(12), "probes", List.duplicate(literal, 10))
    encoded = SharedValues.compact(original)
    assert encoded != original
    assert {:ok, ^original} = SharedValues.expand(encoded)
  end

  test "changed, missing, cyclic and injected dictionaries refuse expansion" do
    encoded = SharedValues.compact(record(12))
    assert encoded["text_encoding"] == "lossless_shared_values/v2"
    {value_key, _} = Enum.at(encoded["value_table"], 0)
    {text_key, _} = Enum.at(encoded["text_table"], 0)
    {schema_key, _} = Enum.at(encoded["schema_table"], 0)

    invalid = [
      put_in(encoded, ["value_table", value_key], %{"$value" => value_key}),
      update_in(encoded, ["value_table"], &Map.delete(&1, value_key)),
      put_in(encoded, ["value_table", "injected"], %{"unrelated" => true}),
      put_in(encoded, ["text_table", text_key], "changed"),
      put_in(encoded, ["text_table", "injected"], "unused"),
      put_in(encoded, ["schema_table", schema_key], ["duplicate", "duplicate"]),
      put_in(encoded, ["value_table", value_key], %{"$join" => [42]}),
      Map.put(encoded, "raw_record_bytes", SharedValues.maximum_expanded_bytes() + 1)
    ]

    for record <- invalid, do: assert({:error, _} = SharedValues.expand(record))
  end

  test "joined references cannot amplify beyond the separately bounded expanded source" do
    encoded = SharedValues.compact(record(12))
    text = String.duplicate("bounded public output\n", 1000)

    forged =
      encoded
      |> put_in(["text_table", "amplifier"], text)
      |> Map.put("original", %{"$join" => List.duplicate(%{"$text" => "amplifier"}, 500)})

    assert byte_size(text) * 500 > SharedValues.maximum_expanded_bytes()
    assert {:error, _} = SharedValues.expand(forged)
  end

  defp record(count) do
    shared =
      for line <- 1..65, into: "" do
        "bounded reusable source line #{line}: preserve exact λ bytes and escapes \\\"\n"
      end

    %{
      "task_request" => "Inspect and verify the complete source.",
      "original" => %{
        "transcript" =>
          for n <- 1..count do
            %{
              "id" => "entry-#{n}",
              "type" => "tool_result",
              "seq" => n,
              "payload" => %{
                "name" => "bash",
                "output" => "unique start #{n}\n" <> shared <> "unique finish #{n}\n",
                "context" => %{
                  "scope" => "the same explicitly bounded scope",
                  "permitted" => ["read", "workspace_write"],
                  "uncertainty" => "mechanics evidence does not establish transfer"
                }
              }
            }
          end
      }
    }
  end

  defp existing_pointer?(record, pointer) do
    value =
      pointer
      |> String.trim_leading("/")
      |> String.split("/")
      |> Enum.reduce(record, fn part, value ->
        key = part |> String.replace("~1", "/") |> String.replace("~0", "~")

        if is_list(value),
          do: Enum.at(value, String.to_integer(key)),
          else: Map.fetch!(value, key)
      end)

    is_map(value) or is_binary(value)
  end
end
