defmodule Lemieux.Conversation.Command.Usage do
  @moduledoc "`/usage [refresh]`: asynchronous host account reports, without model inference."
  @behaviour Lemieux.Conversation.Command
  alias Lemieux.AccountUsage
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.ID

  @impl true
  def spec,
    do: %{
      name: "usage",
      description: "show provider account spend and quotas",
      accepts_arguments?: true,
      action: {:account_usage, nil, nil},
      subcommands: [{"refresh", {:account_usage, nil, nil}}]
    }

  @impl true
  def parse(arguments, %{usage_request_id: id})
      when arguments in ["", "refresh"] and is_binary(id),
      do: [{:say, "a provider usage report is already being fetched"}]

  def parse(arguments, conversation) when arguments in ["", "refresh"] do
    cached = conversation.account_usage

    if arguments == "" and AccountUsage.fresh?(cached, System.system_time(:second)) do
      [{:say, AccountUsage.format(cached, cached: true)}]
    else
      id = ID.generate()
      {%{conversation | usage_request_id: id}, [{:account_usage, id, cached}]}
    end
  end

  def parse(_arguments, _conversation), do: [{:say, "use /usage or /usage refresh"}]

  @impl true
  def perform(acc, %{account_usage: nil} = host, {:account_usage, id, _previous}),
    do:
      Dispatch.fold(
        acc,
        host,
        {:account_usage_result, id,
         {:error,
          "This host has no provider account usage reporter. Session usage remains available through /context."}}
      )

  def perform(acc, host, {:account_usage, id, previous}) do
    Dispatch.run(acc, host, fn ->
      {:account_usage_result, id, fetch(host.account_usage, previous)}
    end)
  end

  defp fetch(callback, previous) do
    report = AccountUsage.merge(callback.(), previous)
    {:ok, report, AccountUsage.format(report)}
  rescue
    _error ->
      {:error,
       "The provider usage reporter failed; the session remains usable. Try /usage refresh again."}
  catch
    _kind, _reason -> {:error, "The provider usage reporter stopped; try /usage refresh again."}
  end
end
