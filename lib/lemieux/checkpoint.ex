defmodule Lemieux.Checkpoint do
  @moduledoc """
  Undo for what an agent did to files: each file's contents saved before a
  tool changed it, git snapshots around each command, grouped by turn, and
  put back on request — with a report that says what was put back and,
  just as plainly, what was not.

  A transcript can be forked at any turn; the files the agent wrote cannot,
  and without this a person who dislikes the last turn has to find and revert
  its changes by hand. `Lemieux.Extensions.Checkpoints` wires the recording
  into a session; a host calls `undo/3`, `rewind/4` or `redo/3` from its
  interface (`/undo`, `/rewind N`, `/redo` in the terminal UI) and `list/2`
  to show what an undo would touch.

  This is the safety net under a host that lets tools run without asking, so
  the rule for every report is the one a person needs: never claim more than
  was done, and never stay quiet about what was seen and could not be done.

  ## Turns

  A turn is everything the agent did between one prompt and the next.
  `begin_turn/2` starts one (the extension calls it from a `user_prompt`
  hook); records made after it belong to it. A turn in which nothing was
  recorded is reused rather than left empty, so turn numbers count turns in
  which the agent did something that could have changed a file — a file
  tool, a command, a tool nothing could see into — whether or not it did.
  A turn with anything in it is never reused, so one prompt's records never
  mix with the next's.

  ## What is recorded

    * **Before a file tool runs**, `capture/4`: the file's contents (or that
      it did not exist), stored once per content in the session's blob
      directory — any file the tool may write, `.env` and other ignored
      files included. A file over `:max_file_bytes` (10 MB) is changed
      without its contents being saved (or read to the end), and undo names
      it as one it could not restore.
    * **After it ran**, `record_after/3`: the digest of what the tool left,
      at any size. This is what makes undo safe: a file whose contents are
      no longer what the agent left has been changed since, by the person or
      by a later command, and is reported as a conflict rather than
      overwritten.
    * **Around each command**, when the working directory is a git
      repository, `snapshot/4`: a git tree of the working tree immediately
      before the command and immediately after it (see
      `Lemieux.Checkpoint.Git` for what a tree holds: tracked files, and
      untracked ones up to 1 MB, the first 2,000 across the whole
      repository). Undo restores the paths that differ between the two.
      What a snapshot leaves out — ignored files such as `.env`, wholly
      ignored directories such as `_build/` (by name only), larger or later
      untracked files — is still listed, up to 2,000 entries, so undo can
      name the ones a command changed even though it cannot put them back.
      `HEAD` and the refs are recorded too, so undo can say when a command
      committed, switched branches or reset; it never moves them back.
    * **What nothing could record**, `mark_unrecorded/4`: a command run
      where there is no git repository, or in a directory its repository
      ignores, a snapshot that failed, a command left running in the
      background, a tool such as an MCP server's whose effects are out of
      sight. Undo reports each one with the turn.

  Not recorded, and not reported unless a host brackets them with
  `around/4`: anything that changes files by other means than the wrapped
  tools — command hooks, a host's own tools — and anything outside the git
  repository a command ran in, such as a file in the home directory. What a
  command changes inside a wholly ignored directory is not seen beyond the
  directory appearing or going. The post-edit check
  (`Lemieux.Extensions.Verify`) brackets itself with `around/4` when it is
  given `:checkpoints`, as `lmx` gives it: what the check changes is then
  recorded with the turn whose edits it checked, and undone with them, as
  far as a command's changes are.

  ## Commands

  Each command has a window of its own — a before-tree and an after-tree,
  one record per call — rather than one before-tree for the turn and an
  after-tree that moves with every command. Under that obvious design, a
  file the person saved while the model was thinking between two commands
  sat inside the turn's window and was "restored" to what it was before
  the turn; a cancelled command stretched one turn's window into the next
  prompt. With a window per command, a change the person makes between the
  agent's commands is theirs: undo takes each file back to what it held just
  before the agent's first change to it in the turn, so a file the agent
  first touched after the person's edit goes back to the person's version.
  A file the agent changed, the person then edited, and the agent changed
  again goes back to before the agent's first change; the person's edit in
  between, already overwritten by the agent, is not brought back. A change
  the person saves *during* a command still cannot be told from the
  command's own, and goes back with it; `redo/3` is the way to get it back.

  A command can end without its after-tree being taken: a cancel or a
  timeout kills the tool task, and the code that would have taken it never
  runs. `snapshot/4` with `watch: pid` starts a process (under the
  context's runtime, when it names one) that waits for the tool task to
  exit and takes the after-tree then, so a cancelled command's changes are
  undone like any other's. Undo waits up to five seconds for such a watcher
  and then answers `{:error, :still_recording}` rather than read a turn
  whose last command is still being recorded — reading it would report that
  command as unrecorded, mark the turn undone, and leave its changes out of
  every later undo. If the VM itself stopped mid-command, nothing can take
  that after-tree: the window stays open, the turn is not reused for the
  next prompt, and undo reports the command as unrecorded rather than
  skipping over it.

  When a command and a file tool change the same path in one turn, the path
  goes back to its state before the earlier of the two — the command's
  before-tree, its listing of a file the tree leaves out, or the file tool's
  capture, ordered by `Lemieux.Checkpoint.Store.seq/0` — and is checked
  against what the later of the two left. A generated file the agent then
  edited is therefore deleted, not "restored" to the generator's output, and
  the same holds for an ignored file: a `.env` a command created and the
  agent then edited is deleted; one a command rewrote before the agent
  edited it is named as unrestorable, since what it held before the command
  was never saved, rather than "restored" to the command's version. A file
  only a command touched in an ignored location is named, never deleted.
  Inside a wholly ignored directory a command's change cannot be seen at
  all, so a file the agent's file tool changed there after a command ran is
  put back as the file tool found it, and the report says it may still
  differ from before the turn (`uncertain`).

  ## Undoing

  `undo/3` reverts the most recent turn not already undone, file by file,
  and returns what it restored, deleted, refused (`conflicts`), could not
  restore (`unrestorable`: a file too large to have been saved, a snapshot
  whose objects `git gc` has since removed, a file a command changed that
  no snapshot saved, a path outside the working directory), put back but
  cannot vouch for (`uncertain`, above) and what the turn did that undo
  does not reverse (`not_undone`: commands it could not record, moved
  refs). It never stops at the first conflict: the other files of the turn
  are still put back, and the report says which ones were not.

  `force: true` restores over conflicts. When the last undo left files
  alone and no turn has recorded anything since, `force: true` finishes
  *that* undo — the files its report named — rather than undoing the turn
  before it with force, which is what the report's "`/undo --force` puts
  them back" means to a person reading it. Otherwise it undoes the next
  turn, overwriting what changed since.

  A turn that recorded something but has nothing undo can put back — only
  unrecorded commands, say — is still the turn `/undo` answers about: it is
  reported and marked undone, and the report's `next` names the turn a
  second `undo/3` would take. The alternative, skipping to the newest turn
  with something restorable, undid the turn before a cancelled command and
  called that the undo the person asked for.

  `redo/3` puts back what the most recent undo replaced — saved before the
  undo wrote anything — with the same conflict check, so an undo that took
  away the person's own edit can itself be taken back. A redo that put
  nothing back because everything had changed since leaves the undo where
  it is; `force: true` then, or after a redo that put back only some files,
  acts on the files that redo named. A forced redo keeps what it
  overwrote in the store, since nothing else holds it.

  ## Where files are, and what "confined" means

  Files are read and written through the session's environment, as the
  tools did, so undo reaches the same files in a container or a sandbox. Git
  snapshots and restores run on this machine, outside any sandbox, in a
  repository the session's commands can write — so they run git in a git
  directory of their own, and nothing the repository configures (a hook,
  `core.fsmonitor`, a filter driver) runs; see `Lemieux.Checkpoint.Git`.

  Confinement is by path: a path outside the working directory — through
  `..`, an absolute path or a symbolic link — is refused, but a hard link
  inside the tree to a file elsewhere is the same file, so writing it writes
  through, and undo puts the shared file back the same way.

  Nothing is stored in the working directory; `store` is a directory of the
  host's choosing, `~/.lmx/checkpoints` for `lmx`. Git's private directories
  are made there too, under each session's `git/`, while a snapshot or an
  undo runs, so `store` must be out of the session's commands' reach: a
  command that could write it could configure the git that runs here (`lmx`'s
  is inside `~/.lmx`, which `--sandbox` hides). It keeps every saved
  pre-image, `.env` contents included, what each undo replaced and what a
  forced redo overwrote, until `forget/2` deletes the session or somebody
  deletes the directory; nothing prunes it. Snapshots also leave
  unreferenced objects in the repository's own `.git/objects` until `git gc`
  prunes them.
  """

  alias Lemieux.Checkpoint.Files
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Checkpoint.Undo
  alias Lemieux.Checkpoint.Window
  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Tools.Search.Scope

  @subject_length 60

  @typedoc "The directory checkpoints are kept in."
  @type store :: Path.t()

  @typedoc "A turn number, counting from 1."
  @type turn :: pos_integer()

  @typedoc "What a tool context supplies: where the session works and who it is."
  @type context :: %{
          required(:cwd) => Path.t(),
          required(:session_id) => String.t(),
          optional(:environment) => Environment.t(),
          optional(:call_id) => String.t(),
          optional(atom()) => term()
        }

  @typedoc "One turn that can be undone, for a listing."
  @type summary :: %{
          turn: turn(),
          files: [String.t()],
          snapshot?: boolean(),
          undone?: boolean(),
          at: String.t() | nil
        }

  @typedoc "A file undo left alone, and why."
  @type problem :: %{path: String.t(), reason: String.t()}

  @typedoc """
  Something a turn did that undo did not reverse — a command it could not
  record, a branch it does not move back — and why. `subject` is written
  for a person: a command in backticks, a tool's name, `HEAD`.
  """
  @type not_undone :: %{subject: String.t(), reason: String.t()}

  @typedoc """
  What undoing (or redoing) one turn did. `uncertain` names restored or
  deleted paths that may still differ from before the turn, and why; `next`
  is the turn another undo would take, `nil` when none is left; `commands?`
  says whether anything but the file tools ran in the turn, so a host can
  tell "it changed nothing" from "nothing undo records changed". A path is
  a file name as the file system has it, which need not be valid UTF-8.
  """
  @type report :: %{
          required(:turn) => turn(),
          required(:restored) => [String.t()],
          required(:deleted) => [String.t()],
          required(:conflicts) => [problem()],
          required(:unrestorable) => [problem()],
          optional(:uncertain) => [problem()],
          optional(:not_undone) => [not_undone()],
          optional(:action) => :undo | :redo,
          optional(:commands?) => boolean(),
          optional(:next) => turn() | nil
        }

  ## Recording

  @doc """
  Starts a turn for `session_id`, returning its number.

  A current turn in which nothing was recorded is returned instead of a new
  one. A turn with anything in it — a capture, a command's window even if it
  never closed, a note of something unrecorded — is never reused, so one
  prompt's records never mix with the next's.
  """
  @spec begin_turn(store :: store(), session_id :: String.t()) :: {:ok, turn()} | {:error, term()}
  def begin_turn(store, session_id) do
    with {:ok, session} <- Store.session_dir(store, session_id) do
      current = Store.current(session)

      if current > 0 and empty?(session, current),
        do: {:ok, current},
        else: put_turn(session, current + 1)
    end
  end

  @doc """
  Saves `path`'s current contents (relative to `context.cwd`) before a tool
  changes it.

  Options: `:tool`, the tool's name, recorded for the listing;
  `:max_file_bytes` (default 10 MB), above which the contents are not saved
  and the file is reported as unrestorable rather than silently skipped.
  """
  @spec capture(store :: store(), context :: context(), path :: String.t(), opts :: keyword()) ::
          :ok | {:error, term()}
  def capture(store, context, path, opts \\ []) do
    with {:ok, session} <- Store.session_dir(store, context.session_id),
         {:ok, relative} <- relative(context.cwd, path),
         {:ok, turn} <- ensure_turn(session) do
      environment = environment(context)
      before = Files.observe(session, environment, context.cwd, relative, opts, true)

      record = %{
        "version" => 1,
        "turn" => turn,
        "call_id" => Map.get(context, :call_id),
        "tool" => opts |> Keyword.get(:tool) |> nullable_string(),
        "cwd" => context.cwd,
        "path" => relative,
        "before" => before,
        "created_from" => created_from(environment, context.cwd, relative, before),
        "seq" => Store.seq(),
        "at" => now()
      }

      Store.put_json(
        Path.join([Store.turn_dir(session, turn), "captures", Store.id() <> ".json"]),
        record
      )
    end
  end

  @doc """
  Records what a tool left `path` as, once it has run.

  Undo compares the file with this before restoring it, so a change made
  after the agent's is never overwritten.
  """
  @spec record_after(store :: store(), context :: context(), path :: String.t()) ::
          :ok | {:error, term()}
  def record_after(store, context, path) do
    with {:ok, session} <- Store.session_dir(store, context.session_id),
         {:ok, relative} <- relative(context.cwd, path),
         {:ok, turn} <- ensure_turn(session) do
      call_id = Map.get(context, :call_id)
      state = Files.observe(session, environment(context), context.cwd, relative, [], false)

      record = %{
        "call_id" => call_id,
        "cwd" => context.cwd,
        "path" => relative,
        "after" => state,
        "seq" => Store.seq(),
        "at" => now()
      }

      key = Store.key(call_id, context.cwd, relative)
      Store.put_json(Path.join([Store.turn_dir(session, turn), "after", key <> ".json"]), record)
    end
  end

  @doc """
  Brackets one command with git trees of the working directory: `:before`
  immediately ahead of it, `:after` once it has finished.

  Each call (`context.call_id`) gets a window of its own in the turn that was
  current at `:before`; a second `:before` for the same call keeps the
  first tree, and `:after` replaces any earlier after-tree. Without a call
  id, every command of the turn shares one window. `:after` with no window
  to close — the `:before` was skipped — is `:skipped` and takes no
  snapshot.

  `:skipped` when the working directory is not a git work tree on this
  machine. That, and a snapshot that fails, is also recorded with the turn
  (see `mark_unrecorded/4`), so undo can say a command ran that it could
  not see.

  Options:

    * `:watch` — a process (the tool task) whose exit takes the
      after-tree if `:after` never comes: a cancelled or timed-out command
      is killed before it can. See "Commands" in the moduledoc.
    * `:subject` — how a report names what ran, such as the command in
      backticks. Defaults to `"a command"`.
    * `:key` — the window to use instead of the call's own.
    * `Lemieux.Checkpoint.Git.snapshot/2`'s `:max_untracked_bytes` and
      `:max_untracked_files`.
  """
  @spec snapshot(
          store :: store(),
          context :: context(),
          which :: :before | :after,
          opts :: keyword()
        ) :: :ok | :skipped | {:error, term()}
  def snapshot(store, context, which, opts \\ [])

  def snapshot(store, context, :before, opts) do
    with {:ok, session} <- Store.session_dir(store, context.session_id),
         {:ok, turn} <- ensure_turn(session) do
      opts = Keyword.put(opts, :scratch, Store.scratch(session))
      path = Window.path(Store.turn_dir(session, turn), window_key(context, opts))
      subject = Keyword.get(opts, :subject, "a command")
      watch = Keyword.get(opts, :watch)

      meta = %{
        "call_id" => Map.get(context, :call_id),
        "cwd" => context.cwd,
        "subject" => subject,
        "watched" => is_pid(watch)
      }

      path
      |> Window.open(meta, opts)
      |> opened(path, watch, Keyword.put(opts, :supervisor, Map.get(context, :supervisor)))
      |> noted(&note(session, turn, context, subject, &1))
    end
  end

  def snapshot(store, context, :after, opts) do
    with {:ok, session} <- Store.session_dir(store, context.session_id) do
      opts = Keyword.put(opts, :scratch, Store.scratch(session))
      close(find_window(session, window_key(context, opts)), opts)
    end
  end

  # The watcher starts once the before-tree is on disk: there is nothing for
  # it to close before that.
  defp opened(:ok, path, watch, opts) when is_pid(watch), do: Window.watch(path, watch, opts)
  defp opened(result, _path, _watch, _opts), do: result

  # A command the turn could not bracket is recorded as unrecorded, so undo
  # can say so instead of answering as if the turn had not run it.
  defp noted(:skipped, note) do
    _ = note.(not_a_repository())
    :skipped
  end

  defp noted({:error, reason} = error, note) do
    _ = note.(snapshot_failed(reason))
    error
  end

  defp noted(result, _note), do: result

  defp close(nil, _opts), do: :skipped
  defp close(path, opts), do: Window.close(path, opts)

  @doc """
  Runs `fun` inside a window of its own, so what it changes in the working
  directory's git repository is undone with the turn — for whatever writes
  files outside the wrapped tools: a check run after edits, a hook, a host's
  own tool. The window is closed when `fun` returns or raises, and by a
  watcher if the calling process is killed first. Options are
  `snapshot/4`'s; `:subject` names it in a report.
  """
  @spec around(store :: store(), context :: context(), fun :: (-> result), opts :: keyword()) ::
          result
        when result: term()
  def around(store, context, fun, opts \\ []) when is_function(fun, 0) do
    opts =
      opts
      |> Keyword.put_new(:key, "around-" <> Store.id())
      |> Keyword.put(:watch, self())

    _ = snapshot(store, context, :before, opts)

    try do
      fun.()
    after
      _ = snapshot(store, context, :after, Keyword.delete(opts, :watch))
    end
  end

  @doc """
  Records with the current turn that something ran whose changes nothing
  recorded — `subject` names it for a person, `reason` says why — so undo
  reports it instead of answering as if the turn had done nothing.
  """
  @spec mark_unrecorded(
          store :: store(),
          context :: context(),
          subject :: String.t(),
          reason :: String.t()
        ) :: :ok | {:error, term()}
  def mark_unrecorded(store, context, subject, reason)
      when is_binary(subject) and is_binary(reason) do
    with {:ok, session} <- Store.session_dir(store, context.session_id),
         {:ok, turn} <- ensure_turn(session) do
      note(session, turn, context, subject, reason)
    end
  end

  @doc """
  How a report names a command: its first line, shortened, in backticks.
  """
  @spec subject(command :: String.t()) :: String.t()
  def subject(command) when is_binary(command) do
    line = command |> String.trim() |> String.split("\n", parts: 2) |> hd()
    more? = String.length(line) > @subject_length or String.contains?(String.trim(command), "\n")
    shown = String.slice(line, 0, @subject_length)
    "`" <> shown <> if(more?, do: "…", else: "") <> "`"
  end

  defp note(session, turn, context, subject, reason) do
    record = %{
      "version" => 1,
      "call_id" => Map.get(context, :call_id),
      "cwd" => context.cwd,
      "subject" => subject,
      "reason" => reason,
      "seq" => Store.seq(),
      "at" => now()
    }

    Store.put_json(
      Path.join([Store.turn_dir(session, turn), "unrecorded", Store.id() <> ".json"]),
      record
    )
  end

  defp not_a_repository,
    do:
      "undo records what commands change only in a git repository, and the working " <>
        "directory is not one"

  defp snapshot_failed(:git_not_found),
    do: "git was not found, so what it changed could not be recorded"

  defp snapshot_failed(:ignored_working_directory),
    do:
      "the working directory is one its git repository ignores, so what commands change " <>
        "in it cannot be recorded"

  defp snapshot_failed(:foreign_work_tree),
    do:
      "the repository's work tree is set to another directory (core.worktree), and undo " <>
        "snapshots only the directory holding .git, so what it changed was not recorded"

  defp snapshot_failed(reason),
    do: "the repository could not be snapshotted around it: #{inspect(reason, limit: 5)}"

  # One window per call, working directory and VM. Commands without a call id
  # share one per turn; a VM's is never another VM's, so a `/retry` after a
  # restart cannot reopen the window a stopped run left, nor close it.
  defp window_key(context, opts) do
    Keyword.get_lazy(opts, :key, fn ->
      Store.key("window:#{Map.get(context, :call_id)}", context.cwd, Store.vm())
    end)
  end

  # The open window under `key` this VM began, newest turn first: the one its
  # `:before` went into, even if a new prompt has started another turn since
  # (text sent while a command runs does). Only an open window: a call id a
  # server reuses, or none at all, would otherwise re-close an older turn's
  # window with today's tree, stretching that turn over everything since.
  # Only this VM's: a window a stopped run left open is reported, not closed
  # by a later run's command.
  defp find_window(session, key) do
    vm = Store.vm()

    session
    |> Store.turns()
    |> Enum.reverse()
    |> Enum.map(&Window.path(Store.turn_dir(session, &1), key))
    |> Enum.find(&open_here?(&1, vm))
  end

  defp open_here?(path, vm) do
    case Store.json(path) do
      {:ok, %{"vm" => ^vm} = window} -> Window.open?(window)
      _missing_or_another_vms -> false
    end
  end

  ## Reading

  @doc "The turns that recorded something, newest first."
  @spec list(store :: store(), session_id :: String.t()) :: {:ok, [summary()]} | {:error, term()}
  def list(store, session_id) do
    with {:ok, session} <- Store.session_dir(store, session_id) do
      summaries =
        session
        |> Store.turns()
        |> Enum.reject(&empty?(session, &1))
        |> Enum.map(&summary(session, &1))
        |> Enum.reverse()

      {:ok, summaries}
    end
  end

  defp summary(session, turn) do
    directory = Store.turn_dir(session, turn)
    captures = Store.all_json(Path.join(directory, "captures"))

    %{
      turn: turn,
      files: captures |> Enum.map(& &1["path"]) |> Enum.uniq(),
      snapshot?:
        Enum.any?(Window.all(directory), &Window.complete?/1) or
          complete_legacy_snapshot?(directory),
      undone?: File.regular?(Path.join(directory, "undone.json")),
      at: captures |> List.first(%{}) |> Map.get("at")
    }
  end

  ## Undoing

  @doc """
  Reverts the most recent turn that recorded something and has not been
  undone — or, with `force: true` right after an undo that left files
  alone, puts those files back (see "Undoing" in the moduledoc).

  Options: `:environment` (default the local machine), the environment the
  session's tools used; `:force`, to restore over conflicts; `:await_ms`,
  how long to wait for a stopped command's after-tree (default 5 seconds).

  `{:error, :nothing_to_undo}` when no such turn is left;
  `{:error, {:unwritable, path}}` when nothing was ever recorded because the
  store cannot be written — which is what a person whose edits undo cannot
  find needs to be told instead; `{:error, :still_recording}` when a command
  of the turn stopped a moment ago is still being snapshotted, and undoing
  now would lose its changes.
  """
  @spec undo(store :: store(), session_id :: String.t(), opts :: keyword()) ::
          {:ok, report()}
          | {:error, :nothing_to_undo | :still_recording | {:unwritable, Path.t()} | term()}
  def undo(store, session_id, opts \\ []) do
    with {:ok, session} <- Store.session_dir(store, session_id) do
      next = next_undoable(session)

      case undo_target(session, next, Keyword.get(opts, :force, false)) do
        {:left_alone, turn, keys} -> undo_turn(session, turn, Keyword.put(opts, :only, keys))
        nil -> nothing_to_undo(store, session)
        turn -> undo_turn(session, turn, opts)
      end
    end
  end

  # `force: true` finishes the last undo when that undo left files alone and
  # no newer turn has recorded anything since: that is what its report
  # offered `--force` for. Taking the next turn instead forced the turn
  # *before* the one the person was told about and left the files they had
  # been told about alone.
  defp undo_target(session, next, true) do
    case Undo.left_alone(session) do
      %{action: :undo, turn: turn, keys: keys} when is_nil(next) or turn > next ->
        {:left_alone, turn, keys}

      _nothing_to_finish ->
        next
    end
  end

  defp undo_target(_session, next, false), do: next

  defp undo_turn(session, turn, opts) do
    with {:ok, report} <- Undo.turn(session, turn, opts),
         do: {:ok, Map.put(report, :next, next_undoable(session))}
  end

  defp nothing_to_undo(store, session) do
    if Store.turns(session) == [] and not Store.writable?(session),
      do: {:error, {:unwritable, Path.expand(store)}},
      else: {:error, :nothing_to_undo}
  end

  @doc """
  Reverts up to `count` turns, newest first, stopping early when there is
  nothing left to undo. Returns one report per turn undone.
  """
  @spec rewind(store :: store(), session_id :: String.t(), count :: pos_integer(), keyword()) ::
          {:ok, [report()]} | {:error, :nothing_to_undo | term()}
  def rewind(store, session_id, count, opts \\ []) when is_integer(count) and count > 0 do
    result =
      Enum.reduce_while(1..count, {:ok, []}, fn _step, {:ok, reports} ->
        case undo(store, session_id, opts) do
          {:ok, report} -> {:cont, {:ok, [report | reports]}}
          {:error, :nothing_to_undo} -> {:halt, {:ok, reports}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, []} -> {:error, :nothing_to_undo}
      {:ok, reports} -> {:ok, Enum.reverse(reports)}
      error -> error
    end
  end

  @doc """
  Puts back what the most recent undo replaced: the files as they were just
  before it, saved when it ran. A file changed since the undo is a conflict
  and left alone unless `force: true`. Once anything is put back the turn
  can be undone again; a redo that put nothing back leaves the undo in
  place. Contents come back, written through the environment as undo wrote
  them; a file mode the undo reset (an executable bit) does not.

  Options are `undo/3`'s; `force: true` right after a redo that left files
  alone puts those back. `{:error, :nothing_to_redo}` when no undo is left
  to take back.
  """
  @spec redo(store :: store(), session_id :: String.t(), opts :: keyword()) ::
          {:ok, report()} | {:error, :nothing_to_redo | term()}
  def redo(store, session_id, opts \\ []) do
    with {:ok, session} <- Store.session_dir(store, session_id) do
      case redo_target(session, Keyword.get(opts, :force, false)) do
        {:left_alone, turn, name, keys} -> Undo.redo_left_alone(session, turn, name, keys, opts)
        nil -> {:error, :nothing_to_redo}
        turn -> Undo.redo(session, turn, opts)
      end
    end
  end

  # As for undo: `force: true` finishes the redo whose report offered it. A
  # redo that put nothing back left its undo in place, and the plain path
  # reaches that same undo again.
  defp redo_target(session, true) do
    case Undo.left_alone(session) do
      %{action: :redo, turn: turn, record: name, keys: keys} when is_binary(name) ->
        {:left_alone, turn, name, keys}

      _nothing_to_finish ->
        Undo.last_redoable(session)
    end
  end

  defp redo_target(session, false), do: Undo.last_redoable(session)

  @doc "Deletes everything recorded for `session_id`."
  @spec forget(store :: store(), session_id :: String.t()) :: :ok | {:error, term()}
  def forget(store, session_id) do
    with {:ok, session} <- Store.session_dir(store, session_id) do
      case File.rm_rf(session) do
        {:ok, _removed} -> :ok
        {:error, reason, _path} -> {:error, reason}
      end
    end
  end

  defp next_undoable(session) do
    session
    |> Store.turns()
    |> Enum.reverse()
    |> Enum.find(&undoable?(session, &1))
  end

  defp undoable?(session, turn) do
    directory = Store.turn_dir(session, turn)
    not File.regular?(Path.join(directory, "undone.json")) and not empty?(session, turn)
  end

  ## Helpers

  defp put_turn(session, turn) do
    with :ok <- Store.put_current(session, turn), do: {:ok, turn}
  end

  defp ensure_turn(session) do
    case Store.current(session) do
      0 -> put_turn(session, 1)
      turn -> {:ok, turn}
    end
  end

  defp empty?(session, turn) do
    directory = Store.turn_dir(session, turn)

    not (Store.any_json?(Path.join(directory, "captures")) or
           Store.any_json?(Window.directory(directory)) or
           Store.any_json?(Path.join(directory, "unrecorded")) or
           File.regular?(Path.join(directory, "snapshot.json")))
  end

  defp complete_legacy_snapshot?(directory) do
    match?(
      {:ok, %{"before" => _before, "after" => _after}},
      Store.json(Path.join(directory, "snapshot.json"))
    )
  end

  # The highest directory a write to a missing file will create, so undoing
  # the write can remove what it made and nothing that was there before.
  defp created_from(environment, cwd, relative, %{"state" => "absent"}) do
    if local?(environment) do
      relative
      |> Path.dirname()
      |> Path.split()
      |> Enum.scan(&Path.join(&2, &1))
      |> Enum.find(&(not File.dir?(Path.join(cwd, &1))))
    end
  end

  defp created_from(_environment, _cwd, _relative, _before), do: nil

  defp local?(Local), do: true
  defp local?({Local, _state}), do: true
  defp local?(_environment), do: false

  defp relative(cwd, path) when is_binary(path) do
    case Path.safe_relative(Scope.relativize(cwd, path), cwd) do
      {:ok, ""} -> {:error, :not_a_file}
      {:ok, relative} -> {:ok, relative}
      :error -> {:error, :outside_worktree}
    end
  end

  defp relative(_cwd, _path), do: {:error, :invalid_path}

  defp environment(context), do: Map.get(context, :environment, Environment.local())

  defp nullable_string(nil), do: nil
  defp nullable_string(value), do: to_string(value)

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
