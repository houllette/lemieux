defmodule Lemieux.Conversation.Command.Model do
  @moduledoc """
  `/model [SPEC]`: which model, within the current provider.

  The argument is a model id, scoped to the provider the session is already
  on: `/model haiku` under `anthropic:*` asks for `anthropic:haiku`, which is
  why a session whose model names no provider is sent to `/provider` first.
  Bare, it asks, and the front ends answer `:model_status` in their own
  words.

  So `/model ollama:qwen3` under `anthropic:*` asks for
  `anthropic:ollama:qwen3`. A provider with no key refuses that with its
  own missing key, and the line said "no API key for anthropic", about the
  provider the person was trying to leave, with nothing about the one they
  named. So when the current provider's missing key refuses an id that
  starts with the name of another provider `req_llm` knows, the line says
  whose model that is, that the current provider has no key, and what
  switches to the one named (`/provider`, then `/model`).

  Only that refusal, and only on one of `req_llm`'s own providers. A
  router's ids may start with a provider's name — an Ixway route, `/model
  openai:gpt-5` under `ixway:*`, switches as typed — and when the router
  refuses one (a route it does not list, no gateway key, no tool support), its own
  sentence is the reason, as for every other refusal. Rewritten whatever
  the refusal, an Ixway session was told to leave Ixway for the direct
  provider in place of the gateway's answer (found in review, 2026-10).
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.ModelSpec
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "model",
      description: "switch model in this provider",
      accepts_arguments?: true,
      action: :model_status,
      actions: [:model_status, {:set_model, "SPEC"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:model_status]
  def parse(_spec, %Conversation{busy?: true}), do: Command.wait()

  def parse(spec, %Conversation{model: model}) do
    case {String.trim(spec), ModelSpec.provider(model)} do
      {"", _provider} ->
        [:model_status]

      {_id, nil} ->
        [{:say, "the current model has no provider; choose one with /provider"}]

      {id, provider} ->
        [{:set_model, ModelSpec.join(provider, id)}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, :model_status), do: acc

  def perform(acc, host, {:set_model, model}) do
    case Session.set_model(host.session, model) do
      {:ok, selected} ->
        Dispatch.react(acc, host, {:model_set, selected})

      {:error, reason} ->
        Dispatch.say(acc, host, "could not switch model: " <> refusal(model, reason))
    end
  end

  # See the module documentation. `req_llm` names the provider whose key is
  # missing with an atom; a host's provider may use a string.
  defp refusal(model, {:missing_api_key, missing, _hint} = reason) do
    current = ModelSpec.provider(model)
    typed = ModelSpec.model_id(model)

    case ModelSpec.split(typed) do
      {:ok, {named, id}} when named != current ->
        if to_string(missing) == current and provider?(current) and provider?(named),
          do:
            "#{typed} belongs to #{named}, and /model chooses within #{current}, which has " <>
              "no API key · /provider #{named} switches to #{named}, then /model #{id}",
          else: Conversation.describe(reason)

      _within ->
        Conversation.describe(reason)
    end
  end

  defp refusal(_model, reason), do: Conversation.describe(reason)

  defp provider?(name), do: Enum.any?(ReqLLM.Providers.list(), &(Atom.to_string(&1) == name))
end
