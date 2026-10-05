defmodule Lemieux.Conversation.Command.Elixir do
  @moduledoc """
  `/elixir`: toggle the focused Elixir tool profile.

  Waits for the turn, because it swaps the catalog the next request is built
  from. Performed by the front end, which holds the standard catalog to
  swap back to and the `delegate` tool the swap must carry on — see
  `Lemieux.TUI`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "elixir",
      description: "toggle focused Elixir tool mode",
      action: :toggle_elixir_mode
    }

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:toggle_elixir_mode]

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
