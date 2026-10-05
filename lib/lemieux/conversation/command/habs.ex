defmodule Lemieux.Conversation.Command.Habs do
  @moduledoc """
  `/habs`: hidden, and the front end's to draw.

  Deliberately absent from `/help` and the completion menu — a listed easter
  egg is a feature request — and still a command here so hosts can handle it.
  """

  @behaviour Lemieux.Conversation.Command

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "habs", description: "go habs go", action: :habs, hidden?: true}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:habs]

  @impl Lemieux.Conversation.Command
  def perform(acc, _host, _effect), do: acc
end
