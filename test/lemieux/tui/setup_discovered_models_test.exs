defmodule Lemieux.TUI.SetupDiscoveredModelsTest do
  # `:discovered_models` takes what a late discovery does (`{:models_discovered,
  # _}`): specs, and the host's `{:preferred, spec}` for the model it would
  # choose. Put in the catalog as given, a `{:preferred, spec}` reached
  # `Lemieux.ModelSpec.provider/1`, which takes a string, at the first merge,
  # and the screen crashed as its session attached.
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI

  @discovered ["ollama:llama3.1:8b", {:preferred, "ollama:qwen3:8b"}, "ollama:gemma3:1b"]

  test "a host's preferred model is taken at start, first, and the session attaches" do
    session =
      fake_session(%{snapshot("01OLLAMA") | model: "ollama:llama3.1:8b", provider: "ollama"})

    assert {:ok, state} =
             TUI.mount(
               test_mode: {80, 24},
               start: fn -> {:ok, session} end,
               discovered_models: @discovered
             )

    assert state.catalog.discovered == [
             "ollama:qwen3:8b",
             "ollama:gemma3:1b",
             "ollama:llama3.1:8b"
           ]

    assert "ollama:qwen3:8b" in state.catalog.models
  end

  test "the same list arriving late is ordered the same way" do
    late = TUI.new(test_mode: {80, 24}, model: "ollama:llama3.1:8b")
    {:noreply, late} = TUI.handle_info({:models_discovered, @discovered}, late)

    at_start =
      TUI.new(test_mode: {80, 24}, model: "ollama:llama3.1:8b", discovered_models: @discovered)

    assert at_start.catalog.discovered == late.catalog.discovered
    assert at_start.catalog.models == late.catalog.models
  end
end
