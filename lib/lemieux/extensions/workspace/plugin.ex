defmodule Lemieux.Extensions.Workspace.Plugin do
  @moduledoc """
  A local Claude-compatible plugin as understood by `lmx`.

  Loaded: Agent Skills, legacy Markdown commands, root skills and
  manifest-declared skill/command paths as prompt-time instructions; agent
  definitions as read-only delegation targets
  (`Lemieux.Extensions.Workspace.Agent`); MCP servers; and hooks, as Claude
  Code dialect commands (`Lemieux.Hooks.Config`). Language servers, output
  styles, themes and the rest are diagnosed rather than half-supported.

  ## Selection is the trust decision

  A plugin is read only because a person selected it — `--plugin-dir`, or a
  plugin named from a marketplace they configured — and nothing here goes
  looking. That selection is what makes it acceptable for a plugin's hooks
  to run commands and its MCP servers to start: the same act of trust a
  person makes installing one in Claude Code, where these components come
  from. A repository cannot select a plugin for you.

  ## What a plugin's processes are told

  `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` in a hook command or an
  MCP server's configuration are replaced with the plugin's directory and its
  persistent data directory, and both are also exported as environment
  variables to the plugin's hook commands and stdio MCP servers — what
  Claude Code provides, and what a plugin's scripts read. Substituting into
  the command line alone was not enough: a script that reads
  `os.environ["CLAUDE_PLUGIN_ROOT"]` (hookify does) failed to import its own
  modules, printed a warning and exited 0, so its blocking rules silently
  allowed everything. Hooks also get `CLAUDE_PROJECT_DIR` when they run
  (`Lemieux.Hooks.Command`).

  The data directory is `<data_root>/<id>`, where the id is the plugin's
  name, or `NAME@MARKETPLACE` for a marketplace plugin, with every character
  other than a letter, digit, `_` or `-` replaced by `-` — Claude Code's
  rule. The data root is `~/.lmx/plugin-data` (`default_data_root/0`, and
  what `Lemieux.Extensions.Workspace.Discovery` uses with the person's
  files); a discovery that reads nothing personal — `lmx --config none` —
  gives its plugins a fresh directory for the run instead, so it keeps
  nothing in the person's state either. Reading a plugin creates nothing:
  the directory is made, owner-only, when a hook command or stdio MCP
  server that is told about it is about to start, as Claude Code makes it on
  first use, and it is kept across updates because the plugin's root (a
  cache directory per revision) is not.

  `.claude-plugin/plugin.json` is optional in the upstream format. Without it,
  the directory or marketplace entry supplies the plugin name.
  """

  alias Lemieux.Extensions.Workspace.Agent
  alias Lemieux.Extensions.Workspace.Skill

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          version: String.t() | nil,
          root: Path.t(),
          skills: [Skill.t()],
          agents: [Agent.t()],
          mcp_servers: [map()],
          hooks: Lemieux.Hooks.t(),
          diagnostics: [String.t()]
        }

  @enforce_keys [:name, :root]
  defstruct [
    :name,
    :description,
    :version,
    :root,
    skills: [],
    agents: [],
    mcp_servers: [],
    hooks: [],
    diagnostics: []
  ]

  @doc """
  Reads one already-materialized local plugin directory.

  Options:

    * `:name` — the plugin's name, instead of its manifest's or directory's;
    * `:id` — the identifier its data directory is named after (the name by
      default; `NAME@MARKETPLACE` for a marketplace plugin);
    * `:marketplace_entry` — the catalog entry it was selected from;
    * `:data_root` — the directory its persistent data directory is made in,
      instead of `default_data_root/0`.
  """
  @spec read(root :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(root, opts \\ []) when is_binary(root) and is_list(opts) do
    root = Path.expand(root)
    marketplace_entry = Keyword.get(opts, :marketplace_entry, %{})

    with :ok <- directory(root),
         {:ok, manifest} <- manifest(root),
         {:ok, name} <- name(root, manifest, opts),
         paths = paths(root, name, opts),
         :ok <- strict_components(manifest, marketplace_entry),
         {:ok, skill_sources} <-
           component_sources(manifest, marketplace_entry, "skills", "skills", :additive),
         {:ok, skill_roots} <- component_paths(root, skill_sources, "skills"),
         {:ok, command_sources} <-
           component_sources(manifest, marketplace_entry, "commands", "commands", :replacing),
         {:ok, command_roots} <-
           component_paths(root, command_sources, "commands"),
         {:ok, agent_sources} <-
           component_sources(manifest, marketplace_entry, "agents", "agents", :additive),
         {:ok, agent_paths} <- component_paths(root, agent_sources, "agents"),
         {:ok, mcp_servers, mcp_diagnostics} <- mcp_servers(paths, manifest, marketplace_entry),
         {:ok, hooks, hook_diagnostics} <- hooks(paths, manifest, marketplace_entry) do
      {directory_skills, skill_diagnostics} =
        Skill.discover(skill_roots,
          namespace: name,
          source: {:plugin, name},
          plugin_root: root
        )

      {command_skills, command_diagnostics} = commands(command_roots, name, root)

      {root_skills, root_diagnostics} =
        root_skill(root, name, manifest, marketplace_entry, directory_skills)

      {agents, agent_diagnostics} = agents(agent_paths, name)

      skills =
        (command_skills ++ root_skills ++ directory_skills)
        |> Map.new(&{Skill.qualified_name(&1), &1})
        |> Map.values()
        |> Enum.sort_by(&Skill.qualified_name/1)

      diagnostics =
        unsupported(root, [manifest, marketplace_entry], name) ++
          skill_diagnostics ++
          command_diagnostics ++
          root_diagnostics ++ agent_diagnostics ++ mcp_diagnostics ++ hook_diagnostics

      {:ok,
       %__MODULE__{
         name: name,
         description: string(manifest, "description") || string(marketplace_entry, "description"),
         version: string(manifest, "version") || string(marketplace_entry, "version"),
         root: root,
         skills: skills,
         agents: agents,
         mcp_servers: Enum.map(mcp_servers, &plugin_server(&1, name, paths)),
         hooks: Enum.map(hooks, &plugin_hook(&1, paths)),
         diagnostics: diagnostics
       }}
    end
  end

  # A declared agents path may be a directory of definitions or one file.
  defp agents(paths, namespace) do
    paths
    |> Enum.flat_map(fn path ->
      if File.dir?(path),
        do: path |> Path.join("*.md") |> Path.wildcard() |> Enum.sort(),
        else: [path]
    end)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce({[], []}, fn path, {agents, diagnostics} ->
      case Agent.read(path, namespace: namespace, source: {:plugin, namespace}) do
        {:ok, agent} -> {agents ++ [agent], diagnostics ++ agent.diagnostics}
        {:error, reason} -> {agents, diagnostics ++ [reason]}
      end
    end)
  end

  # A plugin's server is named as Claude Code names it,
  # `plugin_<plugin>_<server>`. Under the name its file gives it, a plugin's
  # `github` and the person's own `github` were one name for two servers,
  # and whichever the session saw last silently replaced the other; the
  # person's own server lost to a plugin they may not know declares one. The
  # prefix keeps the two apart, and it is the name a Claude Code plugin's
  # own hooks and permission rules already use for its tools
  # (`mcp__plugin_<plugin>_<server>__…`). `"plugin"` says where it came from:
  # like the person's own servers, and unlike a repository's, it may read
  # any variable its entry names, because installing a plugin is the
  # decision to run what it declares.
  #
  # A stdio server is also given the plugin's two directories in its
  # environment; its own `env` wins, since it said so.
  defp plugin_server(server, plugin, paths) do
    server
    |> Map.merge(%{"name" => "plugin_#{plugin}_#{server["name"]}", "source" => "plugin"})
    |> plugin_server_env(paths)
  end

  defp plugin_server_env(%{"transport" => "stdio"} = server, paths) do
    exported = exported(paths)
    Map.update(server, "env", exported, &Map.merge(exported, &1))
  end

  defp plugin_server_env(server, _paths), do: server

  # The same two directories for every hook command the plugin declares,
  # under whatever the command sets itself.
  defp plugin_hook({event, %Lemieux.Hooks.Command{} = command}, paths),
    do: {event, %{command | env: Map.merge(exported(paths), command.env)}}

  defp exported(paths),
    do: %{"CLAUDE_PLUGIN_ROOT" => paths.root, "CLAUDE_PLUGIN_DATA" => paths.data}

  @doc """
  Where plugins' persistent data directories are made when the caller names
  no `:data_root`: `plugin-data` under `~/.lmx`, beside the rest of the
  person's `lmx` state and where discovery puts it by default. There used to
  be a second default here, the platform's data directory, so the same
  plugin's data moved depending on which function read it.
  """
  @spec default_data_root() :: Path.t()
  def default_data_root, do: Path.expand("~/.lmx/plugin-data")

  defp paths(root, name, opts) do
    id = Keyword.get(opts, :id) || name
    data_root = Keyword.get(opts, :data_root) || default_data_root()
    %{root: root, data: Path.join(data_root, String.replace(id, ~r/[^A-Za-z0-9_-]/, "-"))}
  end

  # `.mcp.json` at the root, or the manifest's `mcpServers` — a path to such
  # a file or the servers inline. Read through `Lemieux.MCP.Config` so a
  # plugin's servers mean exactly what the same entries in a repository's
  # `.mcp.json` would.
  defp mcp_servers(paths, manifest, marketplace_entry) do
    case declared(manifest, marketplace_entry, "mcpServers") do
      nil -> mcp_file(paths, Path.join(paths.root, ".mcp.json"), :optional)
      path when is_binary(path) -> declared_mcp_file(paths, path)
      servers when is_map(servers) -> inline_mcp(paths, servers)
      _invalid -> {:error, "plugin manifest mcpServers must be a path or an object"}
    end
  end

  defp declared_mcp_file(paths, path) do
    case Path.safe_relative(path, paths.root) do
      {:ok, relative} -> mcp_file(paths, Path.join(paths.root, relative), :required)
      :error -> {:error, "plugin mcpServers path escapes plugin root: #{path}"}
    end
  end

  # A component that cannot be read costs that component, as a diagnostic,
  # and not the plugin's skills and agents beside it.
  defp mcp_file(paths, path, presence) do
    cond do
      File.regular?(path) ->
        case Lemieux.MCP.Config.read(path) do
          {:ok, servers} -> {:ok, Enum.map(servers, &substitute(&1, paths)), []}
          {:error, reason} -> {:ok, [], ["plugin MCP servers were not loaded: #{reason}"]}
        end

      presence == :optional ->
        {:ok, [], []}

      true ->
        {:ok, [], ["plugin MCP servers were not loaded: #{path} does not exist"]}
    end
  end

  # `Lemieux.MCP.Config` reads files, and a file is what an inline object is
  # the contents of; routing it through one keeps a single definition of
  # what an entry means rather than a second parser here.
  defp inline_mcp(paths, servers) do
    path =
      Path.join(System.tmp_dir!(), "lmx-plugin-mcp-#{System.unique_integer([:positive])}.json")

    try do
      File.write!(path, JSON.encode!(%{"mcpServers" => servers}))
      mcp_file(paths, path, :required)
    after
      File.rm(path)
    end
  end

  # `hooks/hooks.json`, or the manifest's `hooks` — a path to such a file or
  # the configuration inline — in Claude Code's own shape.
  defp hooks(paths, manifest, marketplace_entry) do
    case declared(manifest, marketplace_entry, "hooks") do
      nil ->
        default = Path.join([paths.root, "hooks", "hooks.json"])
        if File.regular?(default), do: hook_file(paths, default), else: {:ok, [], []}

      path when is_binary(path) ->
        case Path.safe_relative(path, paths.root) do
          {:ok, relative} -> hook_file(paths, Path.join(paths.root, relative))
          :error -> {:error, "plugin hooks path escapes plugin root: #{path}"}
        end

      document when is_map(document) ->
        load_hooks(paths, document)

      _invalid ->
        {:error, "plugin manifest hooks must be a path or an object"}
    end
  end

  defp hook_file(paths, path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} when is_map(document) <- JSON.decode(contents) do
      load_hooks(paths, document)
    else
      {:error, reason} when is_atom(reason) ->
        {:ok, [], ["plugin hooks were not loaded: #{path}: #{:file.format_error(reason)}"]}

      _undecodable ->
        {:ok, [], ["plugin hooks were not loaded: #{path} is not a JSON object"]}
    end
  end

  defp load_hooks(paths, document) do
    document = if Map.has_key?(document, "hooks"), do: document, else: %{"hooks" => document}

    case Lemieux.Hooks.Config.load(substitute(document, paths), dialect: :claude) do
      {:ok, %{hooks: hooks, warnings: warnings}} -> {:ok, hooks, warnings}
      {:error, reason} -> {:ok, [], ["plugin hooks were not loaded: #{reason}"]}
    end
  end

  defp declared(manifest, marketplace_entry, key),
    do: Map.get(manifest, key) || Map.get(marketplace_entry, key)

  # `${CLAUDE_PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_DATA}` are written into every
  # string of a hook or server configuration that mentions them, as Claude
  # Code substitutes them in those fields — an MCP server's `command` and
  # `args` are spawned without a shell, so an exported variable alone would
  # leave the literal placeholder there. They are exported as well (see
  # `plugin_hook/2` and `plugin_server_env/2`).
  defp substitute(value, paths) when is_binary(value) do
    value
    |> String.replace("${CLAUDE_PLUGIN_ROOT}", paths.root)
    |> String.replace("$CLAUDE_PLUGIN_ROOT", paths.root)
    |> String.replace("${CLAUDE_PLUGIN_DATA}", paths.data)
  end

  defp substitute(value, paths) when is_list(value), do: Enum.map(value, &substitute(&1, paths))

  defp substitute(value, paths) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, substitute(item, paths)} end)

  defp substitute(value, _paths), do: value

  defp directory(root) do
    if File.dir?(root), do: :ok, else: {:error, "plugin directory does not exist: #{root}"}
  end

  defp manifest(root) do
    path = Path.join([root, ".claude-plugin", "plugin.json"])

    case File.read(path) do
      {:ok, contents} -> decode_manifest(contents, path)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp decode_manifest(contents, path) do
    case JSON.decode(contents) do
      {:ok, manifest} when is_map(manifest) -> {:ok, manifest}
      {:ok, _other} -> {:error, "#{path} must contain a JSON object"}
      {:error, reason} -> {:error, "could not parse #{path}: #{inspect(reason)}"}
    end
  end

  defp name(root, manifest, opts) do
    name = Keyword.get(opts, :name) || string(manifest, "name") || Path.basename(root)

    if is_binary(name) and String.trim(name) != "" do
      {:ok, name}
    else
      {:error, "plugin at #{root} needs a name"}
    end
  end

  defp unsupported(root, manifests, name) do
    filesystem = [
      {"LSP servers", File.exists?(Path.join(root, ".lsp.json"))},
      {"output styles", File.dir?(Path.join(root, "output-styles"))},
      {"themes", File.dir?(Path.join(root, "themes"))},
      {"monitors", File.dir?(Path.join(root, "monitors"))},
      {"bin", File.dir?(Path.join(root, "bin"))},
      {"settings", File.exists?(Path.join(root, "settings.json"))}
    ]

    declared = [
      {"LSP servers", declared?(manifests, "lspServers")},
      {"output styles", declared?(manifests, "outputStyles")},
      {"channels", declared?(manifests, "channels")},
      {"experimental components", declared?(manifests, "experimental")}
    ]

    (filesystem ++ declared)
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(&"plugin #{name}: ignored unsupported #{&1} component")
  end

  defp declared?(manifests, key), do: Enum.any?(manifests, &Map.has_key?(&1, key))

  defp commands(roots, namespace, root),
    do:
      Skill.discover_commands(roots,
        namespace: namespace,
        source: {:plugin, namespace},
        plugin_root: root
      )

  defp root_skill(root, namespace, manifest, marketplace_entry, directory_skills) do
    path = Path.join(root, "SKILL.md")
    default_skills = Path.join(root, "skills")

    if directory_skills == [] and not File.dir?(default_skills) and
         not Map.has_key?(manifest, "skills") and
         not Map.has_key?(marketplace_entry, "skills") and File.regular?(path) do
      read_many(
        [path],
        &Skill.read(&1,
          namespace: namespace,
          source: {:plugin, namespace},
          plugin_root: root
        )
      )
    else
      {[], []}
    end
  end

  defp read_many(paths, reader) do
    paths
    |> Enum.reduce({[], []}, fn path, {loaded, diagnostics} ->
      case reader.(path) do
        {:ok, skill} -> {[skill | loaded], Enum.reverse(skill.diagnostics, diagnostics)}
        {:error, reason} -> {loaded, [reason | diagnostics]}
      end
    end)
    |> then(fn {loaded, diagnostics} -> {Enum.reverse(loaded), Enum.reverse(diagnostics)} end)
  end

  defp component_paths(root, sources, key) do
    sources
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, &add_component_path(&1, &2, root, key))
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp component_sources(manifest, marketplace_entry, key, default, behavior) do
    with {:ok, manifest_paths} <- optional_declared_paths(manifest, key),
         {:ok, marketplace_paths} <- optional_declared_paths(marketplace_entry, key) do
      strict? = Map.get(marketplace_entry, "strict", true)

      sources =
        if strict? do
          base_sources(manifest_paths, default, behavior) ++ List.wrap(marketplace_paths)
        else
          base_sources(marketplace_paths, default, behavior)
        end

      {:ok, sources}
    end
  end

  defp base_sources(nil, default, _behavior), do: [default]
  defp base_sources(paths, default, :additive), do: [default | paths]
  defp base_sources(paths, _default, :replacing), do: paths

  @component_keys ~w(skills commands agents hooks mcpServers outputStyles lspServers experimental channels)

  defp strict_components(manifest, %{"strict" => false}) do
    conflicts = Enum.filter(@component_keys, &Map.has_key?(manifest, &1))

    if conflicts == [] do
      :ok
    else
      {:error,
       "plugin strict: false conflicts with plugin.json components: #{Enum.join(conflicts, ", ")}"}
    end
  end

  defp strict_components(_manifest, %{"strict" => value}) when not is_boolean(value),
    do: {:error, "plugin marketplace strict must be true or false"}

  defp strict_components(_manifest, _marketplace_entry), do: :ok

  defp add_component_path(source, {:ok, paths}, root, key) do
    case Path.safe_relative(source, root) do
      {:ok, relative} -> {:cont, {:ok, [Path.join(root, relative) | paths]}}
      :error -> {:halt, {:error, "plugin #{key} path escapes plugin root: #{source}"}}
    end
  end

  defp optional_declared_paths(manifest, key) do
    case Map.fetch(manifest, key) do
      :error -> {:ok, nil}
      {:ok, value} -> declared_paths(value, key)
    end
  end

  defp declared_paths(value, key) do
    case value do
      path when is_binary(path) -> validate_declared_paths([path], key)
      paths when is_list(paths) and paths != [] -> validate_declared_paths(paths, key)
      _invalid -> {:error, "plugin manifest #{key} must be a path or non-empty list of paths"}
    end
  end

  defp validate_declared_paths(paths, key) do
    if Enum.all?(paths, &(is_binary(&1) and String.starts_with?(&1, "./"))) do
      {:ok, paths}
    else
      {:error, "plugin manifest #{key} paths must be non-empty and start with ./"}
    end
  end

  defp string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end
end
