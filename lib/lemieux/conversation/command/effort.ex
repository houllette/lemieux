defmodule Lemieux.Conversation.Command.Effort do
  @moduledoc """
  `/effort [LEVEL]`: the model's reasoning effort.

  Bare, it asks, and the front ends answer `:reasoning_effort_status` in
  their own words; with a level it waits for the turn and sets it.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "effort",
      description: "set reasoning effort",
      accepts_arguments?: true,
      action: :reasoning_effort_status,
      actions: [:reasoning_effort_status, {:set_reasoning_effort, "LEVEL"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:reasoning_effort_status]
  def parse(_effort, %Conversation{busy?: true}), do: Command.wait()

  def parse(effort, _conversation),
    do: Command.argued(effort, :reasoning_effort_status, :set_reasoning_effort)

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, :reasoning_effort_status), do: acc

  def perform(acc, host, {:set_reasoning_effort, effort}) do
    case Session.set_reasoning_effort(host.session, effort) do
      {:ok, _effort} ->
        Dispatch.react(acc, host, {:reasoning_effort_set, effort})

      {:error, reason} ->
        Dispatch.say(
          acc,
          host,
          "could not set reasoning effort: #{Conversation.describe(reason)}"
        )
    end
  end
end
