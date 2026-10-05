defmodule Lemieux.Conversation.Command.Init do
  @moduledoc """
  `/init`: ask the agent to write the repository's `AGENTS.md`.

  An `AGENTS.md` is what every later session reads first, so the cheapest
  improvement to every session in a repository is a good one. The brief is
  `Lemieux.Extensions.Workspace.Init.prompt/1`'s — investigate first, write
  only what a newcomer would get wrong, never commit — and it is sent as an
  ordinary prompt: the work is a visible, cancellable turn under the
  session's own approvals, not a file this command writes.

  Waits for the turn. The conversation is marked busy when the prompt is
  sent (`{:send_prompt, text, note}`), not in the parse, because a host
  policy may still refuse the command after the parse.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Extensions.Workspace.Init

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "init",
      description: "have the agent write this repository's AGENTS.md",
      action: :init
    }

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}), do: Command.wait()
  def parse(_arguments, _conversation), do: [:init]

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, :init),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, :init) do
    root = host |> Dispatch.cwd() |> project_root()

    Dispatch.fold(
      acc,
      host,
      {:send_prompt, Init.prompt(root),
       "asking the agent to write #{Path.join(root, "AGENTS.md")}"}
    )
  end

  @doc """
  The repository root above `cwd`: the nearest directory holding `.git`, or
  `cwd` itself outside a repository. Where an `AGENTS.md` and a project
  `MEMORY.md` belong, rather than the subdirectory a session happens to run in.
  """
  @spec project_root(cwd :: Path.t()) :: Path.t()
  def project_root(cwd) when is_binary(cwd) do
    cwd
    |> Path.expand()
    |> ancestors()
    |> Enum.find(cwd, &File.exists?(Path.join(&1, ".git")))
  end

  defp ancestors(path) do
    case Path.dirname(path) do
      ^path -> [path]
      parent -> [path | ancestors(parent)]
    end
  end
end
