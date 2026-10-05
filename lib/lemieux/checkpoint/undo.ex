defmodule Lemieux.Checkpoint.Undo do
  @moduledoc false

  # Undoing one turn, and putting an undo back. The rules — which pre-image a
  # path goes back to, when a path is a conflict, what is reported as not
  # undone, what `force` acts on — are `Lemieux.Checkpoint`'s moduledoc; this
  # is how they are done.
  #
  # Every record that saw a path change is an event: a file tool's capture
  # (`{:file, state}` before, the after-record's state after), a command's
  # git trees (`{:git, blob}`), or a command's listing of a file the trees
  # leave out (`{:unsaved, fingerprint}`, or `{:file, absent}` when it was
  # not there). A path's events merge into one entry whose `pre` is the
  # earliest event's before and whose `post` is the latest event's after,
  # ordered by `Store.seq/0`. That ordering is what sends a path a command
  # changed and a file tool then changed again back to its state before
  # both — and what keeps a file tool's capture of an ignored `.env` a
  # command had already rewritten from being called "restored" when it held
  # the command's version.

  alias Lemieux.Checkpoint.Files
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Checkpoint.Store
  alias Lemieux.Checkpoint.Window
  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Tools.FileOps

  @await_ms 5_000
  @left_alone "left_alone.json"

  # Why a path a command recorded is left alone once a directory above it is
  # a symbolic link: see `Lemieux.Checkpoint.Git.beyond_link?/2`.
  @beyond_link "a directory above it is now a symbolic link, which undo does not follow; " <>
                 "left alone"

  @typedoc "A path in a turn: the working directory it was named from, and the name."
  @type key :: {Path.t(), String.t()}

  @typedoc "What the last undo or redo left alone, which is what `force` finishes."
  @type left_alone :: %{
          action: :undo | :redo,
          turn: pos_integer(),
          keys: [key()],
          record: String.t() | nil
        }

  ## Undoing a turn

  @doc """
  Undoes `turn`. With `only: keys`, puts back just those paths — what an
  earlier undo of the turn left alone — and adds what it replaced to that
  undo's record, so one redo still takes the whole undo back.

  `{:error, :still_recording}` when a command of the turn that was stopped
  a moment ago is still being snapshotted: undoing then would report it as
  unrecorded and mark the turn undone, and its changes, recorded a moment
  later, could never be undone.
  """
  @spec turn(session :: Path.t(), turn :: pos_integer(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def turn(session, turn, opts) do
    directory = Store.turn_dir(session, turn)

    case Window.await(directory, Keyword.get(opts, :await_ms, @await_ms)) do
      :ok -> undo(session, directory, turn, opts)
      :timeout -> {:error, :still_recording}
    end
  end

  defp undo(session, directory, turn, opts) do
    undo = settings(session, opts)
    only = Keyword.get(opts, :only)

    {entries, report} =
      directory |> entries(empty_report(turn, :undo), undo.git) |> narrowed(only)

    {plan, report, left} = plan(entries, undo, report)

    # What each path holds now, saved before it is overwritten, so the undo
    # itself can be undone (`redo/3`).
    replaced = Enum.map(plan, &replacing(&1, undo))
    report = apply_plan(plan, undo, report)
    replaced = Enum.map(replaced, &replaced_by(&1, undo))

    # A pass that finishes left-alone files is about files the turn did
    # change, so its headline never says the turn changed nothing.
    report =
      report
      |> not_undone(directory, only)
      |> Map.put(:commands?, is_nil(only) and commands?(directory))
      |> finish()

    with :ok <- put_undone(directory, report, replaced, only),
         :ok <- put_left_alone(session, :undo, turn, left, nil) do
      {:ok, report}
    end
  end

  # A pass that finishes what an earlier undo left alone acts on those paths
  # and reports on them alone: the rest of the turn was reported then.
  defp narrowed({entries, report}, nil), do: {entries, report}

  defp narrowed({entries, report}, keys) do
    keys = MapSet.new(keys)
    {Enum.filter(entries, &MapSet.member?(keys, &1.key)), %{report | unrestorable: []}}
  end

  defp put_undone(directory, report, replaced, nil) do
    record =
      report
      |> report_json()
      |> Map.merge(%{
        "replaced" => replaced,
        # A record name, ordered by `Store.seq/0`: which undo came last has to
        # hold across a restart.
        "order" => Store.id()
      })

    Store.put_json(Path.join(directory, "undone.json"), record)
  end

  defp put_undone(directory, report, replaced, _only) do
    path = Path.join(directory, "undone.json")

    with {:ok, record} <- Store.json(path) do
      Store.put_json(
        path,
        Map.merge(record, %{
          "replaced" => (record["replaced"] || []) ++ replaced,
          "forced" => (record["forced"] || []) ++ [report_json(report)],
          "order" => Store.id()
        })
      )
    end
  end

  ## Putting an undo back

  @doc """
  Puts back what the undo of `turn` replaced. An undo with nothing put back
  and something left alone stays where it is, so `/redo --force` can still
  reach it; otherwise its record moves to `redone/` and the turn can be
  undone again. A forced write over a change made since the undo keeps what
  it overwrote in the record (`"overwritten"`), in the session's store.
  """
  @spec redo(session :: Path.t(), turn :: pos_integer(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def redo(session, turn, opts) do
    directory = Store.turn_dir(session, turn)
    undone = Path.join(directory, "undone.json")
    undo = settings(session, opts)

    with {:ok, %{"replaced" => replaced} = record} <- Store.json(undone) do
      {report, left, overwritten} = redo_entries(replaced, undo, empty_report(turn, :redo))
      record = Map.merge(record, %{"redo" => report_json(report), "overwritten" => overwritten})

      with :ok <- redone(session, turn, record, report, left), do: {:ok, report}
    end
  end

  # Something came back, or nothing was left alone: the undo is taken back,
  # and the turn can be undone again.
  defp redone(session, turn, record, report, left) when left == [] or report.restored != [],
    do: consume(session, turn, record, left)

  defp redone(session, turn, record, %{deleted: [_ | _]}, left),
    do: consume(session, turn, record, left)

  # Nothing came back and something was left alone: the undo stays, so a
  # forced redo still reaches it.
  defp redone(session, turn, _record, _report, left),
    do: put_left_alone(session, :redo, turn, left, nil)

  defp consume(session, turn, record, left) do
    directory = Store.turn_dir(session, turn)
    name = Store.id() <> ".json"

    with :ok <- Store.put_json(Path.join([directory, "redone", name]), record),
         :ok <- File.rm(Path.join(directory, "undone.json")),
         do: put_left_alone(session, :redo, turn, left, name)
  end

  @doc """
  Puts back, over whatever is there now, the paths a redo of `turn` left
  alone, from that redo's record `name`.
  """
  @spec redo_left_alone(
          session :: Path.t(),
          turn :: pos_integer(),
          name :: String.t(),
          keys :: [key()],
          opts :: keyword()
        ) :: {:ok, map()} | {:error, term()}
  def redo_left_alone(session, turn, name, keys, opts) do
    path = Path.join([Store.turn_dir(session, turn), "redone", name])
    undo = settings(session, Keyword.put(opts, :force, true))
    keys = MapSet.new(keys)

    with {:ok, %{"replaced" => replaced} = record} <- Store.json(path) do
      entries = Enum.filter(replaced, &MapSet.member?(keys, {&1["cwd"], &1["path"]}))
      {report, left, overwritten} = redo_entries(entries, undo, empty_report(turn, :redo))

      record =
        Map.merge(record, %{
          "forced" => (record["forced"] || []) ++ [report_json(report)],
          "overwritten" => (record["overwritten"] || []) ++ overwritten
        })

      with :ok <- Store.put_json(path, record),
           :ok <- put_left_alone(session, :redo, turn, left, name) do
        {:ok, report}
      end
    end
  end

  @doc """
  The turn whose undo is the most recent one that put something back, or
  `nil`. An undo that only reported a turn changed no file, so there is
  nothing of it to take back; one recorded before undos saved what they
  replaced cannot be taken back either.
  """
  @spec last_redoable(session :: Path.t()) :: pos_integer() | nil
  def last_redoable(session) do
    session
    |> Store.turns()
    |> Enum.flat_map(fn turn ->
      case Store.json(Path.join(Store.turn_dir(session, turn), "undone.json")) do
        {:ok, %{"replaced" => [_ | _], "order" => order}} -> [{order, turn}]
        _not_redoable -> []
      end
    end)
    |> Enum.max(fn -> nil end)
    |> case do
      {_order, turn} -> turn
      nil -> nil
    end
  end

  @doc "What the last undo or redo left alone, or `nil` when it left nothing."
  @spec left_alone(session :: Path.t()) :: left_alone() | nil
  def left_alone(session) do
    case Store.json(Path.join(session, @left_alone)) do
      {:ok, %{"action" => action, "turn" => turn, "keys" => [_ | _] = keys} = record}
      when action in ["undo", "redo"] and is_integer(turn) ->
        %{
          action: String.to_existing_atom(action),
          turn: turn,
          keys: for([cwd, path] <- keys, do: {cwd, path}),
          record: record["record"]
        }

      _nothing_left_alone ->
        nil
    end
  end

  # Rewritten by every undo and redo, so it always describes the last one:
  # `--force` acts on what the report the person just read offered it for.
  defp put_left_alone(session, _action, _turn, [], _record) do
    case File.rm(Path.join(session, @left_alone)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp put_left_alone(session, action, turn, keys, record) do
    Store.put_json(Path.join(session, @left_alone), %{
      "action" => Atom.to_string(action),
      "turn" => turn,
      "keys" => Enum.map(keys, &Tuple.to_list/1),
      "record" => record,
      "at" => now()
    })
  end

  # `git` is what every `Lemieux.Checkpoint.Git` call here is given: the
  # session's own directory for git's private directories, in the store.
  defp settings(session, opts) do
    %{
      session: session,
      environment: Keyword.get(opts, :environment, Environment.local()),
      force?: Keyword.get(opts, :force, false),
      git: [scratch: Store.scratch(session)]
    }
  end

  defp empty_report(turn, action) do
    %{
      turn: turn,
      action: action,
      restored: [],
      deleted: [],
      conflicts: [],
      unrestorable: [],
      uncertain: [],
      not_undone: [],
      commands?: false
    }
  end

  # Whether anything other than the file tools ran in the turn — a command, or
  # a tool noted as unrecorded — which is what makes "it changed nothing
  # undo records" need the caveat about what undo does not record.
  defp commands?(directory) do
    Store.any_json?(Window.directory(directory)) or
      Store.any_json?(Path.join(directory, "unrecorded")) or
      File.regular?(Path.join(directory, "snapshot.json"))
  end

  ## What the turn changed

  defp entries(directory, report, git) do
    captures = Store.all_json(Path.join(directory, "captures"))

    afters =
      directory
      |> Path.join("after")
      |> Store.all_json()
      |> Map.new(&{Store.key(&1["call_id"], &1["cwd"], &1["path"]), &1})

    captured = capture_entries(captures, afters)
    covered = MapSet.new(captured, & &1.key)
    windows = directory |> Window.all() |> Enum.filter(&Window.complete?/1)

    {windowed, report} =
      Enum.reduce(windows, {[], report}, fn window, {entries, report} ->
        {more, report} = window_entries(window, report, git)
        {more ++ entries, report}
      end)

    {legacy, report} = legacy_entries(directory, covered, report, git)

    {entries, report} =
      (captured ++ windowed ++ legacy)
      |> Enum.group_by(& &1.key)
      |> Enum.flat_map_reduce(report, fn {_key, events}, report -> merged(events, report) end)

    entries =
      entries
      |> Enum.map(&%{&1 | uncertain: uncertain(&1, windows)})
      |> Enum.sort_by(& &1.path)

    {entries, report}
  end

  # The earliest capture of a path holds what it was before the call that
  # first changed it; the latest capture's after-record holds what the agent
  # left.
  defp capture_entries(captures, afters) do
    captures
    |> Enum.group_by(&{&1["cwd"], &1["path"]})
    |> Enum.map(fn {{cwd, path}, list} ->
      list = Enum.sort_by(list, &(&1["seq"] || 0))
      first = hd(list)
      done = Map.get(afters, Store.key(List.last(list)["call_id"], cwd, path))

      event(:capture, {cwd, path}, %{
        open: first["seq"] || 0,
        close: (done && done["seq"]) || 0,
        pre: {:file, first["before"]},
        post: done && {:file, done["after"]},
        created_from: first["created_from"]
      })
    end)
  end

  defp event(source, {cwd, path} = key, fields) do
    Map.merge(
      %{
        key: key,
        cwd: cwd,
        path: path,
        source: source,
        created_from: nil,
        captured?: source == :capture,
        uncertain: nil,
        why: nil,
        limits: %{}
      },
      fields
    )
  end

  defp window_entries(window, report, git) do
    %{"root" => root, "prefix" => prefix, "cwd" => cwd} = window
    before = window["before"]
    later = window["after"]

    with true <- Git.object?(root, before["tree"], git) and Git.object?(root, later["tree"], git),
         {:ok, changes} <- Git.changed(root, before["tree"], later["tree"], git) do
      changed = changes |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      side = %{
        root: root,
        prefix: prefix,
        cwd: cwd,
        git: git,
        window: window,
        limits: window["limits"] || %{},
        before: unsaved_map(before),
        after: unsaved_map(later),
        dirs: existing_dirs(before)
      }

      inside? = &String.starts_with?(&1, prefix)
      {inside, outside} = Enum.split_with(changed, inside?)

      {unsaved_inside, unsaved_outside} =
        side
        |> unsaved_changes(MapSet.new(changed))
        |> Enum.split_with(inside?)

      # A wholly ignored directory is listed by name only: undo can say it
      # appeared or went, never put it back, so it stays a line in the report.
      {directories, files} = Enum.split_with(unsaved_inside, &String.ends_with?(&1, "/"))

      report =
        report
        |> outside(side, outside ++ unsaved_outside)
        |> unsaved_directories(side, directories)

      {tree, report} = tree_entries(side, inside, report)
      {tree ++ Enum.map(files, &unsaved_entry(side, &1)), report}
    else
      false ->
        {[],
         problem(report, :unrestorable, ".", "the turn's git snapshot no longer exists (git gc)")}

      {:error, reason} ->
        {[], unreadable(report, reason)}
    end
  end

  # The directories git did not track before the command — an empty one
  # included, which no tree can show; `nil` when the window did not list them
  # (recorded before it did, or past the listing's limit), in which case undo
  # removes no directory a command's files were in.
  defp existing_dirs(%{"dirs" => dirs, "dirs_more" => 0}) when is_list(dirs), do: dirs
  defp existing_dirs(_side), do: nil

  defp tree_entries(side, paths, report) do
    window = side.window

    with {:ok, original} <- Git.entries(side.root, window["before"]["tree"], paths, side.git),
         {:ok, left} <- Git.entries(side.root, window["after"]["tree"], paths, side.git) do
      entries =
        Enum.map(paths, fn path ->
          event(:tree, {side.cwd, shown(side, path)}, %{
            open: window["before"]["seq"] || 0,
            close: window["after"]["seq"] || 0,
            pre: tree_state(side, window["before"]["tree"], path, original[path], side.before),
            post: tree_state(side, window["after"]["tree"], path, left[path], side.after)
          })
        end)

      {entries, report}
    else
      {:error, reason} -> {[], unreadable(report, reason)}
    end
  end

  # A path the tree does not have may still have been there, unsaved: past
  # the untracked-file limit, or too large. Taking that for "absent" would
  # delete a file nobody touched, or call it a conflict.
  defp tree_state(side, tree, path, nil, unsaved) do
    case Map.get(unsaved, path) do
      nil -> {:git, git_state(side, tree, path, nil, nil)}
      saved -> unsaved_state(side, path, saved)
    end
  end

  defp tree_state(side, tree, path, entry, _unsaved),
    do: {:git, git_state(side, tree, path, entry.blob, entry.mode)}

  defp git_state(side, tree, path, blob, mode),
    do: %{root: side.root, tree: tree, path: path, blob: blob, mode: mode, dirs: side.dirs}

  # A file the listings show but the trees do not: what it was, by
  # fingerprint, or absent — which, merged with a file tool's records of the
  # same path, is a state undo can return to (by deleting).
  defp unsaved_state(_side, _path, nil), do: {:file, %{"state" => "absent"}}

  defp unsaved_state(side, path, saved),
    do:
      {:unsaved,
       %{
         root: side.root,
         path: path,
         fingerprint: saved.fingerprint,
         why: saved.why,
         limits: side.limits
       }}

  defp unsaved_entry(side, path) do
    window = side.window
    saved = Map.get(side.after, path) || Map.fetch!(side.before, path)

    event(:unsaved, {side.cwd, shown(side, path)}, %{
      open: window["before"]["seq"] || 0,
      close: window["after"]["seq"] || 0,
      pre: unsaved_state(side, path, Map.get(side.before, path)),
      post: unsaved_state(side, path, Map.get(side.after, path)),
      why: saved.why,
      limits: side.limits
    })
  end

  defp unsaved_map(%{"unsaved" => unsaved}) when is_list(unsaved) do
    Map.new(unsaved, fn [path, size, mtime, inode, why] ->
      {path, %{fingerprint: [size, mtime, inode], why: why}}
    end)
  end

  defp unsaved_map(_side), do: %{}

  # Files and ignored directories the listings show but the trees do not,
  # that differ between the two listings: created, deleted or rewritten.
  defp unsaved_changes(side, changed) do
    side.before
    |> Map.keys()
    |> Enum.concat(Map.keys(side.after))
    |> Enum.uniq()
    |> Enum.reject(
      &(MapSet.member?(changed, &1) or Map.get(side.before, &1) == Map.get(side.after, &1))
    )
  end

  defp unsaved_directories(report, side, directories) do
    Enum.reduce(directories, report, fn path, report ->
      verb = if Map.has_key?(side.before, path), do: "deleted", else: "created"
      why = Map.get(side.after, path, Map.get(side.before, path)).why
      problem(report, :unrestorable, shown(side, path), unsaved_reason(verb, why, side.limits))
    end)
  end

  defp outside(report, side, paths) do
    paths
    |> Enum.uniq()
    |> Enum.reduce(report, fn path, report ->
      # Relative within the repository, from the prefix git reported: the
      # session's `cwd` may name the same directory through a symbolic link
      # (`/tmp` on macOS) that git's root does not.
      shown = Path.relative_to("/" <> path, "/" <> side.prefix, force: true)

      problem(
        report,
        :unrestorable,
        shown,
        "changed by a command outside the working directory, which undo leaves alone"
      )
    end)
  end

  defp shown(side, path), do: String.replace_prefix(path, side.prefix, "")

  # Turns recorded before commands had windows of their own kept one snapshot
  # for all of a turn's commands, and the paths a file tool captured were left
  # to the capture; that rule still applies to what they recorded.
  defp legacy_entries(directory, covered, report, git) do
    case Store.json(Path.join(directory, "snapshot.json")) do
      {:ok,
       %{
         "before" => before,
         "after" => later,
         "root" => root,
         "prefix" => prefix,
         "cwd" => cwd
       }} ->
        window = %{
          "root" => root,
          "prefix" => prefix,
          "cwd" => cwd,
          "before" => %{"tree" => before},
          "after" => %{"tree" => later}
        }

        {entries, report} = window_entries(window, report, git)
        {Enum.reject(entries, &MapSet.member?(covered, &1.key)), report}

      _no_snapshot ->
        {[], report}
    end
  end

  # A path only command listings saw is named and left alone: undo cannot put
  # back what was never saved, and does not delete an ignored file a command
  # created — a dev server's log, a `.DS_Store` — that nothing else says the
  # agent meant. Merged with a file tool's records it is the agent's file,
  # and goes back like one.
  defp merged(events, report) do
    if Enum.all?(events, &(&1.source == :unsaved)),
      do: {[], unsaved_only(merge(events), report)},
      else: {[merge(events)], report}
  end

  defp merge([event]), do: event

  defp merge(events) do
    first = Enum.min_by(events, & &1.open)
    last = Enum.max_by(events, & &1.close)

    %{
      first
      | post: last.post,
        close: last.close,
        created_from: Enum.find_value(events, & &1.created_from),
        captured?: Enum.any?(events, & &1.captured?),
        why: Enum.find_value(events, & &1.why)
    }
  end

  defp unsaved_only(%{pre: pre, post: post} = entry, report) do
    case {absent?(pre), absent?(post)} do
      {true, true} -> report
      {true, false} -> unsaved_problem(report, entry, "created")
      {false, true} -> unsaved_problem(report, entry, "deleted")
      {false, false} -> unsaved_problem(report, entry, "changed")
    end
  end

  defp unsaved_problem(report, entry, verb),
    do: problem(report, :unrestorable, entry.path, unsaved_reason(verb, entry.why, entry.limits))

  # Said as "while a command ran", not "by a command": a file a dev server or
  # the person's editor wrote during the command shows the same in a listing.
  defp unsaved_reason(verb, why, limits), do: "#{verb} while a command ran; #{why(why, limits)}"

  # A path the agent's file tool captured, inside a directory an earlier
  # command's listing names only as a whole (`config/local/`, ignored): the
  # command may have changed it before the capture, which then holds the
  # command's version. Undo puts back what it has and says it may not be all.
  defp uncertain(%{source: :capture} = entry, windows) do
    Enum.find_value(windows, fn window ->
      with true <- earlier?(window, entry) and window["cwd"] == entry.cwd,
           directory when is_binary(directory) <- listed_directory(window, entry.path) do
        shown = String.replace_prefix(directory, window["prefix"], "")

        "an earlier command in this turn may have changed it first; what commands " <>
          "change inside #{shown} is not recorded, since git ignores what it holds"
      else
        _seen_or_later -> nil
      end
    end)
  end

  defp uncertain(_entry, _windows), do: nil

  defp earlier?(%{"before" => %{"seq" => seq}}, %{open: open})
       when is_integer(seq) and is_integer(open),
       do: seq < open

  defp earlier?(_window, _entry), do: false

  defp listed_directory(window, path) do
    repository_path = window["prefix"] <> path

    [window["before"], window["after"]]
    |> Enum.flat_map(&Map.get(&1, "unsaved", []))
    |> Enum.find_value(fn [listed | _fingerprint] ->
      if String.ends_with?(listed, "/") and String.starts_with?(repository_path, listed),
        do: listed
    end)
  end

  ## Deciding

  defp plan(entries, undo, report) do
    now = current(entries, undo)

    {plan, report, left} =
      Enum.reduce(entries, {[], report, []}, fn entry, {plan, report, left} ->
        case decide(entry, Map.fetch!(now, entry.key), undo.force?) do
          :unchanged ->
            {plan, report, left}

          :restore ->
            {[entry | plan], report, left}

          {:conflicts, reason} ->
            {plan, problem(report, :conflicts, entry.path, reason), [entry.key | left]}

          {:unrestorable, reason} ->
            {plan, problem(report, :unrestorable, entry.path, reason), left}
        end
      end)

    {Enum.reverse(plan), report, Enum.reverse(left)}
  end

  # What is behind the link is not the turn's to touch, force or not: a
  # sandboxed command that planted it would otherwise aim this host-side
  # undo at a file outside the sandbox (`Lemieux.Checkpoint.Git.beyond_link?/2`).
  defp decide(_entry, %{beyond_link?: true}, _force?), do: {:unrestorable, @beyond_link}

  defp decide(%{pre: {:file, %{"state" => "unavailable"} = pre}}, _now, _force?),
    do: {:unrestorable, pre["reason"] || "its contents were not saved"}

  defp decide(%{pre: pre} = entry, now, force?) do
    if matches?(now, pre), do: :unchanged, else: changed(entry, now, force?)
  end

  defp changed(%{pre: {:unsaved, saved}} = entry, _now, _force?),
    do: {:unrestorable, unsaved_before(entry.captured?, saved)}

  defp changed(%{post: post}, now, force?) do
    cond do
      force? or (post != nil and matches?(now, post)) -> :restore
      is_nil(post) -> {:conflicts, "the change was not recorded; the call did not finish"}
      match?({:file, _state}, post) -> {:conflicts, "changed since the agent wrote it"}
      true -> {:conflicts, "changed since the agent's command ran"}
    end
  end

  defp unsaved_before(true = _captured?, saved),
    do:
      "a command changed it before the agent's file tool did, and its contents before " <>
        "that were not saved: #{why(saved.why, saved.limits)}"

  defp unsaved_before(false = _captured?, saved),
    do: "its contents before the command were not saved: #{why(saved.why, saved.limits)}"

  defp matches?(now, {:file, state}), do: Files.same?(now.file, state)
  defp matches?(now, {:git, state}), do: same_entry?(now.git, state, now.file_mode?)
  defp matches?(now, {:unsaved, %{fingerprint: fingerprint}}), do: now.fingerprint == fingerprint

  # Absent on both sides, or the same blob with the same mode — where the
  # repository records the executable bit; where it does not, a regular
  # file's mode is whatever the tree last said and proves nothing.
  defp same_entry?(nil, %{blob: nil}, _file_mode?), do: true
  defp same_entry?(%{blob: blob, mode: mode}, %{blob: blob, mode: mode}, _file_mode?), do: true

  defp same_entry?(%{blob: blob, mode: now}, %{blob: blob, mode: then}, false),
    do: regular?(now) and regular?(then)

  defp same_entry?(_now, _then, _file_mode?), do: false

  defp regular?(mode), do: mode in ["100644", "100755"]

  # Each entry's state now, read only in the forms its records need: a git
  # hash, a digest through the environment, or a fingerprint.
  defp current(entries, undo) do
    git = git_now(entries, undo.git)
    Map.new(entries, &{&1.key, now(&1, git, undo)})
  end

  defp now(entry, git, undo) do
    kinds = [kind(entry.pre), kind(entry.post)]

    {worktree, file_mode?} =
      if :git in kinds,
        do:
          git
          |> Map.fetch!(root(entry))
          |> then(fn {all, mode?} -> {all[repo_path(entry)], mode?} end),
        else: {nil, true}

    %{
      file:
        if(:file in kinds,
          do: Files.observe(undo.session, undo.environment, entry.cwd, entry.path, [], false)
        ),
      git: worktree,
      file_mode?: file_mode?,
      # Only a path a snapshot located: a file tool's goes through the
      # environment, whose own confinement refuses a link out of the tree.
      beyond_link?:
        Enum.any?(kinds, &(&1 in [:git, :unsaved])) and
          Git.beyond_link?(root(entry), repo_path(entry)),
      fingerprint:
        if(:unsaved in kinds, do: Files.fingerprint(Path.join(root(entry), repo_path(entry))))
    }
  end

  defp git_now(entries, git) do
    entries
    |> Enum.filter(&(kind(&1.pre) == :git or kind(&1.post) == :git))
    |> Enum.group_by(&root/1, &repo_path/1)
    |> Map.new(fn {root, paths} ->
      case Git.worktree_entries(root, Enum.uniq(paths), git) do
        {:ok, entries} ->
          {root, {entries, Git.file_mode?(root, git)}}

        # Unreadable is "not what the agent left", which makes each a conflict
        # rather than an overwrite.
        {:error, _reason} ->
          {root, {Map.new(paths, &{&1, %{blob: :unreadable, mode: nil}}), true}}
      end
    end)
  end

  defp kind({kind, _state}), do: kind
  defp kind(nil), do: nil

  # Where in its repository a path is, from whichever record was a snapshot.
  defp root(entry), do: located(entry).root
  defp repo_path(entry), do: located(entry).path

  defp located(%{pre: {kind, state}}) when kind in [:git, :unsaved], do: state
  defp located(%{post: {kind, state}}) when kind in [:git, :unsaved], do: state

  ## Putting back

  defp apply_plan(plan, undo, report) do
    {git, files} = Enum.split_with(plan, &match?({:git, _state}, &1.pre))
    report = Enum.reduce(files, report, &put_back(&1.pre, &1, undo, &2))
    report = restore_git(git, report, undo.git)
    tidy(plan, undo)
    report
  end

  defp put_back({:file, %{"state" => "absent"}}, entry, undo, report) do
    case FileOps.delete(undo.environment, entry.cwd, entry.path) do
      :ok ->
        done(report, :deleted, entry)

      {:error, reason} ->
        problem(report, :unrestorable, entry.path, "could not delete: #{inspect(reason)}")
    end
  end

  defp put_back({:file, %{"state" => "file", "sha256" => digest}}, entry, undo, report) do
    with {:ok, contents} <- Store.blob(undo.session, digest),
         {:ok, _disposition} <-
           Environment.write_file(undo.environment, entry.cwd, entry.path, contents) do
      done(report, :restored, entry)
    else
      {:error, reason} ->
        problem(report, :unrestorable, entry.path, "could not restore: #{inspect(reason)}")
    end
  end

  # What was done to a path, and — for a capture an earlier command may have
  # changed unseen — that it may not be all.
  defp done(report, field, %{uncertain: reason} = entry) when is_binary(reason),
    do:
      report |> done(field, %{entry | uncertain: nil}) |> problem(:uncertain, entry.path, reason)

  defp done(report, field, entry), do: Map.update!(report, field, &[entry.path | &1])

  defp restore_git(entries, report, git) do
    {absent, present} = Enum.split_with(entries, &match?({:git, %{blob: nil}}, &1.pre))
    report = Enum.reduce(absent, report, &remove/2)

    present
    |> Enum.group_by(fn %{pre: {:git, state}} -> {state.root, state.tree} end)
    |> Enum.reduce(report, fn {{root, tree}, group}, report ->
      paths = Enum.map(group, fn %{pre: {:git, state}} -> state.path end)

      case Git.restore(root, tree, paths, git) do
        {:ok, unwritten} ->
          Enum.reduce(group, report, &restored(&1, unwritten, &2))

        failed ->
          reason = restore_failed(failed)
          Enum.reduce(group, report, &problem(&2, :unrestorable, &1.path, reason))
      end
    end)
  end

  defp restore_failed(:skipped),
    do: "git restore failed: the working directory is no longer a git repository"

  defp restore_failed({:error, reason}), do: "git restore failed: #{inspect(reason, limit: 5)}"

  defp restored(%{pre: {:git, state}} = entry, unwritten, report) do
    case Map.fetch(unwritten, state.path) do
      {:ok, reason} -> problem(report, :unrestorable, entry.path, reason)
      :error -> done(report, :restored, entry)
    end
  end

  defp remove(%{pre: {:git, state}} = entry, report) do
    case unlink(state.root, state.path) do
      :ok ->
        done(report, :deleted, entry)

      {:error, :enoent} ->
        report

      {:error, :beyond_link} ->
        problem(report, :unrestorable, entry.path, @beyond_link)

      {:error, reason} ->
        problem(report, :unrestorable, entry.path, "could not delete: #{inspect(reason)}")
    end
  end

  # Checked again immediately before the delete, as `Lemieux.Environment.Local`
  # checks a write: `File.rm/1` follows a link anywhere above the file, and
  # one may have appeared since the plan was made.
  defp unlink(root, path) do
    if Git.beyond_link?(root, path),
      do: {:error, :beyond_link},
      else: File.rm(Path.join(root, path))
  end

  # Directories the turn created for the files it created go with them, deepest
  # first, while they are empty: a file tool's from what its capture saw was
  # missing, a command's when the snapshot before it had no such directory and
  # did not list it as one git does not track. A directory that holds anything
  # else stays, because `rmdir` refuses it. One beyond a symbolic link stays
  # too: `rmdir` follows a link above it, and an empty directory wherever the
  # link points — outside the tree — went with the turn's.
  defp tidy(plan, undo) do
    created = Enum.filter(plan, &absent?(&1.pre))

    {snapshotted, captured} = Enum.split_with(created, &match?({:git, _state}, &1.pre))

    captured_dirs =
      if local?(undo.environment), do: Enum.flat_map(captured, &captured_dirs/1), else: []

    (captured_dirs ++ snapshotted_dirs(snapshotted, undo.git))
    |> Enum.reject(fn {root, dir} -> Git.beyond_link?(root, dir) end)
    |> Enum.map(fn {root, dir} -> Path.join(root, dir) end)
    |> Enum.uniq()
    |> Enum.sort_by(&length(Path.split(&1)), :desc)
    |> Enum.each(&File.rmdir/1)
  end

  defp absent?({:file, %{"state" => "absent"}}), do: true
  defp absent?({:git, %{blob: nil}}), do: true
  defp absent?(_state), do: false

  # Each as the working directory and a directory relative to it.
  defp captured_dirs(%{created_from: from} = entry) when is_binary(from) do
    dir = Path.dirname(entry.path)

    if dir == from or String.starts_with?(dir, from <> "/"),
      do: dir |> up_to(from) |> Enum.map(&{entry.cwd, &1}),
      else: []
  end

  defp captured_dirs(_entry), do: []

  defp up_to(top, top), do: [top]
  defp up_to(dir, top), do: [dir | up_to(Path.dirname(dir), top)]

  defp snapshotted_dirs(entries, git) do
    entries
    |> Enum.group_by(fn %{pre: {:git, state}} -> {state.root, state.tree} end)
    |> Enum.flat_map(fn {{root, tree}, [%{pre: {:git, %{dirs: dirs}}} | _rest] = group} ->
      candidates =
        Enum.flat_map(group, fn %{pre: {:git, state}} = entry ->
          prefix = String.replace_suffix(state.path, entry.path, "")
          below(Path.dirname(state.path), prefix)
        end)

      # Without the lists of what existed, nothing is removed: an empty
      # directory the person had is not the turn's to take away.
      with listed when is_list(listed) <- dirs,
           {:ok, existed} <- Git.directories(root, tree, git) do
        candidates
        |> Enum.reject(&(MapSet.member?(existed, &1) or untracked?(&1, listed)))
        |> Enum.map(&{root, &1})
      else
        _unknown -> []
      end
    end)
  end

  # Listed directories end in `/` and may hold the candidate, or be it.
  defp untracked?(directory, listed),
    do: Enum.any?(listed, &String.starts_with?(directory <> "/", &1))

  # Repository-relative directories from `dir` up to, not including, the
  # working directory's own.
  defp below(".", _prefix), do: []

  defp below(dir, prefix) do
    if String.starts_with?(dir <> "/", prefix) and dir <> "/" != prefix,
      do: [dir | below(Path.dirname(dir), prefix)],
      else: []
  end

  defp local?(Local), do: true
  defp local?({Local, _state}), do: true
  defp local?(_environment), do: false

  ## Undoing an undo

  defp replacing(entry, undo) do
    %{
      "cwd" => entry.cwd,
      "path" => entry.path,
      "before" => Files.observe(undo.session, undo.environment, entry.cwd, entry.path, [], true)
    }
  end

  defp replaced_by(record, undo) do
    Map.put(
      record,
      "after",
      Files.observe(undo.session, undo.environment, record["cwd"], record["path"], [], false)
    )
  end

  defp redo_entries(entries, undo, report) do
    {report, left, overwritten} =
      entries
      |> Enum.sort_by(& &1["path"])
      |> Enum.reduce({report, [], []}, &redo_path(&1, undo, &2))

    {finish(report), Enum.reverse(left), Enum.reverse(overwritten)}
  end

  defp redo_path(entry, undo, {report, left, overwritten}) do
    %{"cwd" => cwd, "path" => path, "before" => wanted} = entry
    current = Files.observe(undo.session, undo.environment, cwd, path, [], false)
    back = %{pre: {:file, wanted}, cwd: cwd, path: path, uncertain: nil}

    cond do
      Files.same?(current, wanted) ->
        {report, left, overwritten}

      wanted["state"] == "unavailable" ->
        unrestorable = wanted["reason"] || "it was not saved"
        {problem(report, :unrestorable, path, unrestorable), left, overwritten}

      Files.same?(current, entry["after"]) ->
        {put_back(back.pre, back, undo, report), left, overwritten}

      # Over a change made since the undo, which nothing else saved.
      undo.force? ->
        saved = Files.observe(undo.session, undo.environment, cwd, path, [], true)
        record = %{"cwd" => cwd, "path" => path, "state" => saved}
        {put_back(back.pre, back, undo, report), left, [record | overwritten]}

      true ->
        conflict = problem(report, :conflicts, path, "changed since the undo")
        {conflict, [{cwd, path} | left], overwritten}
    end
  end

  ## What was not undone

  defp not_undone(report, directory, nil) do
    windows = Window.all(directory)

    report
    |> unrecorded(directory)
    |> unfinished(windows)
    |> unsnapshotted(windows)
    |> moved(Enum.filter(windows, &Window.complete?/1))
    |> unlisted(windows)
  end

  # Said when the turn was first undone; finishing its conflicts does not
  # repeat it.
  defp not_undone(report, _directory, _only), do: report

  defp unrecorded(report, directory) do
    directory
    |> Path.join("unrecorded")
    |> Store.all_json()
    |> Enum.sort_by(&(&1["seq"] || 0))
    |> Enum.reduce(report, fn note, report ->
      missed(report, note["subject"] || "something", note["reason"] || "it was not recorded")
    end)
  end

  defp unfinished(report, windows) do
    windows
    |> Enum.filter(&Window.open?/1)
    |> Enum.reduce(report, fn window, report ->
      missed(
        report,
        window["subject"] || "a command",
        "it had not finished when this turn was last recorded, so what it changed was not " <>
          "recorded or undone; git status shows what changed"
      )
    end)
  end

  defp unsnapshotted(report, windows) do
    windows
    |> Enum.filter(&match?(%{"after" => %{"error" => _error}}, &1))
    |> Enum.reduce(report, fn window, report ->
      missed(
        report,
        window["subject"] || "a command",
        "the repository could not be snapshotted after it ran " <>
          "(#{window["after"]["error"]}), so what it changed was not recorded or undone"
      )
    end)
  end

  # Undo puts file contents back and never moves a ref, so a commit, a branch
  # switch or a reset the turn made is said, not undone.
  defp moved(report, windows) do
    windows
    |> Enum.filter(&match?(%{"before" => %{"head" => _head}, "after" => %{"head" => _later}}, &1))
    |> Enum.group_by(& &1["root"])
    |> Enum.reduce(report, fn {_root, windows}, report ->
      heads = Enum.filter(windows, &(&1["before"]["head"] != &1["after"]["head"]))
      refs = Enum.filter(windows, &(&1["before"]["refs"] != &1["after"]["refs"]))

      cond do
        heads != [] ->
          from = hd(heads)["before"]["head"]
          to = List.last(heads)["after"]["head"]

          missed(
            report,
            "HEAD",
            "moved from #{head(from)} to #{head(to)} during this turn; undo does not move " <>
              "branches or undo commits (git reflog shows the way back)"
          )

        refs != [] ->
          missed(
            report,
            "git refs",
            "a branch, tag, stash or remote-tracking ref changed during this turn; " <>
              "undo does not change refs"
          )

        true ->
          report
      end
    end)
  end

  defp head(%{"branch" => branch, "commit" => commit}) do
    short = if is_binary(commit), do: binary_part(commit, 0, min(7, byte_size(commit)))

    case {branch, short} do
      {nil, nil} -> "nothing"
      {nil, short} -> short
      {branch, nil} -> "#{branch} (no commits yet)"
      {branch, short} -> "#{branch} (#{short})"
    end
  end

  defp unlisted(report, windows) do
    more =
      windows
      |> Enum.flat_map(&[&1["before"]["unsaved_more"], (&1["after"] || %{})["unsaved_more"]])
      |> Enum.filter(&is_integer/1)
      |> Enum.max(fn -> 0 end)

    if more > 0,
      do:
        missed(
          report,
          "untracked, ignored and filtered files",
          "the repository has #{count(more)} more than undo lists, so a command's changes to " <>
            "those are neither undone nor reported"
        ),
      else: report
  end

  ## The report

  # Several windows can see the same path change outside the working
  # directory, or the same ignored file; a report names each once.
  defp finish(report) do
    %{
      report
      | restored: report.restored |> Enum.reverse() |> Enum.uniq(),
        deleted: report.deleted |> Enum.reverse() |> Enum.uniq(),
        conflicts: report.conflicts |> Enum.reverse() |> Enum.uniq(),
        unrestorable: report.unrestorable |> Enum.reverse() |> Enum.uniq_by(& &1.path),
        uncertain: report.uncertain |> Enum.reverse() |> Enum.uniq_by(& &1.path),
        not_undone: report.not_undone |> Enum.reverse() |> Enum.uniq()
    }
  end

  defp problem(report, field, path, reason),
    do: Map.update!(report, field, &[%{path: path, reason: reason} | &1])

  defp missed(report, subject, reason),
    do: %{report | not_undone: [%{subject: subject, reason: reason} | report.not_undone]}

  defp unreadable(report, reason),
    do:
      problem(
        report,
        :unrestorable,
        ".",
        "the turn's git snapshot could not be read: #{inspect(reason)}"
      )

  defp why("ignored", _limits), do: "git ignores it, so undo does not save it"

  # A tracked file a filter attribute names: what git holds for it is the
  # filter's output, and no filter runs here (`Lemieux.Checkpoint.Git`).
  defp why("filtered", _limits),
    do:
      "git passes it through a filter (Git LFS, git-crypt), which undo does not run, so " <>
        "undo does not save it"

  defp why("large", limits),
    do: "an untracked file over #{size(limits["bytes"] || 1_000_000)}, which undo does not save"

  defp why("beyond_limit", limits),
    do:
      "past the first #{count(limits["files"] || 2_000)} untracked files, which is all undo saves"

  defp why(_other, _limits), do: "undo did not save it"

  defp size(bytes) when rem(bytes, 1_000_000) == 0, do: "#{div(bytes, 1_000_000)} MB"
  defp size(bytes), do: "#{count(bytes)} bytes"

  defp count(number) do
    number
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  defp report_json(report) do
    problems =
      &Enum.map(&1, fn problem -> %{"path" => problem.path, "reason" => problem.reason} end)

    %{
      "turn" => report.turn,
      "action" => Atom.to_string(report.action),
      "restored" => report.restored,
      "deleted" => report.deleted,
      "conflicts" => problems.(report.conflicts),
      "unrestorable" => problems.(report.unrestorable),
      "uncertain" => problems.(report.uncertain),
      "not_undone" =>
        Enum.map(report.not_undone, &%{"subject" => &1.subject, "reason" => &1.reason}),
      "at" => now()
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
