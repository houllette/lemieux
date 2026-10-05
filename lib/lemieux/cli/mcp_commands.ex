defmodule Lemieux.CLI.MCPCommands do
  @moduledoc """
  `lmx mcp list | trust [--yes] | untrust | import claude|codex`.

  The terminal UI asks before starting a repository's `.mcp.json` servers.
  These are the same decisions for a person who works in `lmx run` or a
  script: `trust` shows what the servers would run and where they connect,
  and records the decision only with `--yes`, so a command pasted without
  reading prints the description instead of trusting anything. `import`
  copies Claude Code's or Codex's servers into the config file's
  `"mcp_servers"`, where they start for every session as the person's own.

  From Claude Code that is its user scope — the top-level `mcpServers` of
  `~/.claude.json` — and nothing else. A local-scope server
  (`projects.<path>.mcpServers`, the default scope of `claude mcp add`)
  starts in one project only and is where Claude Code keeps servers whose
  credentials stay out of version control; importing the current project's
  along with the user's once turned a production database server for one
  repository into a server every session started everywhere. They are
  named and left out instead, with where to put one that should run here.

  ## What is printed is written out

  Every name, command, argument, URL and path these commands print came
  from a file somebody else may have written, and goes through
  `Lemieux.CLI.Sanitize.visible/1`, so a control character in it shows as an
  escape instead of acting on the terminal, and each argument is
  shell-quoted (`command_line/1`), so where one ends shows too. Printed as
  they were, a cloned repository's `.mcp.json` retitled the window and wrote
  the clipboard as `lmx mcp list` ran, and an argument holding a carriage
  return and an erase-line made `lmx mcp trust` show a harmless `npx …`
  over the command it was asking about (2026-10).
  """

  alias Lemieux.CLI
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Extensions.MCP, as: MCPExtension
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.MCP.Config, as: MCPConfig
  alias Lemieux.MCP.Trust

  @switches [yes: :boolean, config: :string, project: :string]

  @doc "Runs an `mcp` subcommand, printing what it did."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts \\ []) do
    {parsed, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    config_argv = if parsed[:config], do: ["--config", parsed[:config]], else: []

    with [] <- invalid,
         {:ok, options} <- Options.parse(config_argv, command: :request) do
      command(rest, parsed, options, Keyword.get_lazy(opts, :cwd, &File.cwd!/0), opts)
    else
      [{flag, _value} | _rest] -> fail("unrecognised option #{flag}")
      {:error, message} -> fail(message)
    end
  end

  defp command(["list"], _parsed, options, cwd, _opts), do: list(options, cwd)
  defp command(["trust"], parsed, options, cwd, _opts), do: trust(options, cwd, parsed[:yes])
  defp command(["untrust"], _parsed, options, cwd, _opts), do: untrust(options, cwd)

  defp command(["import", from], parsed, options, cwd, opts),
    do: import(from, parsed, options, cwd, opts)

  defp command(_argv, _parsed, _options, _cwd, _opts),
    do:
      fail(
        "usage: lmx mcp list | lmx mcp trust [--yes] | lmx mcp untrust | lmx mcp import claude|codex"
      )

  defp list(options, cwd) do
    claimed = Runtime.claimed_mcp_names(options)
    IO.puts("Your servers (config): #{claimed |> Enum.sort() |> names()}")

    case Discovery.project_mcp_config(cwd) do
      nil -> IO.puts("This repository has no .mcp.json.")
      file -> IO.puts("#{shown(file)}: #{project_status(options, file, claimed)}")
    end
  end

  # The repository's servers as a session gets them. One that shares a name
  # with a server of the person's own is replaced by theirs, so it is listed
  # as replaced, and the trust status is over the rest: the set a decision
  # covers (`Lemieux.CLI.Runtime.claimed_mcp_names/1`).
  defp project_status(options, file, claimed) do
    case MCPConfig.read(file, source: "project") do
      {:ok, servers} ->
        {replaced, offered} = Enum.split_with(servers, &(&1["name"] in claimed))
        offered_status(options, file, offered, replaced) <> replaced_note(replaced)

      {:error, reason} ->
        "cannot be read: #{shown(reason)}"
    end
  end

  # With every server replaced there is nothing of the file's own to trust.
  defp offered_status(_options, _file, [], [_ | _]), do: "nothing of its own to start"

  defp offered_status(options, file, offered, _replaced),
    do: "#{offered |> server_names() |> names()} (#{trust_status(options, file, offered)})"

  defp replaced_note([]), do: ""

  defp replaced_note(replaced),
    do: " · replaced by your own: #{replaced |> server_names() |> names()}"

  defp server_names(servers), do: Enum.map(servers, & &1["name"])

  defp trust_status(%Options{host: %{state_dir: nil}}, _file, _servers), do: :untrusted

  defp trust_status(%Options{host: %{state_dir: dir}}, file, servers),
    do: Trust.status(dir, Path.dirname(file), servers)

  defp names([]), do: "none"
  defp names(names), do: Enum.map_join(names, ", ", &shown/1)

  defp shown(text), do: text |> to_string() |> Sanitize.visible()

  defp trust(%Options{host: %{state_dir: nil}}, _cwd, _yes),
    do:
      fail(
        "trust decisions are kept in the state directory; --config none has none (use --project-mcp)"
      )

  # Asked over exactly the servers a session would gate: a decision recorded
  # over any other set is one the session never matches
  # (`Lemieux.CLI.Runtime.claimed_mcp_names/1`).
  defp trust(options, cwd, yes?) do
    claimed = Runtime.claimed_mcp_names(options)

    case MCPExtension.project_trust(cwd, options.host.state_dir, except: claimed) do
      nil ->
        IO.puts(
          "Nothing to trust: no .mcp.json here, it is already trusted, or your own servers " <>
            "replace all of its servers."
        )

      # `Lemieux.MCP.Trust.describe/1` is one description per server, in
      # order; the server itself is what the command line is quoted from.
      pending ->
        pending.servers
        |> Enum.zip(pending.description)
        |> Enum.each(&IO.puts(describe(&1)))

        say_replaced(pending.file, claimed)
        record(options, pending, yes?)
    end
  end

  # So a server in the file that is missing from the list is not a mystery.
  defp say_replaced(file, claimed) do
    with {:ok, servers} <- MCPConfig.read(file, source: "project"),
         [_ | _] = replaced <- Enum.filter(servers, &(&1["name"] in claimed)) do
      IO.puts(
        "  Not part of this decision, replaced by your own: #{replaced |> server_names() |> names()}"
      )
    end
  end

  defp describe({server, description}) do
    target = command_line(server) || shown(description.url || "")
    env = if description.env == [], do: "", else: " · reads #{names(description.env)}"

    "  #{shown(description.name)} (#{shown(description.transport)}): #{target}#{env}"
  end

  @doc """
  What a stdio `server` runs, as the person deciding whether to run it
  should read it: the command and each argument shell-quoted
  (`Lemieux.CLI.shell_quoted/1`), so `["-y", "a b"]` is not shown as three
  words, then every control character written out
  (`Lemieux.CLI.Sanitize.visible/1`). `nil` for a server that runs no
  command. The terminal UI's trust question shows the same line.
  """
  @spec command_line(server :: map()) :: String.t() | nil
  def command_line(%{"command" => command} = server) when is_binary(command) do
    [command | server |> Map.get("args", []) |> List.wrap() |> Enum.map(&to_string/1)]
    |> Enum.map_join(" ", &CLI.shell_quoted/1)
    |> Sanitize.visible()
  end

  def command_line(_server), do: nil

  defp record(options, pending, true) do
    case Trust.record(options.host.state_dir, pending.workspace, pending.servers, :trusted) do
      :ok -> IO.puts("Trusted #{shown(pending.file)}. Its servers start in new sessions here.")
      {:error, message} -> fail(message)
    end
  end

  defp record(_options, _pending, _yes?),
    do: IO.puts("Nothing recorded. Run lmx mcp trust --yes to trust these servers.")

  defp untrust(%Options{host: %{state_dir: nil}}, _cwd),
    do: fail("--config none keeps no trust decisions")

  defp untrust(options, cwd) do
    case Discovery.project_mcp_config(cwd) do
      nil ->
        IO.puts("This repository has no .mcp.json.")

      file ->
        with :ok <- Trust.forget(options.host.state_dir, Path.dirname(file)),
             do: IO.puts("Forgot the decision for #{shown(file)}.")
    end
  end

  defp import(from, parsed, options, cwd, opts) do
    with {:ok, path} <- config_path(options),
         {:ok, servers, left_out} <- read_client(from, parsed, cwd, opts),
         :ok <- Config.update(path, &merge(&1, servers)) do
      IO.puts(
        "Imported #{length(servers)} server(s) from #{from}: #{servers |> Enum.map(& &1["name"]) |> names()}"
      )

      say_left_out(left_out)
    else
      {:error, message} -> fail(message)
    end
  end

  defp read_client("claude", parsed, cwd, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)
    file = Path.join(home, ".claude.json")
    project = Path.expand(parsed[:project] || cwd)

    with {:ok, user} <- MCPConfig.claude_code(file),
         {:ok, local} <- MCPConfig.claude_code_local(file, project) do
      {:ok, user, {project, local}}
    end
  end

  defp read_client("codex", _parsed, _cwd, opts) do
    home = Keyword.get_lazy(opts, :home, &System.user_home!/0)

    with {:ok, servers} <- MCPConfig.codex(Path.join([home, ".codex", "config.toml"])),
         do: {:ok, servers, nil}
  end

  defp read_client(other, _parsed, _cwd, _opts),
    do: {:error, "lmx mcp import reads claude or codex, not #{inspect(other)}"}

  defp say_left_out({project, [_ | _] = local}) do
    IO.puts(
      "Not imported, local to #{shown(project)} in Claude Code: #{local |> server_names() |> names()}. " <>
        "Claude Code starts these in that project only, often with its credentials; to use " <>
        "one there with lmx, add it to the repository's .mcp.json or pass --mcp-config."
    )
  end

  defp say_left_out(_nothing), do: :ok

  # Servers already in the file keep what the person wrote there.
  defp merge(settings, servers) do
    imported = Map.new(servers, &{&1["name"], written(&1)})
    Map.update(settings, "mcp_servers", imported, &Map.merge(imported, &1))
  end

  defp written(server) do
    server = Map.drop(server, ["name", "source"])

    case Map.pop(server, "transport") do
      {transport, rest} when transport in ["stdio", "http"] -> Map.put(rest, "type", transport)
      {_other, _rest} -> server
    end
  end

  defp config_path(options) do
    case Config.path(options.config) do
      nil -> {:error, "importing needs a config file; --config none has none"}
      path -> {:ok, path}
    end
  end

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
