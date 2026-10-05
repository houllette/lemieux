defmodule Lemieux.Conversation.Command.Refresh do
  @moduledoc """
  `/refresh`: re-read every file the conversation attached.

  Hidden from the list and still typeable: the full screen re-attaches
  changed files by itself when somebody types `@`, so listing a command
  would ask a person to remember to do the harness's job. It stays for
  hosts that want to request a refresh explicitly. The files may live behind an environment that is not this
  machine, so the read goes through the host's `:run`.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "refresh",
      description: "re-read the files this conversation attached",
      action: :refresh,
      hidden?: true
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:refresh]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :refresh) do
    session = host.session

    Dispatch.run(acc, host, fn -> {:refresh_result, Session.refresh(session)} end)
  end
end
