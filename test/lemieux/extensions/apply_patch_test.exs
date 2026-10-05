defmodule Lemieux.Extensions.ApplyPatchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.ApplyPatch
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  defp names(model, opts \\ [], catalog \\ nil) do
    base = if catalog, do: Harness.new(tools: catalog), else: Harness.new()
    {:ok, harness} = Harness.assemble(base, [{ApplyPatch, [model: model] ++ opts}])
    # An inactive extension leaves the catalog unset: the session's default.
    Enum.map(harness.tools || Tools.default(), &Tool.name/1)
  end

  test "GPT-5-family models get apply_patch in edit's place" do
    for model <- [
          "openai:gpt-5",
          "openai:gpt-5-mini",
          "openai:gpt-5.1-codex",
          "ixway:gpt-5.6-luna",
          "openrouter:openai/gpt-5",
          "OPENAI:GPT-5"
        ] do
      assert names(model) == ~w(read write apply_patch bash), model
    end
  end

  test "other models keep edit" do
    for model <- [
          "zai_coding_plan:glm-5.3",
          "anthropic:claude-sonnet-5",
          "openai:gpt-4o-mini",
          "openai:gpt-50",
          "ollama:gpt-5ish",
          nil
        ] do
      assert names(model) == ~w(read write edit bash), inspect(model)
    end
  end

  test "patterns and mode are configurable" do
    assert names("anthropic:claude-sonnet-5", models: ["claude-*"]) ==
             ~w(read write apply_patch bash)

    assert names("openai:gpt-5", mode: :add) == ~w(read write edit apply_patch bash)
  end

  test "a catalog without edit is not given a write tool it did not have" do
    assert names("openai:gpt-5", [], [Tools.Read, Tools.Bash]) == ~w(read bash)
  end

  test "bad options stop assembly" do
    assert {:error, {ApplyPatch, message}} =
             Harness.assemble(Harness.new(), [{ApplyPatch, model: "openai:gpt-5", mode: :swap}])

    assert message =~ ":mode"
  end

  test "records whether it was active" do
    {:ok, harness} = Harness.assemble(Harness.new(), [{ApplyPatch, model: "openai:gpt-5"}])

    assert [%{"options" => %{"active" => true, "model" => "openai:gpt-5", "mode" => "replace"}}] =
             harness.applied
  end
end
