defmodule Lemieux.Conversation.Command.Permissions do
  @moduledoc """
  `/permissions [MODE | allow RULE | forget RULE]`: what the agent may do
  without asking.

  Reads and changes the `Lemieux.Extensions.Permissions` handle the host
  applied. Bare, it says the mode, the modes there are, and the rules this
  repository remembers. With a mode it switches — from the next tool call,
  mid-turn included, because the handle is what every decision reads. `allow`
  remembers a rule the way "always allow" on an approval card does, and
  `forget` drops one.

  A host that applied no permission policy has no handle, and the command
  says how to turn one on rather than pretending to switch a mode nothing
  reads.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Extensions.Permissions

  @usage "usage: /permissions [ask | accept-edits | auto | full-auto | read-only | " <>
           "allow RULE | forget RULE]"

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "permissions",
      description: "show or change what the agent may do without asking",
      accepts_arguments?: true,
      action: :permissions_status,
      actions: [
        :permissions_status,
        {:set_permission_mode, "MODE"},
        {:remember_permission, "RULE"},
        {:forget_permission, "RULE"}
      ],
      subcommands: [
        {"MODE", {:set_permission_mode, "MODE"}},
        {"allow RULE", {:remember_permission, "RULE"}},
        {"forget RULE", {:forget_permission, "RULE"}}
      ]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(arguments, _conversation) do
    case String.split(String.trim(arguments), ~r/\s+/, parts: 2, trim: true) do
      [] -> [:permissions_status]
      ["allow", rule] -> [{:remember_permission, String.trim(rule)}]
      ["forget", rule] -> [{:forget_permission, String.trim(rule)}]
      [mode] -> [{:set_permission_mode, mode_name(mode)}]
      _other -> [{:say, @usage}]
    end
  end

  # `accept-edits` is what a person types; the handle reads `accept_edits`,
  # and Claude Code's own names (`acceptEdits`, `plan`) pass through for it
  # to recognise.
  defp mode_name(mode), do: String.replace(mode, "-", "_")

  @impl Lemieux.Conversation.Command
  # The command the person can actually run comes first: a flag for the next
  # start, then the setting that makes it the default. Naming only the config
  # key sent people to edit a file to try a mode once.
  def perform(acc, %Dispatch{permissions: nil} = host, _effect) do
    Dispatch.say(
      acc,
      host,
      "permissions are off in this session: every tool call runs without asking · " <>
        "start lmx with --permission-mode ask to be asked first, or set \"permissions\" " <>
        "in ~/.lmx/config.json to make it the default"
    )
  end

  def perform(acc, host, :permissions_status),
    do: Dispatch.say(acc, host, status(host.permissions))

  def perform(acc, host, {:set_permission_mode, mode}) do
    case Permissions.set_mode(host.permissions, mode) do
      :ok ->
        label = host.permissions |> Permissions.mode() |> Permissions.label()
        Dispatch.say(acc, host, "permissions: #{label}, from the next tool call")

      {:error, reason} ->
        Dispatch.say(acc, host, reason <> " · " <> @usage)
    end
  end

  def perform(acc, host, {:remember_permission, rule}) do
    case Permissions.remember(host.permissions, rule) do
      :ok -> Dispatch.say(acc, host, "always allowed in this repository: #{rule}")
      {:error, reason} -> Dispatch.say(acc, host, "could not remember #{rule}: #{reason}")
    end
  end

  def perform(acc, host, {:forget_permission, rule}) do
    case Permissions.forget(host.permissions, rule) do
      :ok -> Dispatch.say(acc, host, "no longer always allowed: #{rule}")
      {:error, reason} -> Dispatch.say(acc, host, "could not forget #{rule}: #{reason}")
    end
  end

  @doc "What the bare command says about `handle`."
  @spec status(handle :: Permissions.Handle.t()) :: String.t()
  def status(handle) do
    current = Permissions.mode(handle)

    modes =
      Enum.map_join(Permissions.modes(), " · ", fn mode ->
        label = mode |> Permissions.label() |> String.replace(" ", "-")
        if mode == current, do: "[#{label}]", else: label
      end)

    remembered =
      case Permissions.remembered(handle) do
        [] -> "nothing is always allowed yet"
        rules -> "always allowed: " <> Enum.join(rules, ", ")
      end

    "permissions: #{Permissions.label(current)}\nmodes: #{modes}\n#{remembered}\n" <> @usage
  end
end
