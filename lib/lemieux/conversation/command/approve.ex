defmodule Lemieux.Conversation.Command.Approve do
  @moduledoc """
  `/approve [CALL_ID | all]`: run a tool call a hook parked.

  A `before_tool_call` hook that answers `:pending` stops the call and puts
  the decision in a person's hands; `Lemieux.Conversation` lists the call
  under `approvals` and a bare `y` answers the oldest. This command is for
  the other cases: when more than one call is waiting and the one to run is
  not the oldest, and when a person wants to say so in full. `all` runs
  every parked call, oldest first.

  The answer goes through `Lemieux.Session.resolve_tool/3`, and what it
  said is folded back as `{:approval_result, call_id, result}`, so a call
  that was answered elsewhere or timed out in the meantime is reported
  rather than silently believed approved — the session's own reason for
  answering `{:error, :unknown_call}` at all.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "approve",
      description: "run a tool call that is waiting for approval",
      accepts_arguments?: true,
      action: {:approve, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{approvals: []}), do: {:error, nothing_waiting()}

  def parse(arguments, %Conversation{approvals: [oldest | _rest] = approvals}) do
    case String.trim(arguments) do
      "" ->
        [{:approve, oldest.call_id}]

      "all" ->
        Enum.map(approvals, &{:approve, &1.call_id})

      id ->
        if parked?(approvals, id), do: [{:approve, id}], else: {:error, unknown(id, approvals)}
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:approve, call_id}), do: resolve(acc, host, call_id, :allow)

  @impl Lemieux.Conversation.Command
  def completions(_typed, %Conversation{approvals: approvals}), do: choices(approvals)

  @doc false
  @spec resolve(
          acc :: Dispatch.acc(),
          host :: Dispatch.t(),
          call_id :: String.t(),
          decision :: Lemieux.Hooks.decision()
        ) :: Dispatch.acc()
  def resolve(acc, host, call_id, decision) do
    result = Session.resolve_tool(host.session, call_id, decision)

    Dispatch.fold(acc, host, {:approval_result, call_id, result})
  end

  @doc false
  @spec parked?(approvals :: [Conversation.approval()], call_id :: String.t()) :: boolean()
  def parked?(approvals, call_id), do: Enum.any?(approvals, &(&1.call_id == call_id))

  @doc false
  @spec choices(approvals :: [Conversation.approval()]) :: [String.t()]
  def choices(approvals) do
    ids = Enum.map(approvals, & &1.call_id)
    if length(ids) > 1, do: ids ++ ["all"], else: ids
  end

  @doc false
  @spec nothing_waiting() :: String.t()
  def nothing_waiting, do: "nothing is waiting for approval"

  @doc false
  @spec unknown(call_id :: String.t(), approvals :: [Conversation.approval()]) :: String.t()
  def unknown(call_id, approvals) do
    waiting = Enum.map_join(approvals, ", ", &"#{&1.call_id} (#{&1.name})")
    "no parked call is named #{call_id} · waiting: #{waiting}"
  end
end
