defmodule Lemieux.Conversation.KeylessAndCutOffTest do
  # Two lines a front end owes a person who would otherwise be misled: the
  # missing-key error on a model nobody chose, which used to steer a keyless
  # newcomer to the placeholder's vendor, and the note that an answer stopped
  # at the output cap rather than finishing.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Models
  alias Lemieux.Conversation

  @missing {:missing_api_key, "anthropic", ":api_key option or ANTHROPIC_API_KEY env var"}

  defp said(effects), do: for({:say, text} <- effects, do: text)

  defp failure_line(conversation, reason \\ @missing),
    do: conversation |> Conversation.event({:error, reason}) |> elem(1) |> said()

  describe "a missing key" do
    test "on a model a host or person chose names its provider and the variable" do
      conversation = Conversation.new(model: "anthropic:claude-sonnet-5")

      assert conversation.model_chosen?

      assert failure_line(conversation) ==
               ["no API key for anthropic · set ANTHROPIC_API_KEY, or switch with /provider"]
    end

    test "on a model nobody chose names no vendor, and every way to a key or a local model" do
      [line] =
        failure_line(Conversation.unchosen(Conversation.new(model: "anthropic:claude-sonnet-5")))

      assert line =~ "no provider key was found"
      assert line =~ "start again and paste one when asked"
      refute line =~ "no API key for"
      refute line =~ "anthropic"
      # `/provider` saves no key, and switching to a vendor with none set is
      # the same refusal: it is offered for Ollama only, which needs none.
      refute line =~ "switch with /provider"
      refute line =~ "/retry"
    end

    # `/model` names a model within the current provider: on the anthropic
    # placeholder, `/model ollama:NAME` asked for `anthropic:ollama:NAME` and
    # was refused for the same missing key, in a real keyless sitting.
    test "the way to a local model is /provider ollama, not /model ollama:NAME" do
      [line] =
        failure_line(Conversation.new(model: "anthropic:claude-sonnet-5", model_chosen?: false))

      assert line =~ "or run a model on this machine with Ollama: /provider ollama"
      refute line =~ "/model"
    end

    test "names the first two rows of lmx's provider table as examples, whatever they are" do
      [first, second | _rest] = Models.recommended()
      [line] = failure_line(Conversation.new(model_chosen?: false))

      assert line =~ "such as #{first.env} or #{second.env}"
    end

    test "a model change is a choice, and the line names its provider again" do
      {changed, _effects} =
        [model: "anthropic:claude-sonnet-5", model_chosen?: false]
        |> Conversation.new()
        |> Conversation.event({:model_changed, "anthropic:claude-sonnet-5", "openai:gpt-6-sol"})

      assert changed.model_chosen?

      assert failure_line(changed, {:missing_api_key, "openai", "OPENAI_API_KEY env var"}) ==
               ["no API key for openai · set OPENAI_API_KEY, or switch with /provider"]
    end

    test "other failures on a model nobody chose are worded as before" do
      conversation = Conversation.unchosen(Conversation.new(model: "anthropic:claude-sonnet-5"))

      [line] = failure_line(conversation, {:context_limit, "too long"})
      refute line =~ "no provider key was found"
    end
  end

  describe "a turn the output cap ended" do
    test "says the answer was cut off, and how to have it carry on" do
      {_conversation, effects} =
        Conversation.new(model: "ollama:qwen3.8")
        |> Map.put(:busy?, true)
        |> Conversation.event({:finished, :length})

      assert [note] = said(effects)
      assert note =~ "the answer was cut off at the model's output limit"
      assert note =~ ~s(send "continue")
      assert :idle in effects
    end

    test "a turn that finished says nothing of the kind" do
      {_conversation, effects} = Conversation.event(Conversation.new(), {:finished, :stop})

      assert said(effects) == []
    end

    # A reflection has its own note: what is lost is the JSON after the cut.
    test "a reflection that ran out says so in its own words, once" do
      {_conversation, effects} =
        Conversation.new()
        |> Map.put(:reflecting, :opportunities)
        |> Conversation.event({:finished, :length})

      assert [note] = said(effects)
      assert note =~ "the reflection ran out of output tokens"
    end
  end

  describe "the window sentences front ends share" do
    test "a small window is said the same way as the event the terminal UI draws" do
      small = %{model: "ollama:gemma4:12b", window: 4_096, overhead: 3_490, source: :served}

      {_conversation, [{:say, drawn}]} =
        Conversation.event(Conversation.new(), {:context_window_small, small})

      assert drawn == "  · " <> Conversation.small_window(small)
      assert Conversation.small_window(small) =~ "OLLAMA_CONTEXT_LENGTH=65536"
      refute Conversation.small_window(small) =~ "--context-window"
    end

    test "an ineffective compaction leaves /compact to a front end that has it" do
      info = %{input_tokens: 90_000, threshold: 80_000, window: 100_000, retry_in: 32}

      {_conversation, [{:say, drawn}]} =
        Conversation.event(Conversation.new(), {:compaction_ineffective, info})

      assert drawn ==
               "  · " <> Conversation.ineffective_compaction(info) <> " · /compact still works"

      refute Conversation.ineffective_compaction(info) =~ "/compact"
      assert Conversation.ineffective_compaction(info) =~ "for 32 requests"
    end
  end
end
