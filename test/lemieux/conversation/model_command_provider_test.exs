defmodule Lemieux.Conversation.ModelCommandProviderTest do
  # `/model` chooses within the current provider, so `/model ollama:qwen3:8b`
  # on a keyless `anthropic:` session asks for `anthropic:ollama:qwen3:8b`.
  # The refusal said "no API key for anthropic", about the provider the
  # person was trying to leave, and nothing about the one they named.
  #
  # Under a router the same words are a route id: `/model openai:gpt-5` on an
  # `ixway:` session asks for `ixway:openai:gpt-5`. A refusal there is the
  # gateway's to explain, and the line once replaced it with advice to leave
  # Ixway for the direct provider.
  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Model
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Ixway
  alias Lemieux.Providers.ReqLLM, as: Provider
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir
  @placeholder "anthropic:claude-sonnet-5"

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_model_command_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start(context, provider, model) do
    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: model,
        subscriber: self()
      )

    {session, model}
  end

  # No key for anthropic: the suite removes provider keys from the
  # environment, and this provider is given none.
  defp keyless(context), do: start(context, Provider.new(), @placeholder)

  # A gateway whose catalogue is given, so nothing is asked over the network.
  # Its ids include one that starts with a provider's name, as Ixway route
  # ids do (`openai_codex:gpt-5.6-luna`).
  defp ixway(context, api_key) do
    connection = %{
      Ixway.new(endpoint: "https://gateway.example", api_key: api_key)
      | models: [route("fast"), route("openai:gpt-5")],
        client_policy: %{}
    }

    start(context, Ixway.provider(connection), "ixway:fast")
  end

  defp route(id),
    do: %{"id" => id, "ixway_ingress_dialects" => ["openai_chat"], "max_input_tokens" => 32_000}

  # What `/model TYPED` does on `session`: the one line it said, or the
  # reaction to a model it switched to.
  defp answer({session, model}, typed) do
    conversation = Conversation.new(model: model)
    [action] = Model.parse(typed, conversation)

    host =
      Dispatch.new(
        session: session,
        id: Lemieux.Session.id(session),
        say: fn acc, text -> %{acc | calls: [{:say, text} | acc.calls]} end,
        write: fn acc, _text -> acc end,
        fold: fn acc, _event -> acc end,
        run: fn acc, _work -> acc end,
        react: fn acc, reaction -> %{acc | calls: [{:react, reaction} | acc.calls]} end,
        clipboard: fn _text -> :ok end
      )

    acc = Dispatch.perform(%{conversation: conversation, calls: []}, host, action)
    assert [call] = acc.calls
    call
  end

  defp said(session, typed) do
    assert {:say, line} = answer(session, typed)
    line
  end

  test "names the provider of the model asked for, and what switches to it", context do
    line = context |> keyless() |> said("ollama:qwen3:8b")

    assert line ==
             "could not switch model: ollama:qwen3:8b belongs to ollama, and /model chooses " <>
               "within anthropic, which has no API key · /provider ollama switches to ollama, " <>
               "then /model qwen3:8b"

    refute line =~ "no API key for anthropic"
  end

  # A model id of the current provider's that is refused keeps the reason.
  test "a refused id that names no other provider says why it was refused", context do
    session = keyless(context)

    assert said(session, "claude-haiku-5") =~
             "could not switch model: no API key for anthropic · set ANTHROPIC_API_KEY"

    # A colon inside an id is not a provider: Ollama tags have them.
    assert said(session, "custom:tag") =~ "no API key for anthropic"
  end

  describe "under an Ixway route" do
    test "a route the gateway does not advertise keeps the gateway's reason", context do
      line = context |> ixway("gateway-key") |> said("openai:gpt-5x")

      assert line ==
               "could not switch model: " <>
                 Exception.message(%Ixway.Error{reason: :model_not_available})

      refute line =~ "belongs to"
      refute line =~ "/provider openai"
    end

    test "a missing gateway key keeps the gateway's reason", context do
      line = context |> ixway(nil) |> said("openai:gpt-5")

      assert line ==
               "could not switch model: " <>
                 Exception.message(%Ixway.Error{reason: :api_key_required})

      refute line =~ "belongs to"
    end

    test "a route id that starts with a provider's name switches as typed", context do
      assert {:react, {:model_set, "ixway:openai:gpt-5"}} =
               context |> ixway("gateway-key") |> answer("openai:gpt-5")
    end
  end
end
