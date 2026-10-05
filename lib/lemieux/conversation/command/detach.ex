defmodule Lemieux.Conversation.Command.Detach do
  @moduledoc """
  `/detach`: Elixir evaluation goes back to the session's own node.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Eval

  @impl Lemieux.Conversation.Command
  def spec, do: %{name: "detach", description: "use this session's node", action: :detach}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:detach]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :detach) do
    :ok = Eval.detach(host.session)

    Dispatch.say(acc, host, "back on this session's own node")
  end
end
