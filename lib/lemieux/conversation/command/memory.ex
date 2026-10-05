defmodule Lemieux.Conversation.Command.Memory do
  @moduledoc """
  `/memory [--project] TEXT`: remember something for every later session.

  Appends one dated line to a `MEMORY.md` through
  `Lemieux.Extensions.Workspace.Memory`: the person's own
  (`~/.lmx/MEMORY.md`) by default, the repository's with `--project`.
  Workspace discovery reads both into every session's prompt, so the entry
  takes effect from the next session; this one is told now, ahead of the
  next message, so that "remember we use tabs" is not ignored for the rest
  of the sitting. Bare, it says where the two files are.

  Memory is the person's line, not a task for the model: the agent's file
  tools cannot reach `~/.lmx`, and asking it to edit a file it may never have
  read is a slower, less reliable way to append a sentence.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Command.Init
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Extensions.Workspace.Memory

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "memory",
      description: "remember something for later sessions ([--project] TEXT)",
      accepts_arguments?: true,
      action: {:memory, :personal, "TEXT"}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(arguments, _conversation) do
    case String.split(String.trim(arguments), ~r/\s+/, parts: 2) do
      [""] -> [{:memory, :personal, ""}]
      [flag] when flag in ["--project", "project"] -> [{:memory, :project, ""}]
      [flag, text] when flag in ["--project", "project"] -> [{:memory, :project, text}]
      _personal -> [{:memory, :personal, String.trim(arguments)}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:memory, scope, ""}) do
    Dispatch.say(
      acc,
      host,
      "#{scope} memory: #{path(host, scope)} · /memory TEXT adds to yours, " <>
        "/memory --project TEXT to this repository's"
    )
  end

  def perform(acc, host, {:memory, scope, text}) do
    path = path(host, scope)

    case Memory.append(path, text) do
      :ok -> Dispatch.fold(acc, host, {:memory_saved, path, text})
      {:error, reason} -> Dispatch.say(acc, host, "could not remember that: #{reason}")
    end
  end

  defp path(host, :personal) do
    opts = if host.personal_dir, do: [personal_dir: host.personal_dir], else: []
    Memory.path(:personal, opts)
  end

  defp path(host, :project),
    do: Memory.path(:project, root: host |> Dispatch.cwd() |> Init.project_root())
end
