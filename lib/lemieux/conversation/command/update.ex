defmodule Lemieux.Conversation.Command.Update do
  @moduledoc "The host's `/update` action for installed releases and source checkouts."
  alias Lemieux.Conversation.Command

  @behaviour Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "update",
      description: "update the installed release or source checkout",
      action: :update
    }

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:update]

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
