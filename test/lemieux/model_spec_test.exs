defmodule Lemieux.ModelSpecTest do
  use ExUnit.Case, async: true

  alias Lemieux.ModelSpec

  test "splits only the provider delimiter so model ids may contain colons" do
    assert {:ok, {"ollama", "qwen3.8:27b-mxfp8"}} =
             ModelSpec.split("ollama:qwen3.8:27b-mxfp8")

    assert ModelSpec.provider("ollama:qwen3.8:27b-mxfp8") == "ollama"
    assert ModelSpec.model_id("ollama:qwen3.8:27b-mxfp8") == "qwen3.8:27b-mxfp8"
  end

  test "rejects incomplete specs" do
    assert :error = ModelSpec.split("openai")
    assert :error = ModelSpec.split(":gpt-5")
    assert :error = ModelSpec.split("openai:")
  end

  test "joins a provider and the entire model id" do
    assert ModelSpec.join("ollama", "qwen:tag") == "ollama:qwen:tag"
  end
end
