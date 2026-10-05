defmodule Lemieux.MCP.Trust do
  @moduledoc """
  Whether a person has agreed to start a repository's MCP servers.

  A repository's `.mcp.json` is somebody else's configuration. A stdio server
  in it is a command run with your authority; an HTTP one is a URL sent
  whatever headers the file writes, `${VAR}` references included. Opening a
  checkout used to start them all before anybody had looked, so the one
  guarantee this module exists for is that nothing a repository declares runs
  until a person has seen it and said yes — and that saying yes once is
  enough, until the file changes.

  ## What is remembered, and why a change asks again

  A decision is kept per workspace — the directory holding the configuration
  — against a digest of the servers it declared. The digest is of what
  matters for trust: every server's name, transport, command, arguments,
  environment, URL and headers, in a canonical encoding so that key order
  never changes it. A file that gains a server, changes a command or points a
  URL somewhere new is a different file, and `status/3` says `:changed`
  rather than carrying a yes over to something nobody agreed to.

  A no is remembered too, as `:denied`, so declining does not become a
  question asked on every start; a changed file asks again.

  ## What a person is shown

  `describe/1` lists each server's name, transport, what it runs or where it
  connects, and the environment variables it reads — the names only, never
  values. Those names are what `record/4` keeps as the variables the person
  allowed, and `allowed_env/3` is how a host hands them to
  `Lemieux.MCP.expand/2`: a repository's configuration may read a
  credential-shaped variable only after somebody who could see it asked for
  one said yes.

  The store is a single JSON file in a directory the host names (`lmx` uses
  `~/.lmx`), written atomically and readable only by its owner.
  """

  @file_name "trusted-mcp.json"
  @version 1

  # What decides whether a server is the same server. `source` is where lemieux
  # read it from, not what it is, and a timeout is not a trust question.
  @material ~w(name transport type command args env cwd url headers)

  @typedoc """
  `:trusted` — agreed to, and unchanged since. `:denied` — declined, and
  unchanged since. `:changed` — decided about, but the servers are no longer
  what was decided about. `:untrusted` — never decided about.
  """
  @type status :: :trusted | :denied | :changed | :untrusted

  @typedoc "One server as a person is shown it before deciding."
  @type description :: %{
          name: String.t(),
          transport: String.t(),
          command: String.t() | nil,
          url: String.t() | nil,
          env: [String.t()]
        }

  @doc """
  What has been decided about `servers` in `workspace`.
  """
  @spec status(store :: Path.t(), workspace :: Path.t(), servers :: [map()]) :: status()
  def status(store, workspace, servers) when is_list(servers) do
    case entry(store, workspace) do
      nil ->
        :untrusted

      %{"digest" => digest, "decision" => decision} ->
        decided(digest == digest(servers), decision)

      _unreadable ->
        :untrusted
    end
  end

  defp decided(true, "trusted"), do: :trusted
  defp decided(true, "denied"), do: :denied
  defp decided(_same, _decision), do: :changed

  @doc """
  Records a decision about `servers` in `workspace`.

  A `:trusted` decision keeps the environment variable names the servers
  read (from `describe/1`), which `allowed_env/3` returns while the servers
  stay unchanged.
  """
  @spec record(
          store :: Path.t(),
          workspace :: Path.t(),
          servers :: [map()],
          decision :: :trusted | :denied
        ) :: :ok | {:error, String.t()}
  def record(store, workspace, servers, decision) when decision in [:trusted, :denied] do
    entry = %{
      "digest" => digest(servers),
      "decision" => Atom.to_string(decision),
      "env" => if(decision == :trusted, do: env_names(servers), else: []),
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    update(store, &Map.put(&1, key(workspace), entry))
  end

  @doc "Forgets whatever was decided about `workspace`."
  @spec forget(store :: Path.t(), workspace :: Path.t()) :: :ok | {:error, String.t()}
  def forget(store, workspace), do: update(store, &Map.delete(&1, key(workspace)))

  @doc """
  The environment variable names a person allowed `servers` to read.

  Empty unless the servers are trusted and unchanged: a variable allowed for
  one configuration is not allowed for the next one somebody commits.
  """
  @spec allowed_env(store :: Path.t(), workspace :: Path.t(), servers :: [map()]) :: [String.t()]
  def allowed_env(store, workspace, servers) do
    case {status(store, workspace, servers), entry(store, workspace)} do
      {:trusted, %{"env" => env}} when is_list(env) -> Enum.filter(env, &is_binary/1)
      _otherwise -> []
    end
  end

  @doc """
  A canonical digest of what makes `servers` the servers they are.

  Key order, the order the servers were listed in and where lemieux read them
  from do not change it; anything that changes what runs or where it connects
  does.
  """
  @spec digest(servers :: [map()]) :: String.t()
  def digest(servers) when is_list(servers) do
    canonical =
      servers
      |> Enum.map(&Map.take(stringify(&1), @material))
      |> Enum.sort_by(&Map.get(&1, "name", ""))
      |> canonical()

    "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
  end

  @doc """
  What a person is shown about each server before deciding. See the module
  documentation.
  """
  @spec describe(servers :: [map()]) :: [description()]
  def describe(servers) when is_list(servers) do
    Enum.map(servers, fn server ->
      server = stringify(server)

      %{
        name: to_string(Map.get(server, "name", "mcp")),
        transport: to_string(Map.get(server, "transport") || Map.get(server, "type") || "stdio"),
        command: command(server),
        url: Map.get(server, "url"),
        env: env_names([server])
      }
    end)
  end

  defp command(%{"command" => command} = server) when is_binary(command) do
    [command | server |> Map.get("args", []) |> List.wrap() |> Enum.map(&to_string/1)]
    |> Enum.join(" ")
  end

  defp command(_server), do: nil

  # Every `${NAME}` anywhere in the servers, and the variables a stdio server
  # is told to set from them. Names only: a value is never shown or stored.
  defp env_names(servers) do
    servers
    |> Enum.flat_map(&references(stringify(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp references(value) when is_binary(value) do
    ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-[^}]*)?\}/
    |> Regex.scan(value, capture: :all_but_first)
    |> List.flatten()
  end

  defp references(value) when is_list(value), do: Enum.flat_map(value, &references/1)

  defp references(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&references/1)

  defp references(_value), do: []

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  # Sorted keys at every depth, so a map's insertion order cannot change the
  # digest. JSON's own encoding of a small map happens to be ordered, but a
  # trust decision should not rest on a size threshold in the runtime.
  defp canonical(value) when is_map(value) do
    fields =
      value
      |> Enum.map(fn {key, inner} -> {to_string(key), inner} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, inner} -> [JSON.encode!(key), ":", canonical(inner)] end)
      |> Enum.intersperse(",")

    IO.iodata_to_binary(["{", fields, "}"])
  end

  defp canonical(value) when is_list(value),
    do: IO.iodata_to_binary(["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"])

  defp canonical(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: JSON.encode!(Atom.to_string(value))

  defp canonical(value), do: JSON.encode!(value)

  defp key(workspace), do: Path.expand(workspace)

  # --------------------------------------------------------------------------
  # The store
  # --------------------------------------------------------------------------

  defp path(store), do: Path.join(Path.expand(store), @file_name)

  defp entry(store, workspace) do
    case read(store) do
      {:ok, workspaces} -> Map.get(workspaces, key(workspace))
      {:error, _reason} -> nil
    end
  end

  # An unreadable store is treated as empty rather than fatal: the worst that
  # does is ask a question again, and refusing to start over a corrupt file
  # would make every repository unusable until somebody found it.
  defp read(store) do
    case File.read(path(store)) do
      {:ok, contents} ->
        case JSON.decode(contents) do
          {:ok, %{"workspaces" => workspaces}} when is_map(workspaces) -> {:ok, workspaces}
          _unreadable -> {:error, :unreadable}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update(store, fun) do
    workspaces =
      case read(store) do
        {:ok, workspaces} -> workspaces
        {:error, _reason} -> %{}
      end

    document = %{"version" => @version, "workspaces" => fun.(workspaces)}
    write(path(store), JSON.encode!(document) <> "\n")
  end

  defp write(path, contents) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, contents, [:exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end
end
