defmodule Lemieux.CLI.StateTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.State

  @moduletag :tmp_dir

  test "the last model is remembered privately, and nothing is kept without a directory",
       %{tmp_dir: dir} do
    assert State.last_model(dir) == nil
    assert :ok = State.remember_model(dir, "openai:gpt-6-sol")
    assert State.last_model(dir) == "openai:gpt-6-sol"
    assert Bitwise.band(File.stat!(State.path(dir)).mode, 0o777) == 0o600

    assert :ok = State.remember_model(nil, "openai:gpt-6-sol")
    assert State.last_model(nil) == nil
  end

  test "a malformed state file reads as nothing remembered", %{tmp_dir: dir} do
    File.write!(State.path(dir), "not json")
    assert State.last_model(dir) == nil
    assert :ok = State.remember_model(dir, "anthropic:claude-sonnet-5")
    assert State.last_model(dir) == "anthropic:claude-sonnet-5"
  end

  # Only a newer version is news. A first start has nothing to compare with,
  # and going back to an older build is something the person did on purpose.
  test "a version newer than the last one started is reported once", %{tmp_dir: dir} do
    assert State.record_version(dir, "0.1.0") == :unchanged
    assert State.record_version(dir, "0.1.0") == :unchanged
    assert State.record_version(dir, "0.2.0") == {:updated, "0.1.0"}
    assert State.record_version(dir, "0.2.0") == :unchanged
    assert State.record_version(dir, "0.1.5") == :unchanged
    assert State.record_version(dir, "0.2.0") == {:updated, "0.1.5"}

    assert State.record_version(nil, "9.9.9") == :unchanged
  end

  test "the version is kept beside the model, not over it", %{tmp_dir: dir} do
    :ok = State.remember_model(dir, "openai:gpt-6-sol")
    State.record_version(dir, "0.1.0")

    assert State.last_model(dir) == "openai:gpt-6-sol"
    assert State.record_version(dir, "0.2.0") == {:updated, "0.1.0"}
  end

  test "a version that is not SemVer is compared as text", %{tmp_dir: dir} do
    State.record_version(dir, "nightly-a")
    assert State.record_version(dir, "nightly-b") == {:updated, "nightly-a"}
  end

  test "a model used but not chosen goes on the recent list only", %{tmp_dir: dir} do
    :ok = State.remember_model(dir, "anthropic:claude-sonnet-5")
    :ok = State.remember_model(dir, "ollama:qwen3:8b", chosen?: false)

    assert State.last_model(dir) == "anthropic:claude-sonnet-5"
    assert State.recent_models(dir) == ["ollama:qwen3:8b", "anthropic:claude-sonnet-5"]

    # Used again, it moves to the front rather than appearing twice.
    :ok = State.remember_model(dir, "anthropic:claude-sonnet-5", chosen?: false)
    assert State.recent_models(dir) == ["anthropic:claude-sonnet-5", "ollama:qwen3:8b"]

    assert State.recent_models(nil) == []
  end

  test "the recent list is bounded", %{tmp_dir: dir} do
    for n <- 1..15, do: :ok = State.remember_model(dir, "ollama:m#{n}", chosen?: false)

    assert [newest | _] = recent = State.recent_models(dir)
    assert newest == "ollama:m15"
    assert length(recent) == 10
  end
end
