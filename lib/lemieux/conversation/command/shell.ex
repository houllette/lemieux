defmodule Lemieux.Conversation.Command.Shell do
  @moduledoc """
  `/shell COMMAND`, and `!COMMAND`: run a command here and share what it
  printed with the next message.

  `!` is how it is usually typed — `Lemieux.Conversation` reads a line that
  starts with one as this command — and `/shell` is the same thing where a
  front end cannot send a leading `!`. Either way it is a command in the
  registry, so a host's `command_policy` can refuse `{:shell, nil}` like any
  other: a host that allows no shell to the model should be able to allow
  none to the person at its keyboard either.

  Run through the session's environment by `Lemieux.Conversation.Shell`,
  off the host's draw loop, and answered as `{:shell_result, command, result}`.
  Allowed mid-turn: looking at something while the agent works is exactly
  when a person wants to.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Conversation.Shell

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "shell",
      description: "run a command here, shared with your next message (or type !command)",
      accepts_arguments?: true,
      action: {:shell, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(command, conversation) do
    case String.trim(command) do
      "" ->
        Conversation.ready_unless_busy(conversation, [
          {:say, "usage: /shell COMMAND, or !COMMAND"}
        ])

      command ->
        [{:shell, command}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:shell, command}) do
    environment = Dispatch.environment(host)

    Dispatch.run(acc, host, fn ->
      {:shell_result, command, Shell.run(environment, command, Dispatch.cwd(host))}
    end)
  end
end
