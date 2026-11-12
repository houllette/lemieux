defmodule Lemieux.Conversation.Command.Usage do
  @moduledoc "`/usage [refresh]`: asynchronous host account reports, without model inference."
  @behaviour Lemieux.Conversation.Command
  alias Lemieux.AccountUsage
  alias Lemieux.Conversation.Dispatch

  @impl true
  def spec,
    do: %{
      name: "usage",
      description: "show provider account spend and quotas",
      accepts_arguments?: true,
      action: {:account_usage, nil},
      subcommands: ["refresh"]
    }

  @impl true
  def parse(arguments, conversation) when arguments in ["", "refresh"] do
    cached = conversation.account_usage

    if arguments == "" and AccountUsage.fresh?(cached, System.system_time(:second)),
      do: [{:say, AccountUsage.format(cached, cached: true)}],
      else: [{:account_usage, cached}]
  end

  def parse(_arguments, _conversation), do: [{:say, "use /usage or /usage refresh"}]

  @impl true
  def perform(acc, %{account_usage: nil} = host, _effect),
    do:
      Dispatch.say(
        acc,
        host,
        "This host has no provider account usage reporter. Session usage remains available through /context."
      )

  def perform(acc, host, {:account_usage, previous}) do
    Dispatch.run(acc, host, fn ->
      {:account_usage_result, AccountUsage.merge(host.account_usage.(), previous)}
    end)
  end
end
