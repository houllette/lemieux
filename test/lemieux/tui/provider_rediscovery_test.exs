defmodule Lemieux.TUI.ProviderRediscoveryTest do
  @moduledoc """
  `/provider ollama` on a screen whose first look at Ollama found nothing —
  it was not running yet — asks the host again rather than failing until
  `lmx` restarts. The keyless missing-key line offers exactly that command.
  """

  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI

  @found [{:preferred, "ollama:qwen3:8b"}, "ollama:qwen3:8b", "ollama:llama3.1:8b"]

  defp screen_with(discover, unavailable \\ ["ollama"]) do
    session = fake_session(snapshot("01SESSION"), unavailable_providers: unavailable)
    state = tui(session: session) |> sized()
    put_in(state.catalog.discover, %{"ollama" => discover})
  end

  defp asked(found) do
    owner = self()

    fn ->
      send(owner, :asked)
      found
    end
  end

  test "asks the host again, then switches to the model it found first" do
    asking = command(screen_with(asked(@found)), "/provider ollama")

    assert_receive {:set_provider, "ollama"}
    assert unwrapped(asking) =~ "looking for ollama models"
    refute unwrapped(asking) =~ "could not switch provider"

    assert_receive :asked
    assert_receive {:provider_discovered, "ollama", @found} = answer
    refute_received {:set_model, _model}

    assert {:noreply, switched} = TUI.handle_info(answer, asking)

    assert_receive {:set_model, "ollama:qwen3:8b"}
    # Recorded too, so `/model` offers the rest of what was found.
    assert "ollama:llama3.1:8b" in switched.catalog.discovered
  end

  test "a daemon still serving nothing says what to do, and is asked only once more" do
    asking = command(screen_with(asked([])), "/provider ollama")

    assert_receive {:provider_discovered, "ollama", []} = answer
    assert {:noreply, said} = TUI.handle_info(answer, asking)

    refute_received {:set_model, _model}

    assert unwrapped(said) =~
             "could not switch provider: Ollama did not answer, or serves no model that " <>
               "can call tools · start it, pull one that can (ollama pull NAME), then " <>
               "/provider ollama again"

    assert_received :asked
    refute_received :asked
  end

  test "a provider the host cannot look for fails at once, asking nobody" do
    state = screen_with(fn -> flunk("the host was asked about groq") end, ["groq"])
    said = command(state, "/provider groq")

    assert unwrapped(said) =~ "could not switch provider: groq has no available models"
    refute_receive {:provider_discovered, _provider, _found}, 50
  end
end
