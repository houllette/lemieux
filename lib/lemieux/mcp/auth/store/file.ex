defmodule Lemieux.MCP.Auth.Store.File do
  @moduledoc """
  Credentials in one JSON file, readable only by its owner.

  The default for `lmx`, and what an embedder gets if it does not supply
  something better. The whole file is one object of key to record; a write
  reads it, replaces one key and writes it back.

  ## The mode is the point

  The file is created with `0600` and re-asserted on every write, and a
  directory the store has to create for it is created `0700`. A refresh
  token is a longer-lived credential than the access token beside it, and a
  file readable by every process on the machine is how both leave. `lmx`
  therefore refuses nothing and asks nothing — it just never writes a
  world-readable credential, and there is a test that would fail if it did.

  Note what this does *not* claim: the file is not encrypted, so it protects
  against other users on the machine and not against the user themself or
  anything running as them. That is the same guarantee Claude Code gives on
  Linux, and the honest ceiling for a file-backed default. A host that needs
  more implements `Lemieux.MCP.Auth.Store` over a keychain.

  ## One writer at a time is assumed

  Two processes writing different keys at the same instant can lose one of the
  writes, because the read-modify-write is not atomic across processes. That is
  accepted rather than solved: writes happen when somebody authorizes or a
  token is refreshed, which is rare and generally interactive, and the cost of
  losing one is re-authorizing. Locking a file across platforms to protect a
  once-an-hour write would be the more expensive mistake. A host that runs
  many sessions against many servers concurrently should implement the
  behaviour over whatever it already uses for coordination.
  """

  @behaviour Lemieux.MCP.Auth.Store

  @mode 0o600
  @directory_mode 0o700

  @doc """
  A store keeping credentials in the file at `path`.

  `:migrate_from` names a file an earlier version kept them in. It is moved
  to `path` (`migrate/2`) the first time the store is read or written rather
  than here: building a store touches no file, so a host can build one for
  every session — and a test suite can build one over somebody's home
  directory — without moving anything that is never used.
  """
  @spec new(path :: Path.t(), opts :: keyword()) :: Lemieux.MCP.Auth.Store.t()
  def new(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case Keyword.get(opts, :migrate_from) do
      nil -> {__MODULE__, path}
      from when is_binary(from) -> {__MODULE__, %{path: path, migrate_from: from}}
    end
  end

  @doc """
  Where a host that names no path of its own keeps credentials:
  `~/.lemieux/credentials.json`.

  `lmx` used to keep its tokens here too. It now names its own file beside
  everything else it keeps (`~/.lmx/mcp-credentials.json`) and moves an
  existing one there with `migrate/2`.
  """
  @spec default_path() :: Path.t()
  def default_path, do: Path.join([System.user_home!(), ".lemieux", "credentials.json"])

  @doc """
  Moves the credentials kept at `from` to `to`, once.

  For a host that changes where it keeps them. Nothing happens when `to`
  already holds credentials — the move happened before, or the new file was
  written first, and either way it is the one in use — or will not parse,
  or when there is nothing at `from`. An empty `to` (`create/1` makes one)
  holds nothing to lose and is written over. A `from` that will not parse
  is reported and left exactly where it is, for the same reason a write
  refuses to replace one.

  The old file is removed once the new one is written rather than kept as a
  backup. A copy would not stay a working backup: a provider that rotates
  refresh tokens invalidates the old one at the first refresh. What it would
  stay is a second place a credential can be read from, and one that
  brought tokens back after somebody deleted the new file to sign out. The
  cost falls on another host still using `from`: it finds the file gone and
  authorizes its servers again.
  """
  @spec migrate(from :: Path.t(), to :: Path.t()) :: :ok | {:error, String.t()}
  def migrate(from, to) when is_binary(from) and is_binary(to) do
    if in_use?(to) or not File.regular?(from) do
      :ok
    else
      with {:ok, records} <- read(from),
           :ok <- write(to, records) do
        _ = File.rm(from)
        :ok
      end
    end
  end

  # Records in it, or a file that will not parse, which is left for a person
  # rather than written over. Absent and empty are not in use.
  defp in_use?(path) do
    case read(path) do
      {:ok, records} -> map_size(records) > 0
      {:error, _unreadable} -> true
    end
  end

  @doc """
  Creates an empty store at `path` — `{}`, `0600`, in a directory made
  `0700` when this makes it — unless something is there already.

  For a host that has to name the file before the first token arrives: a
  sandbox can hide only a path that exists when it starts, and the first
  OAuth flow writes this file mid-session. The create is exclusive, so a
  file another process wrote in the meantime is never replaced.
  """
  @spec create(path :: Path.t()) :: :ok | {:error, String.t()}
  def create(path) when is_binary(path) do
    with :ok <- mkdir(path),
         :ok <- create_empty(path) do
      :ok
    else
      {:error, reason} -> {:error, "could not create #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp create_empty(path) do
    case File.write(path, "{}", [:exclusive]) do
      :ok -> File.chmod(path, @mode)
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Lemieux.MCP.Auth.Store
  def fetch(state, key) do
    case state |> file() |> read() do
      {:ok, records} -> Map.fetch(records, key)
      # Unreadable is indistinguishable from absent to a caller that only wants
      # to know whether it has a token; the error surfaces on the next write.
      {:error, _reason} -> :error
    end
  end

  @impl Lemieux.MCP.Auth.Store
  def put(state, key, record) do
    path = file(state)

    with {:ok, records} <- read(path) do
      write(path, Map.put(records, key, record))
    end
  end

  @impl Lemieux.MCP.Auth.Store
  def delete(state, key) do
    path = file(state)

    with {:ok, records} <- read(path) do
      write(path, Map.delete(records, key))
    end
  end

  # The file to use, after the one-time move when there is one to make. A
  # legacy file that will not parse is left where it is; the servers it held
  # tokens for ask to be authorized again, which costs a browser round trip
  # rather than the credentials.
  defp file(%{path: path, migrate_from: from}) do
    _ = migrate(from, path)
    path
  end

  defp file(path) when is_binary(path), do: path

  defp read(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents, path)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # A file that will not parse is reported rather than replaced. Starting over
  # would be a silent way to throw away every credential on the machine because
  # of one stray byte.
  defp decode(contents, path) do
    case JSON.decode(contents) do
      {:ok, records} when is_map(records) ->
        {:ok, records}

      _otherwise ->
        {:error,
         "#{path} holds credentials but is not a JSON object; move it aside to start over"}
    end
  end

  defp write(path, records) do
    with :ok <- mkdir(path),
         # Written before the content, so there is no instant at which a
         # credential sits in a file the umask made world-readable.
         :ok <- touch(path),
         :ok <- File.write(path, JSON.encode!(records)) do
      File.chmod(path, @mode)
    else
      {:error, reason} -> {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Owner-only when this is what creates it; a directory that already exists
  # keeps the mode somebody gave it.
  defp mkdir(path) do
    directory = Path.dirname(path)

    if File.dir?(directory),
      do: :ok,
      else: with(:ok <- File.mkdir_p(directory), do: File.chmod(directory, @directory_mode))
  end

  defp touch(path) do
    case File.open(path, [:write, :binary]) do
      {:ok, handle} ->
        with :ok <- File.close(handle), do: File.chmod(path, @mode)

      error ->
        error
    end
  end
end
