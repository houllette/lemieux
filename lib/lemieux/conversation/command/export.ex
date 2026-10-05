defmodule Lemieux.Conversation.Command.Export do
  @moduledoc """
  `/export [PATH]`: the conversation as Markdown, in a file.

  For sharing what happened with somebody who was not there — a pull request
  description, an issue, a note to self — which the JSONL transcript is not
  for: it is complete and exact, and unreadable as prose.
  `Lemieux.Conversation.Export` renders it; this writes it.

  A bare `/export` writes a new file under the host's export directory
  (`~/.lmx/exports` unless the host says otherwise) rather than into the
  working directory: an export is the person's artefact, and one dropped in
  the repository shows up as an untracked file in the next `git status` the
  agent reads. A named path is relative to the working directory. An existing
  file is never replaced — an export that silently overwrote the notes a
  person had open would be the one data loss in a read-only command.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Conversation.Export
  alias Lemieux.ID.Shorthand
  alias Lemieux.Session

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "export",
      description: "write this conversation to a Markdown file",
      accepts_arguments?: true,
      action: {:export, nil}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(path, _conversation) do
    case String.trim(path) do
      "" -> [{:export, nil}]
      path -> [{:export, path}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{session: nil} = host, {:export, _path}),
    do: Dispatch.say(acc, host, "nothing to export yet")

  def perform(acc, host, {:export, path}) do
    Dispatch.run(acc, host, fn -> {:export_result, export(host, path)} end)
  end

  defp export(host, path) do
    snapshot = Session.snapshot(host.session)
    target = target(host, snapshot, path)

    with :ok <- absent(target),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(target, Export.markdown(snapshot), [:exclusive]) do
      {:ok, target}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "#{target}: #{:file.format_error(reason)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp target(host, snapshot, nil) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    name = "#{Shorthand.of(snapshot.id)}-#{stamp}.md"

    Path.join(host.export_dir || Path.expand("~/.lmx/exports"), name)
  end

  defp target(host, _snapshot, path), do: Path.expand(path, Dispatch.cwd(host))

  defp absent(target) do
    if File.exists?(target),
      do: {:error, "#{target} already exists · name another file"},
      else: :ok
  end
end
