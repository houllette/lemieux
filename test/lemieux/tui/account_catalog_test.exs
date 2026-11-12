defmodule Lemieux.TUI.AccountCatalogTest do
  use ExUnit.Case, async: true
  alias Lemieux.TUI

  test "account replacements preserve selection, effort, preference and recent history" do
    current = "openai_codex:manually-chosen"

    state =
      TUI.new(
        test_mode: {80, 24},
        model: current,
        models: [current, "openai_codex:old-account"],
        preferred_models: %{"openai_codex" => current}
      )

    state = %{state | conversation: %{state.conversation | reasoning_effort: "high"}}

    before = state.conversation
    recent = state.catalog.recent_models

    assert {:noreply, state} =
             TUI.handle_info(
               {:model_catalog, "openai_codex", ["openai_codex:new-model"], nil},
               state
             )

    assert current in state.catalog.models
    assert "openai_codex:new-model" in state.catalog.models
    refute "openai_codex:old-account" in state.catalog.models
    assert state.conversation == before
    assert state.conversation.reasoning_effort == "high"
    assert state.catalog.preferred_models == %{"openai_codex" => current}
    assert state.catalog.recent_models == recent
    assert Enum.any?(state.catalog.model_choices, &(&1.spec == "openai_codex:new-model"))

    assert {:noreply, state} =
             TUI.handle_info(
               {:model_catalog, "openai_codex", [],
                "Discovery unavailable; select a model manually."},
               state
             )

    assert state.catalog.models == [current]
    assert state.conversation == before
    assert Enum.any?(state.terminal.notices.items, &(&1.text =~ "Discovery unavailable"))
  end

  test "account discovery on another provider adds one provider without switching it" do
    state = TUI.new(test_mode: {80, 24}, model: "test:current", models: ["test:current"])

    assert {:noreply, state} =
             TUI.handle_info(
               {:model_catalog, "openai_codex", ["openai_codex:one", "openai_codex:two"], nil},
               state
             )

    assert Enum.count(state.catalog.providers, &(&1 == "openai_codex")) == 1
    assert state.catalog.models == ["test:current"]
    assert state.catalog.discovered == ["openai_codex:one", "openai_codex:two"]
    assert state.conversation.model == "test:current"
  end
end
