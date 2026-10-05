defmodule Lemieux.Store.JSONL do
  @moduledoc """
  A `Lemieux.Store` that keeps one JSON-lines file per session in a directory.

  This is the store `lmx` uses, and the one an embedder gets for free before
  it has opinions. A session lives at `<dir>/<session_id>.jsonl`, one
  `Lemieux.Entry` per line.

  ## Why a file of lines

  Append-only text is the format that makes the cheap operations cheap. Adding
  an entry is one `write` with `O_APPEND` and no read-modify-write, so a
  process crash mid-session loses at most the entry being written — there is
  no index to corrupt and no half-updated document. A short final write can
  leave a torn last line; reads ignore only that invalid tail while still
  rejecting corruption anywhere in the committed prefix. This is process
  durability, not an `fsync` promise against power loss.

  ## A torn tail is sealed before the next append

  Tolerating a torn tail on read is only half of surviving one. The next
  append used to land on the end of the fragment, so the fragment and the
  first new entry became one line in the middle of the file — the corruption
  a read refuses — and a session that had survived the crash was lost to
  resume and fork one entry later. So every append first looks at the last
  byte: a file that does not end in a newline has its tail either completed
  (it was a whole entry missing only its newline, which a read already
  returned and a resumed session is already building on) or cut back to the
  last complete line (it was a fragment nobody ever read).

  ## Readable by its owner alone

  A transcript holds whole prompts, tool output and the contents of every
  file the agent read, `.env` included when it read one. So each transcript
  is `0600`, the mode lmx gives its config file and its tokens: a new one is
  created empty and made private before its first line is written, and one
  an earlier build left more open is tightened at its next write. A
  directory the store creates for itself is `0700`. A directory that already
  existed keeps the mode it has: `LMX_SESSIONS_DIR` or `JSONL.new/1` can
  name a shared one — `/tmp`, a project — and a store that ran as root used
  to chmod those `0700` too, sticky bit and all, shutting every other user
  out (2026-10, found in review). The transcripts in it are private either
  way. Windows has no such modes, and nothing there is changed.

  ## One writer, enforced

  `Lemieux.Store` promises nothing about two writers, because a session has
  one: its process. Two OS processes resuming the same id — two terminals,
  a script and a person — are two sessions with one transcript, and their
  appends interleave into a conversation neither of them had. `lock/2`
  claims `<id>.lock` beside the transcript with the holder's host, OS pid,
  the time that OS process started and its Erlang pid; a live holder is
  refused with its description, a dead one is taken over. Liveness is
  checked, not assumed from age, because an idle session can legitimately
  hold its transcript for a day — and the start time is checked with the
  pid, because a pid outlives its process as a number the system gives to
  the next one. A session releases its claim when it stops; a VM that halts
  or is killed leaves the file, and the next claim takes it over.
  Reading a session back is a fold over lines. And the file stays legible to
  everything else on the machine: `grep`, `tail -f`, `jq`. A transcript you
  can read with the tools you already have is one you will actually look at
  when a session goes wrong.

  The obvious alternative — one JSON document per session, rewritten on every
  entry — costs a full serialise per append and turns a crash into a lost
  session rather than a lost line.

  ## No process

  The store holds no state beyond its directory, so there is nothing to start
  and nothing to supervise. Ordering comes from the single writer above it
  (see `Lemieux.Store`), not from serialising through a process here.
  """

  @behaviour Lemieux.Store

  import Bitwise

  alias Lemieux.Entry
  alias Lemieux.Transcript.Dedup

  @extension ".jsonl"
  @lock_extension ".lock"

  # Owner-only, as lmx keeps its config file and its tokens.
  @file_mode 0o600
  @directory_mode 0o700

  # How far back a torn tail is searched for per read. An entry is rarely more
  # than a few hundred kilobytes, and a tail is at most one entry.
  @tail_chunk 65_536

  # Attempts at claiming a lock: one for the ordinary case, and a retry each
  # for a stale holder removed and a holder that released while we looked.
  @lock_attempts 3

  # Deliberately narrow: this id becomes a path segment, and it arrives from a CLI
  # argument or an embedder's API. Anything outside this set is refused rather than
  # sanitised, because a store that quietly rewrites the id it was handed reads back
  # nothing under the id the caller believes it used.
  @valid_id ~r/\A[A-Za-z0-9_-]+\z/

  @doc """
  Builds a store over `dir`.

  The directory is created on first write, not here, so a store can be
  constructed anywhere — including in a test that never writes.
  """
  @spec new(dir :: Path.t()) :: Lemieux.Store.t()
  def new(dir) when is_binary(dir), do: {__MODULE__, %{dir: dir}}

  @impl Lemieux.Store
  def append(state, session_id, entries) do
    with {:ok, path} <- path(state, session_id) do
      write(path, entries)
    end
  end

  @impl Lemieux.Store
  def read(state, session_id) do
    with {:ok, path} <- path(state, session_id),
         {:ok, contents} <- read_file(path) do
      # Large values written once and referenced after (see
      # `Lemieux.Transcript.Dedup`) are put back here, so every reader of this
      # store — resume, fork, `lmx log`, a front end's history — sees the
      # payloads that were built, not the references that were written.
      {:ok, contents |> decode() |> Dedup.expand()}
    end
  rescue
    # `Lemieux.Entry` raises on a line this build cannot understand, and that refusal
    # is right: a reader that skipped what it did not recognise would hand the model a
    # conversation missing its middle. What was wrong was the shape of the refusal —
    # `read/2` promises `{:ok, _} | {:error, _}`, so an escaping exception made every
    # caller's error handling a lie, and the caller that mattered was `lmx --resume`
    # answering a person with a stacktrace.
    #
    # This is the seam a schema migration goes through: a build that learns to read
    # version N-1 does it in `Lemieux.Entry.from_json!/1`.
    error -> {:error, {:unreadable, session_id, Exception.message(error)}}
  end

  @impl Lemieux.Store
  def list_sessions(%{dir: dir}) do
    ids =
      dir
      |> Path.join("*" <> @extension)
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, @extension))
      |> Enum.sort()

    {:ok, ids}
  end

  @doc """
  Claims `session_id`'s transcript for the calling process.

  Returns an opaque lock for `unlock/3`, or `{:error, {:locked, holder}}`
  when a live process holds it. `holder` says who: `"host"`, `"os_pid"`,
  `"process"`, `"since"` and the lock file's `"path"`. A holder that can be
  proved dead — this VM's process gone, or an OS process on this machine
  that no longer exists — is taken over. A holder on another host cannot be
  checked, so it is refused; delete the lock file if you know it is stale.
  """
  @impl Lemieux.Store
  @spec lock(state :: map(), session_id :: String.t()) ::
          {:ok, map()} | {:error, {:locked, map()} | term()}
  def lock(state, session_id) do
    # The lock is usually the first file a session writes, so this is where
    # the directory is made — private, as `write/2` would make it.
    with {:ok, path} <- lock_path(state, session_id),
         :ok <- private_directory(Path.dirname(path)) do
      claim(path, holder(), @lock_attempts)
    end
  end

  @doc """
  Releases a lock `lock/2` returned.

  Only a lock file still carrying this lock's token is removed: a holder
  that was taken over as stale must not delete its successor's claim on
  the way out.
  """
  @impl Lemieux.Store
  @spec unlock(state :: map(), session_id :: String.t(), lock :: map() | nil) :: :ok
  def unlock(_state, _session_id, %{path: path, token: token}) do
    case read_holder(path) do
      {:ok, %{"token" => ^token}} -> _ = File.rm(path)
      _other -> :ok
    end

    :ok
  end

  def unlock(_state, _session_id, _lock), do: :ok

  defp write(_path, []), do: :ok

  defp write(path, entries) do
    lines = Enum.map(entries, &[Entry.encode!(&1), ?\n])

    with :ok <- private_directory(Path.dirname(path)),
         :ok <- seal(path) do
      # One append per batch rather than one per entry: O_APPEND makes a
      # single write atomic against other appenders, so a batch either lands
      # whole or not at all.
      File.write(path, lines, [:append])
    end
  end

  # The moduledoc's "readable by its owner alone": the directory is made
  # private when this is what makes it, and left as it is when it exists —
  # it may be somebody's `/tmp`. One `mkdir` per write on the common path,
  # where it already exists. Missing parents are made with the umask's mode,
  # as `mkdir -p` would; only the store's own directory is private.
  defp private_directory(dir) do
    case File.mkdir(dir) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(dir)), do: made(File.mkdir(dir), dir)

      made ->
        made(made, dir)
    end
  end

  defp made(:ok, dir), do: make_private(dir, @directory_mode)
  defp made({:error, :eexist}, _dir), do: :ok
  defp made({:error, reason}, _dir), do: {:error, reason}

  defp posix?, do: match?({:unix, _flavour}, :os.type())

  # The moduledoc's "sealed before the next append". A stat and a one-byte read
  # per append is the whole cost on the path that has nothing to repair. A
  # transcript is created empty and made 0600 before anything is written
  # into it, so no line of it ever sits in a file the umask left readable.
  defp seal(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode} = stat} ->
        if (mode &&& 0o077) != 0, do: make_private(path, @file_mode)
        seal(path, stat)

      {:error, :enoent} ->
        create_private(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp seal(_path, %File.Stat{size: 0}), do: :ok
  defp seal(path, %File.Stat{size: size}), do: with_file(path, &seal_tail(&1, size))

  defp create_private(path) do
    case File.write(path, "", [:exclusive]) do
      :ok -> make_private(path, @file_mode)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Best effort: a filesystem that keeps no POSIX modes (a mounted share)
  # refuses the chmod, and refusing the transcript with it would lose the
  # session over a mode the filesystem never had.
  defp make_private(path, mode) do
    if posix?(), do: File.chmod(path, mode)
    :ok
  end

  defp seal_tail(fd, size) do
    case :file.pread(fd, size - 1, 1) do
      {:ok, "\n"} -> :ok
      {:ok, _byte} -> repair(fd, size)
      :eof -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # A whole entry that lost only its newline is kept, because `decode/1` already
  # returns it: a resumed session is building on it, and cutting it would leave
  # that session's next entry pointing at a parent the file no longer holds.
  # Anything else after the last newline is a fragment and is cut.
  defp repair(fd, size) do
    cut = last_line_end(fd, size)

    with {:ok, tail} <- :file.pread(fd, cut, size - cut) do
      if complete_entry?(tail), do: append_newline(fd, size), else: truncate(fd, cut)
    end
  end

  defp append_newline(fd, size), do: :file.pwrite(fd, size, "\n")

  defp truncate(fd, cut) do
    with {:ok, ^cut} <- :file.position(fd, cut), do: :file.truncate(fd)
  end

  defp complete_entry?(line) do
    _entry = Entry.decode!(line)
    true
  rescue
    _error -> false
  end

  # The offset just past the last newline before `position`, or zero when the
  # file is one unterminated line.
  defp last_line_end(_fd, position) when position <= 0, do: 0

  defp last_line_end(fd, position) do
    start = max(position - @tail_chunk, 0)

    case :file.pread(fd, start, position - start) do
      {:ok, chunk} ->
        case :binary.matches(chunk, "\n") do
          [] -> last_line_end(fd, start)
          matches -> start + (matches |> List.last() |> elem(0)) + 1
        end

      _eof_or_error ->
        0
    end
  end

  defp with_file(path, fun) do
    case :file.open(path, [:read, :write, :binary, :raw]) do
      {:ok, fd} ->
        try do
          fun.(fd)
        after
          :file.close(fd)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim(_path, _holder, 0), do: {:error, :lock_contended}

  defp claim(path, holder, attempts) do
    case create_exclusively(path, holder) do
      :ok ->
        {:ok, %{path: path, token: holder["token"]}}

      {:error, :eexist} ->
        claim_held(path, holder, attempts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_held(path, holder, attempts) do
    case read_holder(path) do
      {:ok, current} ->
        if live?(current) do
          {:error, {:locked, current |> Map.put("path", path) |> Map.delete("token")}}
        else
          # Re-read before removing, so a holder that replaced the stale file
          # since the first read is not the one deleted.
          remove_if_unchanged(path, current)
          claim(path, holder, attempts - 1)
        end

      {:error, :enoent} ->
        claim(path, holder, attempts - 1)

      {:error, _unreadable} ->
        # Written whole by `create_exclusively/2`, so an unreadable lock was not
        # written by this code and has no holder a check could find.
        _ = File.rm(path)
        claim(path, holder, attempts - 1)
    end
  end

  # A complete file linked into place: the lock never exists half-written, so a
  # second claimant cannot read an empty file and take it for a stale one.
  # A filesystem without hard links gets an exclusive create instead.
  defp create_exclusively(path, holder) do
    contents = JSON.encode!(holder)
    temporary = path <> "." <> holder["token"]

    with :ok <- File.write(temporary, contents, [:exclusive]) do
      result =
        case File.ln(temporary, path) do
          :ok -> :ok
          {:error, :eexist} -> {:error, :eexist}
          {:error, _no_links} -> File.write(path, contents, [:exclusive])
        end

      _ = File.rm(temporary)
      result
    end
  end

  defp remove_if_unchanged(path, current) do
    case read_holder(path) do
      {:ok, ^current} -> _ = File.rm(path)
      _changed -> :ok
    end
  end

  defp read_holder(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{} = holder} <- JSON.decode(contents) do
      {:ok, holder}
    else
      {:ok, _not_a_map} -> {:error, :invalid_lock}
      {:error, :enoent} -> {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp holder do
    %{
      "token" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      "host" => hostname(),
      "os_pid" => System.pid(),
      "os_started" => own_start(),
      "node" => Atom.to_string(node()),
      "process" => self() |> :erlang.pid_to_list() |> List.to_string(),
      "since" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # This VM's own start never changes, and on macOS reading it is a fork, so
  # it is read once per VM.
  defp own_start do
    case :persistent_term.get({__MODULE__, :own_start}, :unread) do
      :unread ->
        started = os_started(System.pid())
        :persistent_term.put({__MODULE__, :own_start}, started)
        started

      started ->
        started
    end
  end

  @doc false
  # When the OS process `os_pid` started, as a string compared only with
  # another reading of the same kind, or `nil` where it cannot be read.
  # Public so a test can write a lock the way another VM would.
  #
  # A process id names a process only while it lives: the system hands it to
  # the next process once it is free. A lock left by an lmx that exited with
  # the lock still on disk — every exit did, before sessions released theirs —
  # names a pid that some later process may hold, and `kill -0` then calls it
  # alive: `--continue` refused with "open in another lmx" for a terminal
  # closed hours before. The start time tells the two apart.
  #
  # On Linux it is `/proc`'s start in clock ticks since boot, prefixed with
  # the boot's id so a reboot cannot line two up: exact, and the same for
  # every reader. Elsewhere it is `ps -o lstart`, a wall-clock time to the
  # second, read in the C locale and in UTC. `ps` prints local time, and two
  # readers in different time zones — a script with `TZ` set, a laptop that
  # changed zones while lmx was open — read one process's start as two
  # strings: a second lmx then took over the lock of a live session (2026-10,
  # found in review). Pinning the zone makes one process one string; see
  # `reused?/1` for why a difference is still checked against the clock.
  @spec os_started(os_pid :: String.t()) :: String.t() | nil
  def os_started(os_pid) when is_binary(os_pid) do
    if os_pid =~ ~r/\A[0-9]+\z/, do: os_started(:os.type(), os_pid)
  end

  # Field 22 of `/proc/PID/stat`, counted after the process name — which is
  # parenthesised and may itself contain `)`, so the split is on the last one.
  # Without the boot's id there is no reading: one with it and one without
  # would be two strings for one process.
  defp os_started({:unix, :linux}, os_pid) do
    with {:ok, boot} <- File.read("/proc/sys/kernel/random/boot_id"),
         {:ok, stat} <- File.read("/proc/" <> os_pid <> "/stat"),
         fields when length(fields) > 19 <-
           stat |> String.split(")") |> List.last() |> String.split() do
      "linux:" <> String.trim(boot) <> ":" <> Enum.at(fields, 19)
    else
      _unreadable -> nil
    end
  end

  defp os_started({:unix, _flavour}, os_pid) do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         {output, 0} <-
           System.cmd(ps, ["-o", "lstart=", "-p", os_pid],
             env: [{"LC_ALL", "C"}, {"TZ", "UTC0"}],
             stderr_to_stdout: true
           ),
         started when started != "" <- String.trim(output) do
      started
    else
      _unavailable -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp os_started(_windows, _os_pid), do: nil

  # `:inet.gethostname/0` always answers `{:ok, name}`.
  defp hostname do
    {:ok, name} = :inet.gethostname()
    List.to_string(name)
  end

  # Live unless proved dead. A lock wrongly refused costs a person deleting a
  # file; a lock wrongly taken over costs two writers in one transcript.
  #
  # A pid given to another process since the lock was written is proof that
  # its writer is gone (`reused?/1`). That is asked first, because an earlier
  # VM can have had this VM's own pid, and its Erlang process id then names
  # whatever process holds that number here. A start time that cannot be
  # read now proves nothing, and the pid alone decides, as it did for locks
  # written before start times were recorded.
  defp live?(%{"host" => host} = holder) do
    cond do
      host != hostname() -> true
      reused?(holder) -> false
      same_vm?(holder) -> local_process_alive?(holder["process"])
      true -> os_process_alive?(holder["os_pid"])
    end
  end

  defp live?(_holder), do: true

  # The recorded start differs from the one the pid has now, and — for a
  # wall-clock reading — the process holding the pid now started after the
  # lock was taken, which the process that took it cannot have. A string
  # comparison alone took over a live session's lock once, when two readers
  # disagreed about the time zone (`os_started/1`); a difference nobody
  # foresaw costs, this way, a refusal rather than two writers.
  defp reused?(%{"os_pid" => os_pid, "os_started" => recorded} = holder)
       when is_binary(os_pid) and is_binary(recorded) do
    current = if os_pid == System.pid(), do: own_start(), else: os_started(os_pid)
    is_binary(current) and current != recorded and started_after?(current, holder["since"])
  end

  defp reused?(_holder), do: false

  # Ticks since this boot name one process; another reading is another process.
  defp started_after?("linux:" <> _exact, _since), do: true

  defp started_after?(lstart, since) when is_binary(since) do
    with {:ok, started} <- parse_lstart(lstart),
         {:ok, taken, _offset} <- DateTime.from_iso8601(since) do
      DateTime.after?(started, taken)
    else
      _unparsable -> false
    end
  end

  defp started_after?(_lstart, _since), do: false

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

  # `ps -o lstart` in the C locale and UTC: `Sun Oct  4 05:13:17 2026`.
  defp parse_lstart(lstart) do
    with [_all, month, day, time, year] <-
           Regex.run(~r/\A[A-Z][a-z]{2} +([A-Z][a-z]{2}) +(\d{1,2}) ([\d:]{8}) (\d{4})\z/, lstart),
         index when is_integer(index) <- Enum.find_index(@months, &(&1 == month)),
         {:ok, date} <-
           Date.new(String.to_integer(year), index + 1, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time) do
      DateTime.new(date, time, "Etc/UTC")
    else
      _unparsable -> :error
    end
  end

  defp same_vm?(holder),
    do: holder["os_pid"] == System.pid() and holder["node"] == Atom.to_string(node())

  defp local_process_alive?(process) when is_binary(process) do
    process |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
  rescue
    ArgumentError -> false
  end

  defp local_process_alive?(_process), do: false

  defp os_process_alive?(os_pid) when is_binary(os_pid) do
    if os_pid =~ ~r/\A[0-9]+\z/, do: os_pid_alive?(:os.type(), os_pid), else: true
  end

  defp os_process_alive?(_os_pid), do: true

  defp os_pid_alive?({:unix, :linux}, os_pid), do: File.exists?("/proc/" <> os_pid)

  defp os_pid_alive?({:unix, _flavour}, os_pid) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      # EPERM: the process exists and belongs to somebody else.
      {output, _status} -> String.contains?(String.downcase(output), "not permitted")
    end
  rescue
    ErlangError -> true
  end

  defp os_pid_alive?({:win32, _flavour}, os_pid) do
    case System.cmd("tasklist", ["/FI", "PID eq #{os_pid}", "/NH"], stderr_to_stdout: true) do
      {output, 0} -> String.contains?(output, " " <> os_pid <> " ")
      _failed -> true
    end
  rescue
    ErlangError -> true
  end

  defp lock_path(%{dir: dir}, session_id) when is_binary(session_id) do
    if Regex.match?(@valid_id, session_id) do
      {:ok, Path.join(dir, session_id <> @lock_extension)}
    else
      {:error, {:invalid_session_id, session_id}}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(contents) do
    lines = String.split(contents, "\n", trim: false)
    {prefix, [tail]} = Enum.split(lines, -1)
    entries = prefix |> Enum.reject(&(&1 == "")) |> Enum.map(&Entry.decode!/1)

    case tail do
      "" -> entries
      line -> decode_tail(entries, line)
    end
  end

  defp decode_tail(entries, line) do
    entries ++ [Entry.decode!(line)]
  rescue
    _error -> entries
  end

  defp path(%{dir: dir}, session_id) when is_binary(session_id) do
    if Regex.match?(@valid_id, session_id) do
      {:ok, Path.join(dir, session_id <> @extension)}
    else
      {:error, {:invalid_session_id, session_id}}
    end
  end
end
