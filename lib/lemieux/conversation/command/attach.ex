defmodule Lemieux.Conversation.Command.Attach do
  @moduledoc """
  `/attach [NODE]`: evaluate Elixir inside a running application.

  With nothing after it, it lists rather than guessing. Picking a node for
  somebody would be picking which running application to let the model
  inside, which is the one decision here that has to stay theirs — see
  `Lemieux.Eval.Attach`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Eval
  alias Lemieux.Eval.Attach

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "attach",
      description: "evaluate inside a running app",
      accepts_arguments?: true,
      action: {:attach, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(target, _conversation) do
    case String.trim(target) do
      "" -> [{:attach, nil}]
      target -> [{:attach, target}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:attach, nil}), do: Dispatch.say(acc, host, Attach.offer())

  def perform(acc, host, {:attach, target}),
    do: Dispatch.say(acc, host, Attach.said(Eval.attach(host.session, target)))
end
