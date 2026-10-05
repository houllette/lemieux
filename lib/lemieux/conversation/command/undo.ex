defmodule Lemieux.Conversation.Command.Undo do
  @moduledoc """
  `/undo [--force]`: put back the files the agent changed in its last turn.

  Reads the checkpoints `Lemieux.Extensions.Checkpoints` recorded, through
  `Lemieux.Checkpoint.undo/3`, and writes through the session's environment
  as the tools did. A file changed since the agent wrote it — by the person,
  by a later command — is left alone and named, because an undo that
  overwrote somebody's own edit to put back the agent's older one would be
  the worst thing it could do; `--force` puts it back anyway.

  ## Saying what was not done

  The report names what it put back and, in the same line, what it could
  not: files it saw change but never saved (ignored by git, too large),
  files it put back that an earlier command may also have changed unseen,
  commands it could not record (no git repository, a command that never
  finished), tools it cannot see into, and branch moves it does not undo.
  The old answer to a turn whose only change was a command run outside a
  git repository was "nothing to undo · only file changes the agent made in
  this session are kept", which a person whose file had just been deleted
  read as "the agent changed nothing". A turn with nothing to put back is
  now answered as that turn, with what it did and could not undo, and the
  hint to `/undo` again for the turn before — never by quietly undoing the
  turn before instead.

  When files were left alone, the line says what each way on does:
  `/undo --force` puts *those* back (`Lemieux.Checkpoint.undo/3` finishes
  the undo whose report offered it), and `/undo` again keeps them and
  undoes the turn before. Following the old "`/undo --force` puts them back
  anyway" force-undid the turn before and left the named files as they were.

  Waits for the turn: undoing under a turn that is still writing would put
  files back only for the agent to change them again. The conversation is
  not rewound — the transcript is append-only — so the model is told what was
  put back, ahead of the next message (see `describe/1` and `note/1`).
  `/redo` (`Lemieux.Conversation.Command.Redo`) takes an undo back.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Checkpoint
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch

  @impl Lemieux.Conversation.Command
  def spec do
    %{
      name: "undo",
      description: "put back the files the agent changed last turn",
      accepts_arguments?: true,
      action: {:undo, false}
    }
  end

  @impl Lemieux.Conversation.Command
  def parse(_arguments, %Conversation{busy?: true}),
    do: Command.wait("wait for the turn to finish, or /cancel it, before undoing")

  def parse(arguments, _conversation) do
    case String.trim(arguments) do
      "" -> [{:undo, false}]
      flag when flag in ["--force", "force"] -> [{:undo, true}]
      _other -> [{:say, "usage: /undo [--force]"}]
    end
  end

  @impl Lemieux.Conversation.Command
  def perform(acc, %Dispatch{checkpoints: nil} = host, _effect),
    do: Dispatch.say(acc, host, off())

  def perform(acc, host, {:undo, force?}) do
    %{checkpoints: store, id: id} = host
    environment = Dispatch.environment(host)

    Dispatch.run(acc, host, fn ->
      {:undo_result, Checkpoint.undo(store, id, environment: environment, force: force?)}
    end)
  end

  @doc false
  @spec off() :: String.t()
  def off,
    do:
      "no checkpoints are recorded in this session, so there is nothing to put back · " <>
        "git can show what changed in the files it tracks (/diff)"

  @doc """
  What `/undo` says when there is no turn left to undo.
  """
  @spec nothing() :: String.t()
  def nothing,
    do:
      "nothing to undo · every turn recorded in this session is already undone, " <>
        "or none recorded a change"

  @doc """
  What `/undo` says when the checkpoint store could not be written, so
  nothing was ever recorded.
  """
  @spec unwritable(path :: Path.t()) :: String.t()
  def unwritable(path),
    do:
      "nothing to undo · checkpoints could not be written to #{display(path)}, so nothing " <>
        "this session changed was recorded · make that directory writable to record the next turn"

  @doc """
  What `/undo` says when a command stopped a moment ago is still being
  recorded: undoing now would miss its changes for good.
  """
  @spec still_recording() :: String.t()
  def still_recording,
    do: "not undone yet · a command you stopped is still being recorded · /undo again in a moment"

  # How many names a list shows before it says how many more there are: a
  # turn that created 2,000 files printed one line naming all of them.
  @shown 10
  @shown_subjects 3

  @doc """
  What one undone (or redone) turn did, as a person reads it: what was put
  back, what was left alone and why, what the turn did that undo does not
  reverse, and — when nothing was put back — the turn another `/undo` would
  take.
  """
  @spec describe(report :: Checkpoint.report()) :: String.t()
  def describe(%{turn: turn} = report) do
    put_back? = report.restored != [] or report.deleted != []
    action = Map.get(report, :action, :undo)

    [
      headline(action, turn, put_back?, quiet(report)),
      listed("restored", report.restored),
      listed("deleted", report.deleted),
      problems("may still differ from before the turn", Map.get(report, :uncertain, [])),
      problems("left alone", report.conflicts),
      problems("could not restore", report.unrestorable)
      | not_undone(Map.get(report, :not_undone, []))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> Kernel.<>(hints(action, report, put_back?))
    |> display()
  end

  # `:loud` when the report names a problem or something not undone; else
  # `:commands` when commands ran — whose changes beyond what undo records the
  # headline then has to mention — or `:files` when only file tools did.
  defp quiet(report) do
    cond do
      report.conflicts != [] or report.unrestorable != [] -> :loud
      Map.get(report, :not_undone, []) != [] -> :loud
      Map.get(report, :commands?, false) -> :commands
      true -> :files
    end
  end

  defp headline(:redo, turn, true, _quiet), do: "redid turn #{turn}"
  defp headline(:redo, turn, false, :loud), do: "turn #{turn}: nothing redone"

  defp headline(:redo, turn, false, _quiet),
    do: "turn #{turn}: nothing to redo · its files are already as the undo found them"

  defp headline(:undo, turn, true, _quiet), do: "undid turn #{turn}"
  defp headline(:undo, turn, false, :loud), do: "turn #{turn}: nothing put back"

  defp headline(:undo, turn, false, :files),
    do: "turn #{turn}: nothing to put back · the files it recorded are as they were before it"

  defp headline(:undo, turn, false, :commands),
    do:
      "turn #{turn} changed no file undo records, so nothing was put back (what commands " <>
        "change in ignored files and outside the working directory is not recorded)"

  defp listed(_verb, []), do: nil

  defp listed(verb, paths) do
    {shown, rest} = Enum.split(paths, @shown)
    "#{verb} #{Enum.join(shown, ", ")}" <> more(length(rest))
  end

  defp more(0), do: ""
  defp more(count), do: " and #{count} more"

  defp problems(_verb, []), do: nil

  defp problems(verb, problems) do
    {shown, rest} = Enum.split(problems, @shown)

    "#{verb}: " <> Enum.map_join(shown, ", ", &"#{&1.path} (#{&1.reason})") <> more(length(rest))
  end

  # A file name is bytes, and so is a branch name; a screen takes text. What
  # cannot be shown as it is is shown with a replacement character rather
  # than handed to a renderer that expects UTF-8.
  defp display(name), do: if(String.valid?(name), do: name, else: String.replace_invalid(name))

  # One line per reason, naming everything it applies to, so ten commands run
  # outside a repository read as one sentence and not ten.
  defp not_undone(items) do
    items
    |> Enum.group_by(& &1.reason, & &1.subject)
    |> Enum.sort_by(fn {reason, _subjects} -> Enum.find_index(items, &(&1.reason == reason)) end)
    |> Enum.map(fn {reason, subjects} ->
      {shown, rest} = subjects |> Enum.uniq() |> Enum.split(@shown_subjects)
      "not undone: #{Enum.join(shown, ", ")}#{more(length(rest))} — #{reason}"
    end)
  end

  # What each way on does. Left-alone files first: `--force` acts on those,
  # and a plain `/undo` keeps them and moves to the turn before. A report
  # that is not the last of a rewind (`last?: false`) offers neither: the
  # undos after it have moved on.
  defp hints(_action, %{last?: false}, _put_back?), do: ""

  defp hints(:redo, %{conflicts: [_ | _]}, _put_back?),
    do: " · /redo --force puts them back anyway"

  defp hints(:redo, _report, _put_back?), do: ""

  defp hints(:undo, %{conflicts: [_ | _]} = report, _put_back?) do
    case Map.get(report, :next) do
      next when is_integer(next) ->
        " · /undo --force puts them back anyway · /undo again keeps them and undoes turn #{next}"

      _none ->
        " · /undo --force puts them back anyway"
    end
  end

  defp hints(:undo, %{next: next}, false) when is_integer(next),
    do: " · /undo again to undo turn #{next}"

  defp hints(:undo, _report, _put_back?), do: ""

  @doc """
  What the model is told before the next message, or `nil` when nothing was
  put back: its own context still describes the edits it made.
  """
  @spec note(reports :: [Checkpoint.report()]) :: String.t() | nil
  def note(reports) when is_list(reports) do
    uncertain = reports |> Enum.flat_map(&Map.get(&1, :uncertain, [])) |> MapSet.new(& &1.path)
    {partly, restored} = reports |> Enum.flat_map(& &1.restored) |> split(uncertain)
    {partly_deleted, deleted} = reports |> Enum.flat_map(& &1.deleted) |> split(uncertain)
    partly = partly ++ partly_deleted
    redo? = Enum.any?(reports, &(Map.get(&1, :action) == :redo))

    case {restored, deleted, partly} do
      {[], [], []} ->
        nil

      _changed ->
        turns = reports |> Enum.map(& &1.turn) |> Enum.sort() |> Enum.map_join(", ", &to_string/1)

        [
          opening(redo?, turns),
          if(restored != [], do: "#{put_back(redo?)}: #{names(restored)}."),
          if(deleted != [], do: "#{removed(redo?)}: #{names(deleted)}."),
          if(partly != [],
            do:
              "Put back as they were before your file edits, though a command may have " <>
                "changed them before that: #{names(partly)}."
          ),
          "Read a file again before relying on what you remember of it.]"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> display()
    end
  end

  defp split(paths, uncertain), do: Enum.split_with(paths, &MapSet.member?(uncertain, &1))
  defp names(paths), do: Enum.join(paths, ", ")

  defp opening(false, turns), do: "[The person undid your file changes from turn #{turns}."

  defp opening(true, turns),
    do: "[The person took back their undo of your file changes from turn #{turns}."

  defp put_back(false), do: "Put back as they were before"
  defp put_back(true), do: "As you had left them again"

  defp removed(false), do: "Removed again (you had created them)"
  defp removed(true), do: "Removed again (the undo had brought them back)"
end
