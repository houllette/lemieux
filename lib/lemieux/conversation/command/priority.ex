defmodule Lemieux.Conversation.Command.Priority do
  @moduledoc "Choose the requested service tier for the next model request."

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "priority",
      description: "choose the service tier for the next request",
      accepts_arguments?: true,
      action: :priority_status,
      actions: [:priority_status, {:set_priority, "TIER"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(arguments, _conversation) do
    case String.trim(arguments) do
      "" -> [:priority_status]
      tier -> [{:set_priority, tier}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :priority_status) do
    available = host.session |> Session.priority_tiers() |> Enum.map_join(", ", &elem(&1, 0))
    Dispatch.say(acc, host, "Choose with /priority TIER · available: #{available}")
  end

  def perform(acc, host, {:set_priority, tier}) do
    case Session.set_priority(host.session, tier) do
      {:ok, selected} ->
        acc
        |> Dispatch.react(host, {:priority_set, selected})
        |> Dispatch.say(
          host,
          "Priority: #{String.capitalize(selected)} · applies to the next model request"
        )

      {:error, {:priority_unsupported, model, requested, supported}} ->
        Dispatch.say(
          acc,
          host,
          "#{requested} is unavailable for #{model} · available: #{Enum.join(supported, ", ")}"
        )

      {:error, reason} ->
        Dispatch.say(acc, host, "could not set priority: #{Conversation.describe(reason)}")
    end
  end
end
