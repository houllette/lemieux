defmodule Lemieux.MCP.Config do
  @moduledoc """
  Reading a file that says which MCP servers to attach.

  Accepts the shape every other client already uses — an object of server
  names to configurations, under `mcpServers` — because people have these
  files already and asking them to write a second one in a different shape to
  say the same thing is a poor way to be new:

      {
        "mcpServers": {
          "github": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-github"],
            "env": {"GITHUB_TOKEN": "..."}
          },
          "docs": { "url": "https://example.com/mcp" }
        }
      }

  A bare object without the `mcpServers` wrapper is accepted too.

  The transport is Claude Code's `"type"` (`stdio`, `http`, or the legacy
  `sse`, which is refused at connect time with directions) when present, else
  inferred: a `url` means HTTP, a `command` means stdio. lemieux's own
  `"transport"` still works and wins — including a name this module has never
  heard of, which is kept as written. Whether a transport exists is decided by
  the registry at connect time (`Lemieux.MCP.transports/0` and whatever the
  host merged over it), not here: a file cannot know what the host registered,
  and refusing the name would mean editing this module for every transport a
  host adds.

  ## Importing another client's servers

  `claude_code/2` reads the servers Claude Code keeps in `~/.claude.json` —
  the user's own, and a project's local ones — and `codex/1` those Codex keeps
  in `~/.codex/config.toml`. Both mark what they read as `"personal"`: it is
  somebody's own setup, not a repository's (see `Lemieux.MCP.expand/2` for
  why the difference matters).
  """

  alias Lemieux.MCP
  alias Lemieux.MCP.Config.TOML

  @doc """
  Reads a config file into a list of server configurations.

  `source:` marks every server with where it came from — `"project"` for a
  repository's `.mcp.json`, `"personal"`, `"explicit"` — which decides what its
  `${VAR}` references may read.
  """
  @spec read(path :: Path.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def read(path, opts \\ []) do
    with {:ok, contents} <- read_file(path),
         {:ok, json} <- decode(contents, path) do
      {:ok, json |> servers() |> mark(Keyword.get(opts, :source))}
    end
  end

  @doc """
  Reads server configurations out of an already-decoded JSON object.

  The same shape `read/2` accepts — an object of server names to
  configurations, with or without the `mcpServers` wrapper — for a host that
  keeps servers inside a larger document of its own, as `lmx` does in its
  config file's `"mcp_servers"`. `source:` marks them as `read/2` does.
  """
  @spec parse(json :: map(), opts :: keyword()) :: [map()]
  def parse(json, opts \\ []) when is_map(json) do
    json |> servers() |> mark(Keyword.get(opts, :source))
  end

  defp mark(servers, nil), do: servers
  defp mark(servers, source), do: Enum.map(servers, &Map.put(&1, "source", to_string(source)))

  @doc """
  Reads Claude Code's own server configuration.

  `path` is its `~/.claude.json`. The servers at the top level are the
  user's; with `project:` a directory, that project's local servers (Claude
  Code's `projects.<path>.mcpServers`) are added, winning on a name clash as
  they do there — the set Claude Code itself starts in that project. A
  local-scope server belongs to that one project and often carries its
  credentials, so a caller copying servers somewhere they apply to every
  project reads the user's alone and names the rest
  (`claude_code_local/2`). Everything read is marked `"personal"`.
  """
  @spec claude_code(path :: Path.t(), opts :: keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def claude_code(path, opts \\ []) do
    with {:ok, json} <- claude_json(path) do
      user = json |> Map.get("mcpServers", %{}) |> object()

      local =
        case Keyword.get(opts, :project) do
          nil -> %{}
          project -> local_servers(json, project)
        end

      {:ok, user |> Map.merge(local) |> Enum.map(&server/1) |> mark("personal")}
    end
  end

  @doc """
  The servers Claude Code keeps for one project only — its local scope,
  `projects.<path>.mcpServers` in `~/.claude.json` — marked `"personal"`.

  Claude Code starts them only in that project, and uses that scope for
  servers whose credentials should stay out of version control; see
  `claude_code/2`.
  """
  @spec claude_code_local(path :: Path.t(), project :: Path.t()) ::
          {:ok, [map()]} | {:error, String.t()}
  def claude_code_local(path, project) when is_binary(project) do
    with {:ok, json} <- claude_json(path) do
      {:ok, json |> local_servers(project) |> Enum.map(&server/1) |> mark("personal")}
    end
  end

  defp claude_json(path) do
    with {:ok, contents} <- read_file(path), do: decode(contents, path)
  end

  defp local_servers(json, project) do
    with %{} = projects <- Map.get(json, "projects"),
         %{} = entry <- Map.get(projects, Path.expand(project)) do
      entry |> Map.get("mcpServers") |> object()
    else
      _none -> %{}
    end
  end

  defp object(value) when is_map(value), do: value
  defp object(_value), do: %{}

  @doc """
  Reads the MCP servers Codex keeps in `~/.codex/config.toml`.

  Each `[mcp_servers.NAME]` table becomes a server: `command`, `args`, `env`
  and `cwd` for a stdio one; `url`, `http_headers`, `env_http_headers` and
  `bearer_token_env_var` for an HTTP one, the variables written as `${VAR}` so
  they are read when the server connects and never stored.
  `startup_timeout_sec`/`startup_timeout_ms` and `tool_timeout_sec` become the
  per-server budgets `Lemieux.MCP.connect/2` reads. A server with
  `enabled = false` is left out. Everything read is marked `"personal"`.
  """
  @spec codex(path :: Path.t()) :: {:ok, [map()]} | {:error, String.t()}
  def codex(path) do
    with {:ok, contents} <- read_file(path),
         {:ok, document} <- decode_toml(contents, path) do
      servers =
        document
        |> Map.get("mcp_servers", %{})
        |> object()
        |> Enum.filter(fn {_name, table} ->
          is_map(table) and Map.get(table, "enabled", true) != false
        end)
        |> Enum.sort_by(fn {name, _table} -> name end)
        |> Enum.map(fn {name, table} -> table |> codex_server() |> Map.put("name", name) end)
        |> Enum.map(&MCP.config/1)

      {:ok, mark(servers, "personal")}
    end
  end

  defp decode_toml(contents, path) do
    case TOML.decode(contents) do
      {:ok, document} -> {:ok, document}
      {:error, reason} -> {:error, "#{path} is not TOML this reader understands (#{reason})"}
    end
  end

  defp codex_server(table) do
    base =
      table
      |> Map.take(["command", "args", "env", "cwd", "url"])
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    headers =
      Map.merge(
        table |> Map.get("http_headers", %{}) |> object(),
        table
        |> Map.get("env_http_headers", %{})
        |> object()
        |> Map.new(fn {header, variable} -> {header, "${#{variable}}"} end)
      )

    headers =
      case Map.get(table, "bearer_token_env_var") do
        variable when is_binary(variable) ->
          Map.put(headers, "authorization", "Bearer ${#{variable}}")

        _none ->
          headers
      end

    base
    |> put_unless_empty("headers", headers)
    |> put_budget("startup_timeout", startup_ms(table))
    |> put_budget("tool_timeout", seconds_ms(Map.get(table, "tool_timeout_sec")))
  end

  defp startup_ms(%{"startup_timeout_ms" => ms}) when is_integer(ms), do: ms
  defp startup_ms(table), do: seconds_ms(Map.get(table, "startup_timeout_sec"))

  defp seconds_ms(seconds) when is_number(seconds) and seconds > 0, do: round(seconds * 1000)
  defp seconds_ms(_seconds), do: nil

  defp put_unless_empty(map, _key, value) when value == %{}, do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  defp put_budget(map, _key, nil), do: map
  defp put_budget(map, key, ms), do: Map.put(map, key, ms)

  @doc """
  Writes one named server while preserving other entries in an MCP JSON file.

  Written in the shape Claude Code reads: the transport as `"type"` for the
  two it knows, and never the `"source"` lemieux marks servers with, which
  describes where a server was read from rather than what it is. A file
  shared by both clients stays readable by both.
  """
  @spec put_server(path :: Path.t(), server :: map()) :: :ok | {:error, String.t()}
  def put_server(path, %{"name" => name} = server) when is_binary(name) do
    with {:ok, document} <- read_document(path),
         {:ok, servers} <- server_object(document) do
      updated = Map.put(servers, name, written(server))

      wrapped =
        if Map.has_key?(document, "mcpServers"),
          do: Map.put(document, "mcpServers", updated),
          else: %{"mcpServers" => updated}

      write_document(path, JSON.encode!(wrapped) <> "\n")
    end
  end

  @doc "Deletes one named server from an existing MCP JSON file."
  @spec delete_server(path :: Path.t(), name :: String.t()) :: :ok | {:error, String.t()}
  def delete_server(path, name) when is_binary(name) do
    with {:ok, contents} <- read_file(path),
         {:ok, document} <- decode(contents, path),
         {:ok, servers} <- server_object(document),
         true <- Map.has_key?(servers, name) do
      updated = Map.delete(servers, name)

      document =
        if Map.has_key?(document, "mcpServers"),
          do: Map.put(document, "mcpServers", updated),
          else: updated

      write_document(path, JSON.encode!(document) <> "\n")
    else
      false -> {:error, "#{name} is not present in #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_document(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents, path)
      {:error, :enoent} -> {:ok, %{"mcpServers" => %{}}}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp server_object(%{"mcpServers" => servers}) when is_map(servers), do: {:ok, servers}
  defp server_object(%{"mcpServers" => _invalid}), do: {:error, "mcpServers must be an object"}
  defp server_object(document) when is_map(document), do: {:ok, document}

  defp write_document(path, contents) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.write(temporary, contents, [:exclusive]),
         :ok <- preserve_mode(path, temporary),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp preserve_mode(path, temporary) do
    case File.stat(path) do
      {:ok, stat} -> File.chmod(temporary, stat.mode)
      {:error, :enoent} -> File.chmod(temporary, 0o600)
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(contents, path) do
    case JSON.decode(contents) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _otherwise -> {:error, "#{path} is not a JSON object"}
    end
  end

  defp servers(json) do
    json
    |> Map.get("mcpServers", json)
    |> case do
      servers when is_map(servers) -> Enum.map(servers, &server/1)
      _otherwise -> []
    end
  end

  defp server({name, config}) when is_map(config) do
    config
    |> Map.put("name", name)
    |> MCP.config()
  end

  defp server({name, _config}), do: %{"name" => name, "transport" => "unknown"}

  defp written(server) do
    server = Map.drop(server, ["name", "source"])

    case Map.pop(server, "transport") do
      {transport, rest} when transport in ["stdio", "http"] -> Map.put(rest, "type", transport)
      {nil, rest} -> rest
      {_custom, _rest} -> server
    end
  end
end
