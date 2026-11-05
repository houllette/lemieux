defmodule LemieuxSystemOneCompaction.DependencySecurityTest do
  use ExUnit.Case, async: true

  test "regex budget exhaustion cannot bypass schema validation" do
    pattern = "^(?:(a+)+b|a+!)$"
    padded = String.duplicate("a", 20) <> "!"

    object_schema =
      JSV.build!(%{
        "type" => "object",
        "patternProperties" => %{pattern => %{"type" => "integer"}}
      })

    denied_schema = JSV.build!(%{"not" => %{"pattern" => pattern}})

    assert {:error, _error} = JSV.validate(%{padded => "not an integer"}, object_schema)
    assert {:error, _error} = JSV.validate(padded, denied_schema)
    assert {:ok, %{"aaa!" => 1}} = JSV.validate(%{"aaa!" => 1}, object_schema)
  end

  test "the SDK schema builder remains compatible with the patched validator" do
    schema = Sinter.Schema.define([{:keep, :boolean, [required: true]}])
    json_schema = Sinter.JsonSchema.generate(schema)

    assert :ok = Sinter.JsonSchema.validate_schema(json_schema)
    assert {:ok, %{"keep" => true}} = JSV.validate(%{"keep" => true}, JSV.build!(json_schema))
    assert {:error, _error} = JSV.validate(%{"keep" => "yes"}, JSV.build!(json_schema))
    assert {:error, [_issue | _]} = Sinter.JsonSchema.validate_schema(%{"type" => "invalid"})
  end
end
