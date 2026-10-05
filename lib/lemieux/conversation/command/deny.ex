defmodule Lemieux.Conversation.Command.Deny do
  @moduledoc """
  `/deny [CALL_ID | all] [REASON]`: refuse a tool call a hook parked.

  The counterpart of `/approve`. The reason is what the model reads as the
  call's result, so it is worth giving: "not on this branch" tells it what
  to do instead, and the default only tells it that somebody said no.

  The first word is a call id when it names a parked call and the start of
  the reason otherwise, so `/deny t2 not yet` refuses `t2` and `/deny not
  yet` refuses the oldest. Ids are model-generated and never look like a
  reason's first word, which is what makes the rule safe.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Approve

  @default_reason "the person watching this session did not approve the call"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "deny",
      description: "refuse a tool call that is waiting for approval, with a reason",
      accepts_arguments?: true,
      action: {:deny, nil, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{approvals: []}), do: {:error, Approve.nothing_waiting()}

  def parse(arguments, %Conversation{approvals: [oldest | _rest] = approvals}) do
    case String.split(String.trim(arguments), ~r/\s+/, parts: 2) do
      [""] ->
        [{:deny, oldest.call_id, nil}]

      ["all"] ->
        Enum.map(approvals, &{:deny, &1.call_id, nil})

      ["all", reason] ->
        Enum.map(approvals, &{:deny, &1.call_id, reason})

      [word] ->
        if Approve.parked?(approvals, word),
          do: [{:deny, word, nil}],
          else: [{:deny, oldest.call_id, word}]

      [word, reason] ->
        if Approve.parked?(approvals, word),
          do: [{:deny, word, reason}],
          else: [{:deny, oldest.call_id, word <> " " <> reason}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:deny, call_id, reason}),
    do: Approve.resolve(acc, host, call_id, {:deny, reason || @default_reason})

  @impl Lemieux.Conversation.Command
  def completions(_typed, %Conversation{approvals: approvals}), do: Approve.choices(approvals)

  @doc "What the model reads when a call is refused without a reason."
  @spec default_reason() :: String.t()
  def default_reason, do: @default_reason
end
