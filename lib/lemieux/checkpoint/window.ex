defmodule Lemieux.Checkpoint.Window do
  @moduledoc false

  # One command's bracket: the git snapshot taken immediately before it and
  # the one taken immediately after, in `turns/<n>/commands/<key>.json`. The
  # reasoning — why a window per command, why a watcher closes one whose
  # command was killed, why undo waits briefly for that watcher — is in
  # `Lemieux.Checkpoint`'s moduledoc under "Commands".

  alias Lemieux.Checkpoint.Git
  alias Lemieux.Checkpoint.Store

  # How often a watcher whose process is still alive looks whether the window
  # was closed without it, so a host that runs commands from one long-lived
  # process does not collect a watcher per command.
  @recheck_ms 60_000
  @await_step_ms 50

  # `:scratch` is where `Lemieux.Checkpoint` has git make its private
  # directory: the session's own, in the store.
  @git_options [:max_untracked_bytes, :max_untracked_files, :scratch]

  @doc false
  @spec path(turn_dir :: Path.t(), key :: String.t()) :: Path.t()
  def path(turn_dir, key), do: Path.join([turn_dir, "commands", key <> ".json"])

  @doc false
  @spec directory(turn_dir :: Path.t()) :: Path.t()
  def directory(turn_dir), do: Path.join(turn_dir, "commands")

  @doc """
  Takes the before-snapshot of the window at `path`, once: a window that
  already has one keeps it. A closed one is opened again — another command
  under the same key in the same turn (commands without a call id share
  one), which the window then spans from the first command's before-tree to
  this one's after-tree.
  """
  @spec open(path :: Path.t(), meta :: map(), opts :: keyword()) ::
          :ok | :skipped | {:error, term()}
  # The key a window is kept under names this VM (see `Lemieux.Checkpoint`),
  # so the window reopened here is never one a stopped run left.
  def open(path, meta, opts) do
    case read(path) do
      %{"before" => _before, "after" => _after} = closed ->
        Store.put_json(path, closed |> Map.delete("after") |> Map.merge(meta))

      %{"before" => _before} ->
        :ok

      existing ->
        first(path, existing, meta, opts)
    end
  end

  defp first(path, existing, meta, opts) do
    case Git.snapshot(meta["cwd"], Keyword.take(opts, @git_options)) do
      {:ok, snapshot} ->
        # Only the before-side keeps the untracked directories: they are what
        # existed before the command, which is all undo asks of them.
        before =
          snapshot
          |> side()
          |> Map.merge(%{"dirs" => snapshot.dirs, "dirs_more" => snapshot.dirs_more})

        record =
          existing
          |> Map.merge(meta)
          |> Map.merge(%{
            "version" => 2,
            "root" => snapshot.root,
            "prefix" => snapshot.prefix,
            "limits" => limits(opts),
            "vm" => Store.vm(),
            "before" => before
          })

        Store.put_json(path, record)

      other ->
        other
    end
  end

  @doc """
  Takes the after-snapshot of the window at `path`, replacing any earlier one.

  A snapshot that fails — the command removed `.git`, or git itself broke —
  still closes the window, with the reason in place of a tree: the command
  did finish, and undo should say why it cannot reverse it rather than call
  it unfinished.
  """
  @spec close(path :: Path.t(), opts :: keyword()) :: :ok | :skipped | {:error, term()}
  def close(path, opts) do
    case read(path) do
      %{"before" => _before, "cwd" => cwd} = record ->
        cwd
        |> Git.snapshot(Keyword.take(opts, @git_options))
        |> closed(path, record)

      _no_window ->
        :skipped
    end
  end

  defp closed({:ok, snapshot}, path, record),
    do: Store.put_json(path, Map.put(record, "after", side(snapshot)))

  defp closed(failed, path, record) do
    side = %{"error" => failure(failed), "seq" => Store.seq()}
    with :ok <- Store.put_json(path, Map.put(record, "after", side)), do: failed
  end

  defp failure(:skipped), do: "the working directory was no longer a git repository"
  defp failure({:error, :git_not_found}), do: "git was not found"
  defp failure({:error, reason}), do: "git could not snapshot it: #{inspect(reason, limit: 5)}"

  @doc """
  Closes the window at `path` if `pid` exits before anything else does.

  A cancelled or timed-out tool task is killed, not asked to stop, so the
  code that would have taken the after-snapshot never runs; this process
  outlives it to take that snapshot instead. Not linked to the task, for the
  same reason. With `supervisor:` (a `Lemieux.Supervisor` name, as a tool
  context carries) it runs under that runtime's task supervisor, so a host
  that stops the runtime stops its watchers too; a window whose watcher was
  stopped that way stays open, and undo reports its command as one whose
  changes were not recorded. Without one it is a plain process.
  """
  @spec watch(path :: Path.t(), pid :: pid(), opts :: keyword()) :: :ok
  def watch(path, pid, opts) when is_pid(pid) do
    git = Keyword.take(opts, @git_options)

    start(Keyword.get(opts, :supervisor), fn ->
      ref = Process.monitor(pid)
      watching(path, pid, ref, git)
    end)
  end

  defp start(nil, fun) do
    spawn(fun)
    :ok
  end

  defp start(runtime, fun) when is_atom(runtime) do
    tasks = Lemieux.Supervisor.task_supervisor(runtime)

    # A context naming a runtime that is not running (a host's own test
    # context) still gets its window closed.
    with pid when is_pid(pid) <- Process.whereis(tasks),
         {:ok, _watcher} <- Task.Supervisor.start_child(pid, fun) do
      :ok
    else
      _not_running_or_full -> start(nil, fun)
    end
  end

  defp start(_other, fun), do: start(nil, fun)

  defp watching(path, pid, ref, opts) do
    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        if open?(read(path)), do: close(path, opts)
    after
      @recheck_ms ->
        if open?(read(path)), do: watching(path, pid, ref, opts), else: :ok
    end
  end

  @doc """
  Waits up to `timeout_ms` for this VM's watched windows in `turn_dir` to
  close: a command cancelled a moment ago is still being snapshotted by its
  watcher, and undoing before that finishes would report it as unrecorded.
  """
  @spec await(turn_dir :: Path.t(), timeout_ms :: non_neg_integer()) :: :ok | :timeout
  def await(turn_dir, timeout_ms) do
    await_until(turn_dir, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp await_until(turn_dir, deadline) do
    vm = Store.vm()

    waiting? =
      turn_dir
      |> all()
      |> Enum.any?(&(open?(&1) and &1["watched"] == true and &1["vm"] == vm))

    cond do
      not waiting? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@await_step_ms)
        await_until(turn_dir, deadline)
    end
  end

  @doc "Every window recorded in `turn_dir`, oldest first."
  @spec all(turn_dir :: Path.t()) :: [map()]
  def all(turn_dir) do
    turn_dir
    |> directory()
    |> Store.all_json()
    |> Enum.filter(&match?(%{"before" => %{"tree" => _tree}}, &1))
    |> Enum.sort_by(&get_in(&1, ["before", "seq"]))
  end

  @doc "Whether a window's command has not been seen to finish."
  @spec open?(record :: map()) :: boolean()
  def open?(%{"before" => _before} = record), do: not Map.has_key?(record, "after")
  def open?(_record), do: false

  @doc "Whether a window has both trees, so undo can compare them."
  @spec complete?(record :: map()) :: boolean()
  def complete?(record),
    do: match?(%{"before" => %{"tree" => _}, "after" => %{"tree" => _}}, record)

  defp read(path) do
    case Store.json(path) do
      {:ok, %{} = record} -> record
      _missing -> %{}
    end
  end

  defp side(snapshot) do
    %{
      "tree" => snapshot.tree,
      "seq" => Store.seq(),
      "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "head" => %{"commit" => snapshot.head.commit, "branch" => snapshot.head.branch},
      "refs" => snapshot.refs,
      "unsaved" =>
        Enum.map(
          snapshot.unsaved,
          &[&1.path, &1.size, &1.mtime, &1.inode, Atom.to_string(&1.why)]
        ),
      "unsaved_more" => snapshot.unsaved_more
    }
  end

  defp limits(opts) do
    %{bytes: bytes, files: files} = Git.limits(opts)
    %{"bytes" => bytes, "files" => files}
  end
end
