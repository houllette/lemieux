defmodule Lemieux.Conversation.Command.Status do
  @moduledoc "Provider-free `/status [namespace command [arguments]]`, performed off the UI loop."
  @behaviour Lemieux.Conversation.Command
  alias Lemieux.Contribution
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl true
  def spec,
    do: %{
      name: "status",
      description: "inspect extension readiness or run a local command",
      action: :extension_status,
      accepts_arguments?: true,
      actions: [:extension_status, {:extension_command, nil, nil, nil}]
    }

  @impl true
  def parse("", _conversation), do: [:extension_status]

  def parse(arguments, _conversation) do
    case String.split(arguments, " ", parts: 3, trim: true) do
      [namespace, command] -> [{:extension_command, namespace, command, ""}]
      [namespace, command, args] -> [{:extension_command, namespace, command, args}]
      _invalid -> {:error, "use /status or /status NAMESPACE COMMAND [ARGUMENTS]"}
    end
  end

  @impl true
  def perform(acc, host, :extension_status) do
    Dispatch.run(acc, host, fn ->
      report =
        if host.session,
          do: Contribution.format(Session.extension_status(host.session)),
          else: "Extension status unavailable: no current session."

      {:extension_result, report}
    end)
  end

  def perform(acc, host, {:extension_command, namespace, name, args}) do
    Dispatch.run(acc, host, fn ->
      result =
        if host.session,
          do: Session.extension_command(host.session, namespace, name, args),
          else: {:error, :unavailable}

      {:extension_result, format_result(result)}
    end)
  end

  @doc false
  @spec format_result(result :: {:ok, map()} | {:error, atom()}) :: String.t()
  def format_result({:ok, status}), do: Contribution.format([status])
  def format_result({:error, reason}), do: "Extension command unavailable: #{reason}."
end
