defmodule Lemieux.Conversation.Command.Copy do
  @moduledoc """
  `/copy [source]`: the latest agent response, to the host's clipboard.

  A TUI host projects bare copy into rendered visualizations; `source` keeps
  the original text. Other hosts always receive the original transcript text.

  The wording of each failure lives here once. Before the shared
  dispatcher, the screen and the prompt each had their own copy and they
  disagreed.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Session
  alias Lemieux.Transcript

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{
      name: "copy",
      description: "copy the latest agent response; source keeps visualization source",
      action: :copy,
      actions: [{:copy, :source}],
      accepts_arguments?: true,
      subcommands: [{"source", :copy}]
    }

  @impl Lemieux.Conversation.Command
  def parse(arguments, _conversation) do
    case String.trim(arguments) do
      "" -> [:copy]
      "source" -> [{:copy, :source}]
      _unknown -> [{:say, "usage: /copy [source]"}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, host, {:copy, :source}), do: perform(acc, host, :copy)

  def perform(acc, %Dispatch{session: nil} = host, :copy),
    do: Dispatch.say(acc, host, "no agent response to copy")

  def perform(acc, host, :copy) do
    # A host's projection and clipboard transport can both be expensive. Run
    # them through the host's task seam so a diagram never freezes its screen.
    Dispatch.run(acc, host, fn -> {:copy_result, copy(host)} end)
  end

  defp copy(host) do
    with {:ok, text} <-
           host.session
           |> Session.snapshot()
           |> Map.fetch!(:entries)
           |> Transcript.latest_assistant_text(),
         do: clipboard(host, text)
  end

  @doc false
  @spec completed(acc :: Dispatch.acc(), host :: Dispatch.t(), result :: term()) :: Dispatch.acc()
  def completed(acc, host, :ok), do: Dispatch.say(acc, host, "copied the latest agent response")

  def completed(acc, host, {:error, :not_found}),
    do: Dispatch.say(acc, host, "no agent response to copy")

  def completed(acc, host, {:error, :unsupported_transport}),
    do: Dispatch.say(acc, host, "clipboard copy is unavailable for this terminal transport")

  def completed(acc, host, {:error, reason}),
    do: Dispatch.say(acc, host, "could not copy the latest agent response: #{inspect(reason)}")

  def completed(acc, host, other),
    do: Dispatch.say(acc, host, "could not copy the latest agent response: #{inspect(other)}")

  defp clipboard(%Dispatch{clipboard: nil}, _text), do: {:error, :unsupported_transport}
  defp clipboard(%Dispatch{clipboard: copy}, text), do: copy.(text)
end
