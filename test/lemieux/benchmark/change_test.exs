defmodule Lemieux.Benchmark.ChangeTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Change

  test "release and dependency gates require a SemVer minor bump" do
    assert :ok = Change.validate("release", "1.4.7", "1.5.0")
    assert :ok = Change.validate("dependency", "2.8.1", "2.9.0")

    assert {:error, :not_a_minor_bump} = Change.validate("release", "1.4.7", "1.4.8")
    assert {:error, :not_a_minor_bump} = Change.validate("release", "1.4.7", "2.0.0")
    assert {:error, {:invalid_version, "new"}} = Change.validate("dependency", "2.8.1", "new")
  end

  test "model, prompt and tool-schema changes use stable identifiers rather than SemVer" do
    for kind <- ["model", "prompt", "tool_schema"] do
      assert :ok = Change.validate(kind, "old", "new")
    end
  end
end
