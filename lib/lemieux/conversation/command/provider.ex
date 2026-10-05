defmodule Lemieux.Conversation.Command.Provider do
  @moduledoc """
  `/provider [NAME]`: which provider the session runs against.

  Bare, it asks — and each front end answers in its own words, because the
  wording says what its menu offers, so `:provider_status` is left to them.
  With a name it waits for the turn and switches.

  The name is normalised the way the session normalises it, so that the
  fallback below matches the name the session answers with:
  `{:provider_unavailable, "ollama"}` for `/provider Ollama` is this
  provider. The session may have no model under it while the host found
  some — an Ollama scan is the case — and then the switch goes to one of
  those: the host's preference for the provider (`:preferred_models`, a
  configured or recently used model) when that exact model was found,
  otherwise the first one found, in the host's order.

  The host decides what is found and in which order, because only it knows
  what it asked. `Lemieux.CLI.TUI.discovered_models/2` leaves out Ollama
  models that cannot call tools and puts first the one `lmx` would start on
  by itself; `Lemieux.TUI.CatalogState.discover/3` keeps that order. Taken
  alphabetically, the first could be an embedding model (`all-minilm` and
  `bge-m3` sort before `llama` and `qwen`) or a chat model without tools, and
  a session's tools go with every request, so the switch succeeded and the
  first prompt after it failed.

  When neither has a model for the provider and the host can look for its
  models again (`:discover`), it is asked, and the switch tried once more
  with what it found (`discovered/4`).
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
      name: "provider",
      description: "switch model provider",
      accepts_arguments?: true,
      action: :provider_status,
      actions: [:provider_status, {:set_provider, "NAME"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:provider_status]
  def parse(_provider, %Conversation{busy?: true}), do: Command.wait()

  def parse(provider, _conversation),
    do: Command.argued(provider, :provider_status, :set_provider)

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, :provider_status), do: acc

  def perform(acc, host, {:set_provider, provider}) do
    provider = provider |> String.trim() |> String.downcase()

    case select_provider(host, provider) do
      {:ok, selected} -> selected(acc, host, selected)
      {:error, {:provider_unavailable, ^provider}} -> select_discovered(acc, host, provider)
      {:error, reason} -> failed(acc, host, reason)
    end
  end

  defp select_provider(host, provider) do
    current = Session.snapshot(host.session).model
    preferred = Map.get(host.preferred_models, provider)

    cond do
      ModelSpec.provider(current) == provider ->
        Session.set_provider(host.session, provider)

      preferred in Session.available_models(host.session, provider) ->
        Session.set_model(host.session, preferred)

      true ->
        Session.set_provider(host.session, provider)
    end
  end

  defp select_discovered(acc, host, provider) do
    offered = Enum.filter(host.discovered, &(ModelSpec.provider(&1) == provider))
    preferred = Map.get(host.preferred_models, provider)
    models = if preferred in offered, do: [preferred], else: offered

    with [model | _rest] <- models,
         {:ok, selected} <- Session.set_model(host.session, model) do
      selected(acc, host, selected)
    else
      [] -> rediscover(acc, host, provider)
      {:error, reason} -> failed(acc, host, reason)
    end
  end

  # Nothing found for the provider, by the session or by the host's first
  # look: the host is asked again when it can look for this provider's
  # models (`Lemieux.Conversation.Dispatch`'s `:discover`), off the host's
  # process, since asking is a request to a daemon. `lmx` looks for Ollama's
  # once, as the screen opens, and its keyless line says `/provider ollama`
  # — which, for somebody who started Ollama after `lmx`, failed until a
  # restart.
  defp rediscover(acc, host, provider) do
    case Map.fetch(host.discover, provider) do
      {:ok, discover} ->
        acc
        |> Dispatch.say(host, "looking for #{provider} models…")
        |> Dispatch.run(host, fn -> {:provider_discovered, provider, discover.()} end)

      :error ->
        failed(acc, host, {:provider_unavailable, provider})
    end
  end

  @doc """
  The second half of `/provider NAME` after the host was asked again: what
  it found is recorded — `{:models_discovered, found}`, for a host that
  offers discovered models in its menus — and the switch is tried once more
  against it. Not a third time: a host that still finds nothing gets the
  sentence saying what to do, rather than another look.
  """
  @spec discovered(
          acc :: Dispatch.acc(),
          host :: Dispatch.t(),
          provider :: String.t(),
          found :: [String.t() | {:preferred, String.t()}]
        ) :: Dispatch.acc()
  def discovered(acc, host, provider, found) when is_list(found) do
    preferred = for {:preferred, spec} <- found, is_binary(spec), do: spec
    specs = for spec <- found, is_binary(spec), do: spec
    discovered = Enum.uniq(preferred ++ specs ++ host.discovered)
    host = %{host | discovered: discovered, discover: Map.delete(host.discover, provider)}
    acc = Dispatch.react(acc, host, {:models_discovered, found})

    if Enum.any?(discovered, &(ModelSpec.provider(&1) == provider)),
      do: select_discovered(acc, host, provider),
      else: Dispatch.say(acc, host, "could not switch provider: " <> none_found(provider))
  end

  # Ollama is the provider `lmx` looks for, and its fix is on this machine.
  defp none_found("ollama"),
    do:
      "Ollama did not answer, or serves no model that can call tools · start it, " <>
        "pull one that can (ollama pull NAME), then /provider ollama again"

  defp none_found(provider), do: "#{provider} has no available models for this session"

  defp failed(acc, host, reason),
    do: Dispatch.say(acc, host, "could not switch provider: #{Conversation.describe(reason)}")

  defp selected(acc, host, model) do
    acc = Dispatch.react(acc, host, {:provider_set, model})

    case Map.get(host.preferred_efforts, ModelSpec.provider(model)) do
      nil -> acc
      effort -> apply_preferred_effort(acc, host, model, effort)
    end
  end

  defp apply_preferred_effort(acc, host, model, effort) do
    case Session.set_reasoning_effort(host.session, effort) do
      {:ok, _selected} ->
        acc

      {:error, reason} ->
        Dispatch.say(
          acc,
          host,
          "switched to #{model}, but could not set configured effort: #{Conversation.describe(reason)}"
        )
    end
  end
end
