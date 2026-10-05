defmodule Lemieux.CLI.TUIRediscoveryTest do
  @moduledoc """
  What `lmx` hands the screen to look at Ollama again with: the look it
  took as the screen opened, for `ollama` alone, and nothing for a host
  that supplied its own provider.
  """

  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI
  alias Lemieux.Providers.Scripted

  defp opening(opts) do
    {:ok, options} = Options.parse(["--config", "none"], command: :tui)
    TUI.opening_app(options, opts, size: {80, 24}, title: fn _text -> :ok end)
  end

  test "the screen gets lmx's own look at Ollama, by provider" do
    look = fn -> ["ollama:qwen3:8b"] end

    assert %{"ollama" => ^look} = opening(discover_models: look)[:discover]
  end

  test "a host route looks for nothing" do
    assert opening(provider: Scripted.new([]))[:discover] == %{}
  end
end
