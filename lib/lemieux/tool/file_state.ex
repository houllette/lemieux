defmodule Lemieux.Tool.FileState do
  @moduledoc """
  What a session's model has seen of each file, so `write` never replaces
  content it has not read.

  `write` replaces a whole file. A model that believes it knows what a file
  contains — because it read it an hour ago, or because it is guessing from the
  name — and writes it from memory silently discards whatever it did not know
  about: the user's edit in another window, the formatter that ran in between,
  the three hundred lines it never looked at. Nothing in the transcript says
  so, and the loss is found, if at all, much later. Claude Code refuses such a
  write, and so does Lemieux.

  So the file tools record a fingerprint (a SHA-256 of the contents) whenever
  the model sees a file — `read` of the whole file's contents, `write`, `edit`
  — and `write` refuses to replace an existing file unless the session holds a
  fingerprint for it that still matches what is on disk. The model's answer is
  to read the file, which is exactly the information it was missing. `edit`
  does not refuse: its exact-match rule already stops it changing text it has
  not seen, so a stale fingerprint there is a warning in the result rather than
  a refusal.

  ## Where the record lives

  One small process per session, started on first use under the mounted
  runtime's background supervisor and registered in its background registry
  beside the session's background commands. It monitors the session and stops
  with it, so a record never outlives the conversation it describes — and a
  resumed session starts with none, which costs one `read` per file it goes on
  to overwrite. That is deliberately the direction of the error: a record
  restored from the transcript would vouch for files that may have changed
  while nobody was running.

  A context without a session — a tool called directly by a host or a test —
  has nowhere to keep a record, and `seen/2` answers `:untracked`: the tools
  behave as they did before the rule existed rather than refusing everything.
  """

  use GenServer, restart: :temporary

  alias Lemieux.Supervisor, as: Sup

  @typedoc "A content fingerprint: the lowercase hex SHA-256 of the file's bytes."
  @type fingerprint :: String.t()

  @call_timeout 5_000

  @doc "The fingerprint of `contents`."
  @spec fingerprint(contents :: iodata()) :: fingerprint()
  def fingerprint(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  @doc """
  Records that the session in `context` has seen `path` with `fingerprint`.

  A no-op for a context that cannot be tracked (see the module docs).
  """
  @spec record(context :: map(), path :: Path.t(), fingerprint :: fingerprint()) :: :ok
  def record(context, path, fingerprint) when is_binary(path) and is_binary(fingerprint) do
    case server(context, :start) do
      {:ok, pid} -> call(pid, {:record, key(context, path), fingerprint})
      :untracked -> :ok
    end
  end

  @doc """
  What the session in `context` last saw of `path`.

  `{:ok, fingerprint}` when it has seen the file, `:unseen` when it has not,
  and `:untracked` when the context belongs to no session.
  """
  @spec seen(context :: map(), path :: Path.t()) :: {:ok, fingerprint()} | :unseen | :untracked
  def seen(context, path) when is_binary(path) do
    case server(context, :lookup) do
      {:ok, pid} -> call(pid, {:seen, key(context, path)})
      :absent -> :unseen
      :untracked -> :untracked
    end
  end

  @doc false
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts) do
    supervisor = Keyword.fetch!(opts, :supervisor)
    session_id = Keyword.fetch!(opts, :session_id)
    name = {:via, Registry, {Sup.background_registry(supervisor), {__MODULE__, session_id}}}
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :session), name: name)
  end

  @impl GenServer
  def init(session) do
    Process.monitor(session)
    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:record, key, fingerprint}, _from, seen),
    do: {:reply, :ok, Map.put(seen, key, fingerprint)}

  def handle_call({:seen, key}, _from, seen) do
    case Map.fetch(seen, key) do
      {:ok, fingerprint} -> {:reply, {:ok, fingerprint}, seen}
      :error -> {:reply, :unseen, seen}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, _session, _reason}, seen),
    do: {:stop, :normal, seen}

  # Keyed by the absolute path, so `lib/a.ex`, `./lib/a.ex` and the absolute
  # spelling of the same file are one record. Symlinks are not resolved: two
  # names for one file cost at most an extra read, never a missed refusal.
  defp key(context, path), do: Path.expand(path, context.cwd)

  defp server(%{session: session, session_id: session_id, supervisor: supervisor}, mode)
       when is_pid(session) and is_binary(session_id) and is_atom(supervisor) do
    registry = Sup.background_registry(supervisor)

    if Process.whereis(registry),
      do: lookup_or_start(registry, supervisor, session, session_id, mode),
      else: :untracked
  end

  defp server(_context, _mode), do: :untracked

  defp lookup_or_start(registry, supervisor, session, session_id, mode) do
    case {Registry.lookup(registry, {__MODULE__, session_id}), mode} do
      {[{pid, _value}], _mode} -> {:ok, pid}
      {[], :lookup} -> :absent
      {[], :start} -> start(supervisor, session, session_id)
    end
  end

  defp start(supervisor, session, session_id) do
    case DynamicSupervisor.start_child(
           Sup.background_supervisor(supervisor),
           {__MODULE__, supervisor: supervisor, session: session, session_id: session_id}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> :untracked
    end
  end

  # A record that cannot be reached — the session ended between the lookup
  # and the call — is a record that no longer exists.
  defp call(pid, message) do
    GenServer.call(pid, message, @call_timeout)
  catch
    :exit, _reason -> if match?({:seen, _key}, message), do: :unseen, else: :ok
  end
end
