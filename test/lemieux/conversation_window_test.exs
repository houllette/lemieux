defmodule Lemieux.ConversationWindowTest do
  @moduledoc """
  What a front end says about the window a session plans against.

  Each sentence here names a cause and a fix, and has to be true: the one it
  replaced told local-model users their session would never compact while
  it compacted at a third of its window, and pointed them at a flag that
  cannot change the window Ollama serves.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Conversation

  defp said(event) do
    {_conversation, effects} = Conversation.event(Conversation.new(model: "test:model"), event)
    for({:say, text} <- effects, do: text) |> Enum.join("\n")
  end

  describe "a window too small for the session's own instructions and tools" do
    test "names Ollama's own setting for a local model, and how to check it" do
      text =
        said(
          {:context_window_small,
           %{model: "ollama:gemma4:12b", window: 4_096, overhead: 3_490, source: :served}}
        )

      assert text =~ "ollama:gemma4:12b has a 4,096-token context window"
      assert text =~ "this session's own instructions and tools take about 3,490 of it"
      assert text =~ "OLLAMA_CONTEXT_LENGTH=65536"
      assert text =~ "32768 at the least"
      # The desktop app does not see a variable exported in a shell.
      assert text =~ "the Ollama app's Context length setting"
      assert text =~ "restart Ollama"
      assert text =~ "ollama ps"
      refute text =~ "--context-window"
      # Any host renders this sentence, not only lmx.
      refute text =~ "lmx"
    end

    test "points a configured window back at the flag that set it" do
      text =
        said(
          {:context_window_small,
           %{model: "test:model", window: 6_000, overhead: 3_500, source: :configured}}
        )

      assert text =~ "test:model has a 6,000-token context window"
      assert text =~ "--context-window"
      refute text =~ "OLLAMA_CONTEXT_LENGTH"
    end

    test "suggests a larger model for a hosted one" do
      text =
        said(
          {:context_window_small,
           %{model: "test:model", window: 8_000, overhead: 3_500, source: :provider}}
        )

      assert text =~ "choose a model with a larger window"
    end
  end

  describe "a summary that made no room" do
    test "says the session stopped summarising, for how long, and what still works" do
      text =
        said(
          {:compaction_ineffective,
           %{input_tokens: 9_750, threshold: 8_000, window: 10_000, retry_in: 32}}
        )

      assert text =~ "summarising made no room"
      assert text =~ "about 9,750 tokens, over the 8,000"
      assert text =~ "for 32 requests"
      assert text =~ "/compact still works"
    end
  end

  describe "an unknown window" do
    test "says what the session plans against" do
      assert said({:context_window_unknown, %{model: "local:thing", fallback: 128_000}}) =~
               "is planning as if it held 128.0k tokens"
    end

    # The flag describes a window to lmx and cannot change Ollama's, so a
    # local model is not pointed at it; the daemon reports the window once
    # it has loaded the model, and the session learns it then.
    test "for a local Ollama model says the daemon will report it, not the flag" do
      text = said({:context_window_unknown, %{model: "ollama:gemma4:12b", fallback: 128_000}})

      assert text =~ "Ollama has not said yet what window it serves ollama:gemma4:12b with"
      assert text =~ "planning as if it held 128.0k tokens until it does"
      assert text =~ "ollama ps"
      refute text =~ "--context-window"
    end

    test "says nothing compacts on its own when the host turned the fallback off" do
      text = said({:context_window_unknown, %{model: "local:thing", fallback: nil}})

      assert text =~ "will not compact on its own"
      refute text =~ "conservative guess"
    end

    # The note a front end makes itself when the session never said it: a
    # local model is not pointed at the flag there either.
    test "noticed from the context alone, for a local model, names the daemon" do
      {_conversation, effects} =
        Conversation.event(
          Conversation.new(model: "ollama:gemma4:12b"),
          {:context, %Lemieux.Context{measured?: true, window: nil, tokens: 10}}
        )

      text = for({:say, text} <- effects, do: text) |> Enum.join("\n")

      assert text =~ "Ollama has not said what window it serves ollama:gemma4:12b with"
      refute text =~ "--context-window"
    end
  end
end
