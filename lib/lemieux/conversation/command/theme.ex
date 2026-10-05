defmodule Lemieux.Conversation.Command.Theme do
  @moduledoc """
  `/theme [NAME]`: the screen's palette, for this sitting.

  Mid-turn is fine, for the reason `/name` gives. Performed by the front
  end: the registry of palettes is the screen's.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "theme",
      description: "switch this screen's palette",
      accepts_arguments?: true,
      action: :theme_status,
      actions: [:theme_status, {:set_theme, "NAME"}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(name, _conversation), do: Command.argued(name, :theme_status, :set_theme)

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
