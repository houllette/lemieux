defmodule Lemieux.Conversation.Command.Name do
  @moduledoc """
  `/name [TEXT]`: what this sitting calls the session on screen.

  Does not wait for a turn to end, unlike the setting commands: it changes a
  caption, nothing is sent, and a person who wants to label the thing they
  are watching should not have to stop watching it first. Parsed here so
  both front ends read one grammar and performed by each, because the answer
  belongs to neither the session nor the transcript — a resumed session is
  relabelled by its own id again.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "name",
      description: "relabel this session on screen",
      accepts_arguments?: true,
      action: :name_status,
      actions: [:name_status, {:set_name, "TEXT"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(name, _conversation), do: Command.argued(name, :name_status, :set_name)

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
