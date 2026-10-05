defmodule Lemieux.Conversation.Command.Color do
  @moduledoc """
  `/color [COLOUR]`, `/colour`: the accent the screen draws.

  `color` is the listed name because it is the spelling most people reach
  for at a prompt; this codebase spells the thing itself `colour` everywhere,
  so the alias exists to make neither of them wrong. Mid-turn is fine, for
  the reason `/name` gives; performed by the front end, which is the only
  thing with an accent to change.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "color",
      aliases: ["colour"],
      description: "recolour this screen's accents",
      accepts_arguments?: true,
      action: :colour_status,
      actions: [:colour_status, {:set_colour, "COLOUR"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(colour, _conversation), do: Command.argued(colour, :colour_status, :set_colour)

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
