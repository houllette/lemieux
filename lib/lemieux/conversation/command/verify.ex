defmodule Lemieux.Conversation.Command.Verify do
  @moduledoc """
  `/verify [on | off]`: whether the project's own check runs after the agent
  edits files, and how the last one went.

  Reads and flips `Lemieux.Extensions.Verify`'s runtime switch, which lives
  in a session document so it survives resume and applies from the next
  time the agent stops. A session the extension was not applied to has no
  check to run, and says so rather than flipping a switch nothing reads —
  which is why the status asks the session which extensions shaped it.
  Allowed mid-turn: the switch is read when the turn ends.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Extensions.Verify
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "verify",
      description: "check the project after the agent edits files (on/off)",
      accepts_arguments?: true,
      action: :verify_status,
      actions: [:verify_status, {:set_verify, true}],
      subcommands: [{"on | off", {:set_verify, true}}]
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(arguments, _conversation) do
    case String.downcase(String.trim(arguments)) do
      "" -> [:verify_status]
      "status" -> [:verify_status]
      "on" -> [{:set_verify, true}]
      "off" -> [{:set_verify, false}]
      _other -> [{:say, "usage: /verify [on | off]"}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, _effect),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, :verify_status) do
    session = host.session
    Dispatch.run(acc, host, fn -> {:said, status(session)} end)
  end

  def perform(acc, host, {:set_verify, enabled?}) do
    session = host.session

    Dispatch.run(acc, host, fn ->
      {:said,
       if applied?(session) do
         case Verify.set_enabled(session, enabled?) do
           {:ok, _document} -> switched(enabled?)
           {:error, reason} -> "could not change verify: #{inspect(reason)}"
         end
       else
         not_applied()
       end}
    end)
  end

  defp switched(true), do: "verify on · the project's check runs after the agent edits files"
  defp switched(false), do: "verify off · the agent's edits are not checked automatically"

  defp status(session) do
    if applied?(session) do
      case Verify.status(session) do
        {:ok, %{enabled: enabled, last: last}} -> "verify: #{state(enabled)}" <> last_check(last)
        {:error, reason} -> "could not read verify: #{inspect(reason)}"
      end
    else
      not_applied()
    end
  end

  defp state(false), do: "off"
  defp state(_on_or_default), do: "on"

  defp last_check(nil), do: " · nothing checked yet"

  defp last_check(%{} = last) do
    command = last["command"] || "the check"
    " · last: #{command} #{last["status"] || "ran"}" <> duration(last["duration_ms"])
  end

  defp duration(ms) when is_integer(ms), do: " (#{Float.round(ms / 1000, 1)}s)"
  defp duration(_ms), do: ""

  defp not_applied,
    do:
      "verify is not part of this session · turn it on with \"verify\" in ~/.lmx/config.json, " <>
        "then start a new session"

  # Asked of the harness context the session was started with: the one
  # account of which extensions shaped it, there from the first moment (the
  # per-request harness snapshot is not written until a request is). Reading
  # it copies the transcript, which is why this runs off the host's draw loop.
  defp applied?(session) do
    session
    |> Session.snapshot(10_000)
    |> Map.get(:harness_context, %{})
    |> get_in(["extensions", "applied"])
    |> List.wrap()
    |> Enum.any?(&(&1["module"] == "Lemieux.Extensions.Verify"))
  end
end
