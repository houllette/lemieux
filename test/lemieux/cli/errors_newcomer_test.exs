defmodule Lemieux.CLI.ErrorsNewcomerTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Errors
  alias Lemieux.Conversation
  alias Lemieux.Provider.Error, as: ProviderError

  describe "model specifications" do
    test "a bare model name says to write PROVIDER:MODEL" do
      sentence = Errors.describe({:unknown_model, "gpt-4o", :invalid_format})

      assert sentence =~ "gpt-4o is not a model specification"
      assert sentence =~ "PROVIDER:MODEL"
      assert sentence =~ "lmx help models"
      refute sentence =~ "invalid_format"
    end

    test "an empty half is the same mistake" do
      assert Errors.describe({:unknown_model, "anthropic:", :empty_segment}) =~ "PROVIDER:MODEL"
    end

    test "an unknown provider is named, not inspected" do
      sentence = Errors.describe({:unknown_model, "foo:bar", :unknown_provider})

      assert sentence =~ "(foo)"
      refute sentence =~ "unknown_provider"
    end

    test "from a source checkout the help command is mix lmx's" do
      sentence =
        Errors.describe({:unknown_model, "gpt-4o", :invalid_format}, program: "mix lmx")

      assert sentence =~ "(mix lmx help models)"
    end

    # The terminal UI says the same sentence: it used to print the atom too.
    test "the terminal UI's sentence is this one" do
      assert Conversation.describe({:unknown_model, "gpt-4o", :invalid_format}) ==
               Errors.unknown_model("gpt-4o", :invalid_format)
    end
  end

  describe "stored sessions" do
    test "a missing stored session is a sentence, not an inspected atom" do
      sentence = Errors.describe(:not_found)

      refute sentence =~ ":not_found"
      assert sentence =~ "no stored session"
    end

    test "names the reference that was typed" do
      assert Errors.describe(:not_found, resume: "nothere") =~
               "no stored session has the id or name nothere"
    end

    test "an ambiguous name lists the sessions it could be" do
      assert Errors.describe({:ambiguous, ["01A", "01B"]}) =~ "01A, 01B"
    end
  end

  describe "a connection that never opened" do
    @refused %Finch.TransportError{reason: :econnrefused}

    test "names the endpoint and the likely fix for a local Ollama" do
      sentence = Errors.describe(@refused, model: "ollama:llama3")

      assert sentence =~
               "could not reach ollama at http://localhost:11434 (connection refused): " <>
                 "is Ollama running?"
    end

    test "names the gateway it was routed through, and only its origin" do
      sentence =
        Errors.describe(@refused,
          model: "openai:gpt-6-sol",
          base_url: "https://user:secret@gateway.example:8443/v1/private?token=x"
        )

      assert sentence =~ "could not reach openai at https://gateway.example:8443"
      assert sentence =~ "--base-url"
      refute sentence =~ "secret"
      refute sentence =~ "private"
      refute sentence =~ "token"
    end

    test "a name that does not resolve suggests being offline" do
      sentence =
        Errors.describe(%{reason: %{reason: :nxdomain}}, model: "anthropic:claude-sonnet-5")

      assert sentence =~ "could not reach anthropic at https://api.anthropic.com"
      assert sentence =~ "did not resolve"
      assert sentence =~ "offline"
    end

    test "without a model to name, the sentence stays the provider's" do
      assert Errors.describe(@refused) == ProviderError.message(@refused)
    end

    test "is nothing to say about a failure that is not a connection" do
      assert Errors.connection_failure(:not_found, model: "ollama:llama3") == nil
      assert Errors.connection_failure(@refused, []) == nil
    end

    # The terminal UI cannot tell whether a gateway was in the way, and the
    # provider's own address would be the wrong one behind `--base-url`.
    test "names no address when the gateway is unknown, and the switch it is given" do
      sentence =
        Errors.connection_failure(@refused,
          model: "ollama:llama3",
          base_url: :unknown,
          switch: "/model"
        )

      assert sentence =~ "could not reach ollama (connection refused): is Ollama running?"
      assert sentence =~ "choose another model with /model"
      refute sentence =~ "localhost"
      refute sentence =~ "--model"

      assert Errors.connection_failure(@refused, model: "openai:gpt-6-sol", base_url: :unknown) =~
               "could not reach openai (connection refused): is the server it was sent to running?"
    end
  end

  # Ollama not running put "error: connection refused · /retry …" on the
  # screen of the person most likely to meet it: a newcomer on a local model.
  describe "the terminal UI's line for a connection that never opened" do
    test "names the provider and the fix, and still offers /retry" do
      line =
        Conversation.error_line(
          Conversation.new(model: "ollama:llama3"),
          %Finch.TransportError{reason: :econnrefused}
        )

      assert line =~ "error: could not reach ollama (connection refused): is Ollama running?"
      assert line =~ "`ollama serve`"
      assert line =~ "/model"
      assert line =~ "· /retry to send the request again"
    end

    test "leaves every other failure's line as it was" do
      conversation = Conversation.new(model: "ollama:llama3")
      reason = %Finch.TransportError{reason: :closed}

      assert Conversation.error_line(conversation, reason) ==
               "error: #{Conversation.describe(reason)} · /retry to send the request again"
    end
  end
end
