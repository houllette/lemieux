defmodule Lemieux.Extensions.MCP do
  @moduledoc """
  MCP servers from configuration files, appended to the harness.

  Three sources, all explicit:

    * `:files` — paths a person named (`lmx --mcp-config FILE`). Read as
      `"explicit"`.
    * `:servers` — configurations a host already has, such as the servers a
      person keeps in their own settings. Read as `"personal"`.
    * `:project` — a working directory whose repository root may hold a
      `.mcp.json`. Read as `"project"`: see `Lemieux.MCP.expand/2` for what a
      repository's configuration may not do.

  A library caller starting a session does not silently acquire the servers
  of whatever checkout it is running in: this extension has to be applied,
  and `:project` has to be given.

  ## A repository's servers wait for a person

  With `:trust` — a directory where `Lemieux.MCP.Trust` keeps decisions —
  a repository's servers are added only if a person has trusted exactly
  those servers before (`lmx` passes `~/.lmx`). Otherwise they are left out,
  and a notice says which servers were held back and why; `project_trust/3`
  gives a host what it needs to ask. `trusted?: true` skips the question for
  one run (`lmx run --project-mcp`). Without `:trust` a library caller that
  asked for `:project` gets the servers, as it always has.

  A server of the person's own, from `:servers` or `:files`, replaces the
  repository's server of the same name, which is neither started nor asked
  about. Where a named file and `:servers` name the same server, the file's
  is used for the run, with a notice (`Lemieux.Harness.append_mcp_servers/2`
  keeps one server per name).

  ## What is announced

  A file that cannot be read or parsed is a **notice**, not a failure. The
  session still starts, `harness.notices` says which file was ignored and
  why, and the host shows that where it shows the rest — the TUI in the
  transcript, the line hosts on standard error. Failing instead would make
  an unfamiliar repository's malformed `.mcp.json` a reason `lmx` will not
  open at all.

  A server nobody has shown the person is announced before it starts: stdio
  servers because they execute commands, HTTP servers because they receive
  whatever headers their configuration writes. That is a named file's
  servers, and a repository's when `trusted?: true` or the absence of a
  store let them through unreviewed. A repository's servers that a stored
  decision covers are not announced: the prompt that recorded it showed each
  command and URL, and saying so again on every launch told the person
  nothing. Nor are the person's own `:servers`. The HTTP notice names the
  host rather than the URL, since a URL can carry a token in its query. When
  there is nothing to add the servers are left untouched, so a resume keeps
  what its transcript recorded.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.MCP.Config
  alias Lemieux.MCP.Trust

  @type state :: %{
          files: [Path.t()],
          servers: [map()],
          notices: [String.t()],
          held: [String.t()]
        }

  @typedoc "What a host needs to ask a person about a repository's servers."
  @type pending :: %{
          file: Path.t(),
          workspace: Path.t(),
          servers: [map()],
          status: Trust.status(),
          description: [Trust.description()]
        }

  @impl Lemieux.Extension
  @spec init(
          opts :: [
            files: [Path.t()],
            servers: [map()],
            project: Path.t() | nil,
            trust: Path.t() | nil,
            trusted?: boolean()
          ]
        ) :: {:ok, state()}
  def init(opts) do
    explicit = Enum.map(Keyword.get(opts, :files, []), &{&1, "explicit"})

    personal =
      opts
      |> Keyword.get(:servers, [])
      |> Enum.map(&Map.put_new(Lemieux.MCP.config(&1), "source", "personal"))

    {named, notices} =
      Enum.reduce(explicit, {[], []}, fn {file, source}, {servers, notices} ->
        case Config.read(file, source: source) do
          {:ok, read} -> {servers ++ read, notices ++ startup_notices(file, read)}
          {:error, reason} -> {servers, notices ++ [reason]}
        end
      end)

    # A file named for this run comes first, so its server is the one used
    # where the person's settings name the same server
    # (`Lemieux.Harness.append_mcp_servers/2` keeps the first): the run's
    # instruction over the standing configuration, as a flag over a setting.
    servers = named ++ personal
    claimed = MapSet.new(servers, & &1["name"])
    {project, project_notices, held} = project(Keyword.get(opts, :project), opts, claimed)

    {:ok,
     %{
       files: Enum.map(explicit, &elem(&1, 0)) ++ Enum.map(project, & &1.file),
       servers: servers ++ Enum.flat_map(project, & &1.servers),
       notices: notices ++ project_notices,
       held: held
     }}
  end

  # A repository's configuration: read, then gated on trust when a store was
  # given. Returns what to add, what to say, and the names held back.
  defp project(nil, _opts, _claimed), do: {[], [], []}

  defp project(cwd, opts, claimed) when is_binary(cwd) do
    case Discovery.project_mcp_config(cwd) do
      nil ->
        {[], [], []}

      file ->
        case Config.read(file, source: "project") do
          {:ok, servers} -> servers |> unclaimed(claimed) |> gated(file, opts)
          {:error, reason} -> {[], [reason], []}
        end
    end
  end

  # A server the person configured, personally or by `--mcp-config`, wins over
  # the repository's server of the same name. The repository's is dropped
  # before trust is asked about, so neither the trust prompt nor the session
  # sees two servers with one name, and a trust decision covers exactly the
  # servers that would start. A host that asks the question itself passes
  # the same names to `project_trust/3` as `:except`.
  defp unclaimed(servers, claimed), do: Enum.reject(servers, &MapSet.member?(claimed, &1["name"]))

  defp gated([], _file, _opts), do: {[], [], []}

  defp gated(servers, file, opts) do
    case trust(file, servers, opts) do
      # A stored review covered exactly these servers, and the prompt that
      # recorded it showed each command and URL. A notice on every launch
      # after that repeats what the person already approved.
      :reviewed ->
        {[%{file: file, servers: servers}], [], []}

      # Trusted for this run by `--project-mcp`, or by a host with no trust
      # store: nothing has shown the person what starts, so it is said here.
      :unreviewed ->
        {[%{file: file, servers: servers}], startup_notices(file, servers), []}

      held ->
        {[], [held_notice(file, servers, held)], Enum.map(servers, & &1["name"])}
    end
  end

  defp trust(file, servers, opts) do
    store = Keyword.get(opts, :trust)

    cond do
      Keyword.get(opts, :trusted?, false) -> :unreviewed
      is_nil(store) -> :unreviewed
      true -> reviewed(Trust.status(store, Path.dirname(file), servers))
    end
  end

  defp reviewed(:trusted), do: :reviewed
  defp reviewed(held), do: held

  defp held_notice(file, servers, status) do
    names = Enum.map_join(servers, ", ", & &1["name"])

    why =
      case status do
        :denied -> "you declined them"
        :changed -> "the file changed since you trusted it"
        :untrusted -> "they have not been reviewed"
      end

    "MCP servers from #{file} were not started because #{why}: #{names}. " <>
      "Review them before trusting the repository's servers."
  end

  @doc """
  What a host needs to ask a person about the repository's servers, or `nil`.

  `nil` when there is no project configuration, when it cannot be read (the
  extension already reports that as a notice), or when it is trusted. The
  `:workspace` is what `Lemieux.MCP.Trust.record/4` takes, and `:description`
  is what to show.

  `:except` names the servers the host's own configuration claims. The
  repository's servers of those names are left out, as the extension leaves
  them out, so the prompt never asks about a server that will not run. The
  trust decision covers exactly the servers asked about.
  """
  @spec project_trust(cwd :: Path.t(), store :: Path.t(), opts :: [except: [String.t()]]) ::
          pending() | nil
  def project_trust(cwd, store, opts \\ []) do
    claimed = MapSet.new(Keyword.get(opts, :except, []))

    with file when is_binary(file) <- Discovery.project_mcp_config(cwd),
         {:ok, read} <- Config.read(file, source: "project"),
         [_ | _] = servers <- unclaimed(read, claimed),
         workspace = Path.dirname(file),
         status when status != :trusted <- Trust.status(store, workspace, servers) do
      %{
        file: file,
        workspace: workspace,
        servers: servers,
        status: status,
        description: Trust.describe(servers)
      }
    else
      _nothing_to_ask -> nil
    end
  end

  defp startup_notices(file, servers) do
    stdio =
      servers
      |> Enum.filter(&(&1["transport"] == "stdio"))
      |> Enum.map(& &1["name"])

    http =
      servers
      |> Enum.filter(&(&1["transport"] == "http"))
      |> Enum.map(&"#{&1["name"]} (#{host(&1["url"])})")

    [
      if(stdio != [],
        do: "Stdio MCP servers from #{file} execute commands: #{Enum.join(stdio, ", ")}."
      ),
      if(http != [], do: "HTTP MCP servers from #{file} connect to: #{Enum.join(http, ", ")}.")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp host(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _unparsed -> "an unparseable URL"
    end
  end

  defp host(_url), do: "no URL"

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %{servers: servers, notices: notices}) do
    harness
    |> Harness.append_mcp_servers(servers)
    |> Map.update!(:notices, &(&1 ++ notices))
  end

  @impl Lemieux.Extension
  def describe(%{files: files, servers: servers} = state) do
    description = %{"files" => files, "servers" => Enum.map(servers, &Map.get(&1, "name"))}

    case Map.get(state, :held, []) do
      [] -> description
      held -> Map.put(description, "held", held)
    end
  end
end
