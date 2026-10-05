defmodule Lemieux.Conversation.Command.Resume do
  @moduledoc """
  `/resume [SESSION | all]`: continue a stored session in this sitting.

  Bare, it lists this directory's sessions, most recently active first —
  the ones a person in this repository is most likely looking for — and
  `all` lists every stored session. With an id or a name it switches, once
  the turn is over: a resume mid-turn would abandon the work under it.
  Performed by the front end, which owns the callbacks that list and start
  sessions.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "resume",
      description: "continue a stored session (all lists every directory's)",
      accepts_arguments?: true,
      action: :resume_status,
      actions: [:resume_status, {:resume_list, :all}, {:resume, "SESSION"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse("", _conversation), do: [:resume_status]

  def parse(arguments, conversation) do
    case {String.trim(arguments), conversation} do
      {"", _conversation} ->
        [:resume_status]

      {listing, _conversation} when listing in ["all", "--all"] ->
        [{:resume_list, :all}]

      {_id, %Conversation{busy?: true}} ->
        [{:say, "cancel or wait for this turn before resuming another session"}]

      {id, _conversation} ->
        [{:resume, id}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
