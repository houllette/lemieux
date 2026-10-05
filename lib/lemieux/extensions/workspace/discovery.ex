defmodule Lemieux.Extensions.Workspace.Discovery do
  @moduledoc """
  What the filesystem says about a workspace, and how it reads as a prompt.

  The reading half of `Lemieux.Extensions.Workspace`: this module finds the
  files and holds the rules — which files, in which order, what wins — and
  the extension is what the result does to a harness. It is host setup, not
  agent-loop policy. An embedder may assemble its own system prompt from a
  database, an API or a sandbox image; the CLI has a filesystem and follows
  the portable conventions already present in coding repositories.

  It composes persona and memory files, portable and Claude-compatible
  instructions, Agent Skills, legacy commands, and explicitly selected plugin
  skills. Applicable instruction files are loaded from the repository root
  down to the starting directory. Later, nearer files therefore appear later
  in the prompt and take precedence. The prompt also tells the model to look
  for nearer files before working below that starting directory, because a
  static prompt cannot know which subtree a future tool call will enter.

  Nothing calls `discover/2` on its own; `lmx` does, and applies the
  extension over what it found. The terminal UI discovers once per screen.
  `lmx run` and `lmx explain` discover for a new session, and for a resumed
  one whose transcript recorded a workspace layer, unless `--bare`,
  `--system`, `--build-ext` or `--extension-profile` leaves the workspace
  out (`Lemieux.CLI.Runtime.with_workspace/2`). A library embedder keeps the
  prompt and tools it supplied unless it applies the extension too.

  ## Imports, sizes and agents

  A `CLAUDE.md` or `CLAUDE.local.md` may import other files with `@path`, as
  Claude Code reads them: followed up to five levels deep, relative to the
  importing file (or to the home directory for `@~/…`), with `\\ ` for a space
  in a name, and never inside code. Imported files are listed right after
  the file that imports them, so a repository whose `CLAUDE.md` is just
  `@AGENTS.md` is read once rather than as an empty file beside the one it
  meant. Every instruction, persona and memory file is capped at 32 KiB,
  cut on a line boundary with a notice to the model and a diagnostic to the
  person: one oversized file would otherwise be paid for on every request.

  Claude-compatible subagent definitions (`.claude/agents/*.md`, personal
  and repository, and a selected plugin's) are read into `agents`, and a
  selected plugin's MCP servers and hooks into `mcp_servers` and `hooks`;
  `Lemieux.Extensions.Workspace` and `Lemieux.Extensions.Delegation` decide
  what they do.

  ## What a repository may put in the prompt

  A checkout is somebody else's content, and what it says becomes part of
  every request — and of the transcript. So the files a repository supplies
  are confined to it, after symlinks are resolved:

    * an `@path` import in a repository's `CLAUDE.md` or `CLAUDE.local.md`
      (at any level) is followed only to a file whose real path is inside the
      repository. `@~/x/../.ssh/id_ed25519` in a cloned `CLAUDE.md` once put
      an SSH key into the system prompt and the saved session, under
      `--permission-mode read_only --sandbox` too, because imports were
      allowed to reach the home directory;
    * a repository instruction, persona or memory file (`CLAUDE.md`,
      `CLAUDE.local.md`, `AGENTS.md`, `AGENTS.override.md`, `SOUL.md`,
      `MEMORY.md`) that is a symlink to a file outside the repository is not
      read. Committing `AGENTS.md -> ../../.ssh/id_rsa` did the same thing
      without any import at all. A link inside the repository —
      `CLAUDE.md -> AGENTS.md` — still works. The same holds for the
      repository's skills, legacy commands and subagent definitions under
      `.agents/` and `.claude/`, and for its learned overlay: a command
      needs no frontmatter, so one linked to a short credentials file put
      that file into the skill catalog. A repository's skill is checked
      again when it is loaded (`Lemieux.Extensions.Workspace.Skill.render/2`);
    * your own files (`~/.claude/CLAUDE.md`, `~/.lmx/AGENTS.md`, the Codex
      file) may import from your home directory and the repository, which is
      how Claude Code's `@~/.claude/my-project-instructions.md` works;
    * nobody's file reaches a credential location: `~/.ssh`, `~/.aws`,
      `~/.gnupg`, `~/.netrc`, `~/.config/gh`, `~/.docker`, `~/.kube`,
      `~/.lmx`, `~/.lemieux`, `~/.config/gcloud`, `~/.azure`,
      `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`,
      `~/.claude/.credentials.json` and `~/.codex/auth.json` — the
      directories the opt-in sandbox hides, and the credential files beside
      them — in any letter case. That is checked first, so it holds when
      the home directory is itself a repository (a dotfiles checkout) and
      everything under it counts as inside.

  One check answers this for every kind of file, and what it judged is
  what is read. It resolves a path the way the kernel opens it: a `..`
  after a linked directory goes up from where the link leads. Resolving
  `d/../x` as text once judged a file outside the repository to be
  `<repository>/x`.

  Every reference or file left out this way is one diagnostic naming it, so
  a person can see what their instructions asked for and did not get. An
  `@word` that names no file — a mention, a package scope — is prose and
  says nothing.

  ## The learned overlay

  `.lmx/harness.json` at the repository root and `~/.lmx/harness.json` are
  the learned layer (`Lemieux.Learning.Overlay`). The repository's may add
  text to the system prompt, and when it does a diagnostic names it on every
  start, as the trust question names a repository's MCP servers. It may not
  re-describe tools: a description is what the model believes a tool does,
  and a checkout describing `bash` as "sandboxed, safe to run anything" is a
  stronger lie than any paragraph of instructions. Its `tool_descriptions`
  are dropped with a diagnostic; only your own overlay may describe tools.
  The file's `sha256` is self-computed, so it says the file is intact, not
  who wrote it.

  ## Plugins

  A plugin, catalog or selection that cannot be loaded is a diagnostic
  naming it, and the session starts without it. A marketplace that could not
  be fetched or a plugin with a broken manifest used to stop every session
  from starting — offline, a saved marketplace meant no `lmx` at all.

  ## Where skills come from

  Skills and legacy commands are read from these roots, a later root
  winning a name clash:

    1. the bundled skills (`:bundled_skills?`);
    2. system skill roots (`:system_skill_dirs`), which a host names — `lmx`
       names Omarchy's (`Lemieux.CLI.SystemSkills`). They are read like
       personal ones: trusted, not confined to the repository, read in
       place and never copied, so an update to the system's copy is the
       next session's;
    3. `~/.codex/skills`, `~/.agents/skills`, `~/.claude/skills` and
       `~/.lmx/skills`, unless `personal?: false`. `lmx`'s own directory
       comes last because it is the override for this harness: a skill
       there replaces one of the same name that Claude Code or Codex also
       sees. (`~/.claude/skills` used to win over it.) Personal legacy
       commands follow the same order, `~/.claude/commands` then
       `~/.lmx/commands`;
    4. the repository's `.agents/skills` and `.claude/skills`, from its root
       down to the starting directory;
    5. `--skill-dir`s (`:skill_dirs`), in the order given.

  A legacy command loses to a skill of the same name, and a plugin's skills
  are namespaced, so they clash with nothing outside the plugin. The copy of
  a name that lost is kept in `shadowed_skills` — one skill reached through
  several roots is one entry, and an inspector can say whether what it hid
  is the same file — and a name in `:disabled_skills` (qualified, as
  `plugin:name`) is moved to `disabled_skills`, out of the catalog, the
  `skill` tool and the slash commands, wherever it came from. Both are for
  inspection (`lmx skills`); nothing else reads them. Each skill's `source`
  says where it was found: `{:bundled, root}`, `{:system, root}`,
  `{:personal, root}`, `{:repository, root}`, `{:skill_dir, root}`, or
  `{:plugin, id}`. Only the skills kept report their compatibility notes, so
  one skill reached three ways says each thing once. `skill_diagnostics` is
  the part of `diagnostics` about skills, commands and plugins.

  ## The marked layer

  `system_prompt/2` wraps what it adds between `@context_start` and
  `@context_end` and strips an earlier layer before adding the current one.
  That protocol is the contract a replacement must keep: a resume composes
  over the prompt the transcript recorded, and without the markers the
  current files would stack on the stale ones instead of replacing them.
  """

  alias Lemieux.Extensions.Workspace.Agent
  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Plugin
  alias Lemieux.Extensions.Workspace.Plugin.Marketplace
  alias Lemieux.Extensions.Workspace.Skill
  alias Lemieux.Extensions.Workspace.SkillTool
  alias Lemieux.Learning.Overlay

  @context_start "<!-- lmx-workspace-context:start -->"
  @context_end "<!-- lmx-workspace-context:end -->"

  # One instruction file's share of every request. A repository's AGENTS.md
  # is paid for on every model call of every session in it; a file that grew
  # past this is almost always a changelog or a generated reference that
  # somebody pasted in, and the part the model needs is at the top.
  @max_file_bytes 32_768
  # How deep `@path` imports are followed, as Claude Code does.
  @max_import_depth 5

  @type t :: %__MODULE__{
          root: Path.t(),
          persona_files: [{Path.t(), String.t()}],
          instruction_files: [{Path.t(), String.t()}],
          memory_files: [{Path.t(), String.t()}],
          skills: [Skill.t()],
          shadowed_skills: [Skill.t()],
          disabled_skills: [Skill.t()],
          agents: [Agent.t()],
          mcp_servers: [map()],
          hooks: Lemieux.Hooks.t(),
          overlay: Overlay.t() | nil,
          home: Path.t() | nil,
          diagnostics: [String.t()],
          skill_diagnostics: [String.t()]
        }

  @enforce_keys [:root]
  defstruct [
    :root,
    :home,
    persona_files: [],
    instruction_files: [],
    memory_files: [],
    skills: [],
    shadowed_skills: [],
    disabled_skills: [],
    agents: [],
    mcp_servers: [],
    hooks: [],
    overlay: nil,
    diagnostics: [],
    skill_diagnostics: []
  ]

  @doc """
  Discovers repository instructions, standalone skills and selected plugins.

  Options are `:skill_dirs`, `:bundled_skills?`, `:system_skill_dirs`,
  `:disabled_skills`, `:plugin_dirs`, `:marketplaces`, `:plugins`,
  `:marketplace_fetch`, `:plugin_data_dir`, `:personal?`, `:personal_dir`
  (`~/.lmx`), `:claude_personal_dir` (`~/.claude`), `:codex_personal_dir`
  (`~/.codex`), `:agents_personal_dir` (`~/.agents`), `:home` (the home
  directory `@~/` imports expand against and personal imports may reach;
  the user's by default), and `:supplied`. See "Where skills come from"
  above for the skill options. A
  marketplace may be local
  or remote; network access occurs only when the caller explicitly supplies a
  remote marketplace or selects a plugin with a remote source.
  `:marketplace_fetch` carries host/testing overrides such as `:cache_dir`,
  `:get`, `:git` and `:refresh_after_ms`. `:plugin_data_dir` is where plugins'
  persistent data directories go: `plugin-data` under the personal
  directory by default, or, with `personal?: false`, a fresh directory under
  the system's temporary directory that nothing creates unless a plugin's
  hook or server starts.

  A plugin, marketplace or selection that cannot be loaded is reported in
  `diagnostics` and left out; only an instruction file that exists and
  cannot be read is an error.
  """
  @spec discover(cwd :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def discover(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    cwd = Path.expand(cwd)
    root = repository_root(cwd)
    directories = applicable_directories(root, cwd)
    personal_dir = Keyword.get(opts, :personal_dir, Path.expand("~/.lmx"))
    claude_personal_dir = Keyword.get(opts, :claude_personal_dir, Path.expand("~/.claude"))
    codex_personal_dir = Keyword.get(opts, :codex_personal_dir, Path.expand("~/.codex"))
    agents_personal_dir = Keyword.get(opts, :agents_personal_dir, Path.expand("~/.agents"))
    personal? = Keyword.get(opts, :personal?, true)
    scope = Containment.scope(root, Keyword.get_lazy(opts, :home, fn -> Path.expand("~") end))

    plugin_data_dir =
      Keyword.get_lazy(opts, :plugin_data_dir, fn -> plugin_data_root(personal?, personal_dir) end)

    fetch =
      opts
      |> Keyword.get(:marketplace_fetch, [])
      |> Keyword.put_new(:plugin_data_dir, plugin_data_dir)

    with {:ok, persona, persona_notes} <- persona(root, personal_dir, personal?, scope),
         {:ok, instructions, instruction_notes} <-
           instructions(
             directories,
             personal_dir,
             claude_personal_dir,
             codex_personal_dir,
             personal?,
             scope
           ),
         {:ok, memory, memory_notes} <- memory(root, personal_dir, personal?, scope),
         {:ok, overlay, overlay_diagnostics} <- overlay(root, personal_dir, personal?, scope) do
      {direct_plugins, direct_notes} =
        plugins(Keyword.get(opts, :plugin_dirs, []), plugin_data_dir)

      {marketplaces, marketplace_notes} =
        marketplaces(Keyword.get(opts, :marketplaces, []), fetch)

      {selected_plugins, selection_notes} =
        selected_plugins(marketplaces, Keyword.get(opts, :plugins, []), fetch)

      # In precedence order — see "Where skills come from" — the repository's
      # confined to it by the same check as its instruction files; each later
      # root winning by name when they are resolved below.
      within = [within: scope]

      personal_skill_dirs =
        personal_skill_roots(
          [codex_personal_dir, agents_personal_dir, claude_personal_dir, personal_dir],
          personal?
        )

      {standalone, skill_diagnostics} =
        concatenate([
          skills_under(bundled_skill_roots(Keyword.get(opts, :bundled_skills?, false)), :bundled),
          skills_under(Keyword.get(opts, :system_skill_dirs, []), :system),
          skills_under(personal_skill_dirs, :personal),
          skills_under(default_skill_roots(directories), :repository, within),
          skills_under(Keyword.get(opts, :skill_dirs, []), :skill_dir)
        ])

      {commands, command_diagnostics} =
        concatenate([
          commands_under(
            personal_command_roots(personal_dir, claude_personal_dir, personal?),
            :personal
          ),
          commands_under(default_command_roots(directories), :repository, within)
        ])

      {workspace_agents, agent_diagnostics} =
        concatenate([
          Agent.discover(personal_agent_roots(personal_dir, claude_personal_dir, personal?)),
          Agent.discover(default_agent_roots(directories), within)
        ])

      loaded_plugins = direct_plugins ++ selected_plugins
      plugin_skills = Enum.flat_map(loaded_plugins, & &1.skills)

      plugin_diagnostics =
        direct_notes ++
          marketplace_notes ++
          Enum.flat_map(marketplaces, & &1.diagnostics) ++
          selection_notes ++ Enum.flat_map(loaded_plugins, & &1.diagnostics)

      {kept, shadowed} = by_name(commands ++ standalone ++ plugin_skills)
      disabled_names = Keyword.get(opts, :disabled_skills, [])
      {disabled, skills} = Enum.split_with(kept, &(Skill.qualified_name(&1) in disabled_names))

      # A plugin's skills' notes are already among the plugin's.
      skill_notes =
        skill_diagnostics ++
          command_diagnostics ++
          Enum.flat_map(skills, fn
            %Skill{source: {:plugin, _id}} -> []
            skill -> skill.diagnostics
          end)

      agents =
        (workspace_agents ++ Enum.flat_map(loaded_plugins, & &1.agents))
        |> Map.new(&{&1.id, &1})
        |> Map.values()
        |> Enum.sort_by(& &1.id)

      {:ok,
       %__MODULE__{
         root: root,
         persona_files: persona,
         instruction_files: instructions,
         memory_files: memory,
         skills: skills,
         shadowed_skills: shadowed,
         disabled_skills: disabled,
         agents: agents,
         mcp_servers: Enum.flat_map(loaded_plugins, & &1.mcp_servers),
         hooks: Enum.flat_map(loaded_plugins, & &1.hooks),
         overlay: overlay,
         home: scope.home,
         diagnostics:
           experience_diagnostics(root, Keyword.get(opts, :supplied, [])) ++
             persona_notes ++
             instruction_notes ++
             memory_notes ++
             skill_notes ++
             agent_diagnostics ++ plugin_diagnostics ++ overlay_diagnostics,
         skill_diagnostics: skill_notes ++ plugin_diagnostics
       }}
    end
  end

  @doc """
  The repository's own MCP configuration, if it has one.

  `lmx` loads this unless told not to, so this is also what decides whether
  there is anything to say about it — one function rather than a `File.exists?`
  in the loader and another in the diagnostics, which is how a warning ends up
  contradicting what the harness just did.

  Takes the working directory and walks to the repository root, because a
  `.mcp.json` belongs to the checkout rather than to the directory you happened
  to start in.
  """
  @spec project_mcp_config(cwd :: Path.t()) :: Path.t() | nil
  def project_mcp_config(cwd) when is_binary(cwd) do
    path = cwd |> Path.expand() |> repository_root() |> Path.join(".mcp.json")

    if File.regular?(path), do: path
  end

  @doc """
  What this repository leaves lying about that `lmx` will not act on, and what
  to pass if you want it to.

  Separated from `discover/2` because a host may have a workspace to warn
  about and deliberately does not have a workspace: it loads no persona, no
  skills and no plugins, and reading a `.mcp.json`'s worth of `File.exists?`
  is not a reason to change that. `discover/2` calls this too, so both front
  ends say the same thing.

  `:supplied` names the remedies the caller has already taken — `:mcp_config`,
  `:hooks` — so a warning whose own advice has been followed is not repeated.
  """
  @spec notices(cwd :: Path.t(), opts :: keyword()) :: [String.t()]
  def notices(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    cwd
    |> Path.expand()
    |> repository_root()
    |> experience_diagnostics(Keyword.get(opts, :supplied, []))
  end

  @doc """
  Whether `prompt` carries a workspace layer: the marked section
  `system_prompt/2` adds.

  What a host asks of the prompt a transcript recorded when it resumes a
  session: one started with a workspace gets today's files in place of the
  old layer, and one started without — a bare run, a host's own prompt — is
  resumed as it was.
  """
  @spec composed?(prompt :: String.t() | nil) :: boolean()
  def composed?(prompt) when is_binary(prompt), do: String.contains?(prompt, @context_start)
  def composed?(_prompt), do: false

  @doc "Appends discovered instructions and the progressive-disclosure skill catalog."
  @spec system_prompt(workspace :: t(), base :: String.t()) :: String.t()
  def system_prompt(%__MODULE__{} = workspace, base) when is_binary(base) do
    context =
      [
        file_prompt("Agent persona", workspace.persona_files, workspace),
        instruction_prompt(workspace),
        file_prompt("Durable memory", workspace.memory_files, workspace),
        skill_prompt(workspace),
        overlay_prompt(workspace)
      ]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    base = strip_workspace_context(base)

    if context == "" do
      base
    else
      Enum.join([base, @context_start, context, @context_end], "\n\n")
    end
  end

  @doc """
  Applies the discovered harness overlay's tool descriptions to a tool list.

  The overlay is a learned layer, so it is applied the way persona and
  instruction files are: by the host at session start, recorded in the
  harness snapshot, never restored from a transcript. Only a personal
  overlay carries tool descriptions; see "The learned overlay" above.
  """
  @spec overlay_tools(workspace :: t(), tools :: [Lemieux.Tool.t()]) :: [Lemieux.Tool.t()]
  def overlay_tools(%__MODULE__{overlay: overlay}, tools) when is_list(tools),
    do: Overlay.apply_tools(overlay, tools)

  @doc "The resolved-asset records this workspace contributes to session evidence."
  @spec resolved_assets(workspace :: t()) :: [map()]
  def resolved_assets(%__MODULE__{overlay: nil}), do: []
  def resolved_assets(%__MODULE__{overlay: overlay}), do: [Overlay.asset(overlay)]

  @doc "Configured tools the host must re-supply rather than record in a transcript."
  @spec host_tools(workspace :: t()) :: [Lemieux.Tool.t()]
  def host_tools(%__MODULE__{} = workspace) do
    case Enum.filter(workspace.skills, & &1.model_invocable?) do
      [] -> []
      skills -> [SkillTool.new(skills, home: workspace.home)]
    end
  end

  @doc "Skills a screen exposes as slash commands."
  @spec user_skills(workspace :: t()) :: [Skill.t()]
  def user_skills(%__MODULE__{} = workspace),
    do: Enum.filter(workspace.skills, & &1.user_invocable?)

  # `.lmx/harness.json` at the repository root and `~/.lmx/harness.json`
  # personally: the learned layer, discovered like every other prompt file and
  # merged with the project winning per key. A malformed file is a startup
  # diagnostic rather than a silent skip, because a learned layer that quietly stops
  # applying is the drift the overlay's digest exists to expose.
  #
  # The repository's file is a file the repository supplies like any other,
  # so it is read only from where `Containment.check/2` says it really is: a
  # `.lmx/harness.json` linked out of the checkout was read as the
  # repository's overlay, and its parse error quoted a byte of the target.
  defp overlay(root, personal_dir, personal?, scope) do
    personal_path = Path.join(personal_dir, Overlay.filename())
    project_path = Path.join([root, ".lmx", Overlay.filename()])

    {personal, personal_diagnostics} =
      if personal?, do: read_overlay(personal_path, personal_path), else: {nil, []}

    {project, project_diagnostics} = project_overlay(project_path, scope)
    {project, repository_notes} = repository_overlay(project)

    {:ok, Overlay.merge(personal, project),
     personal_diagnostics ++ project_diagnostics ++ repository_notes}
  end

  defp project_overlay(path, scope) do
    with {:ok, _link_or_file} <- File.lstat(path),
         {:ok, real} <- Containment.check(path, scope) do
      read_overlay(path, real)
    else
      {:error, _absent} -> {nil, []}
      refusal -> {nil, [Containment.refused(display_path(path, scope.root), refusal)]}
    end
  end

  # Read from `source`, recorded as `path`: the asset a session records names
  # the file where the person would look for it.
  defp read_overlay(path, source) do
    case Overlay.read(source) do
      {:ok, nil} -> {nil, []}
      {:ok, overlay} -> {%{overlay | path: path}, []}
      {:error, reason} -> {nil, ["harness overlay #{path} was ignored: #{inspect(reason)}"]}
    end
  end

  # The repository's overlay keeps its prompt text, loses its tool
  # descriptions, and is named whenever it applies; see the moduledoc. One
  # left with nothing to apply is not applied, so no asset records a layer
  # that changed nothing.
  defp repository_overlay(nil), do: {nil, []}

  defp repository_overlay(%Overlay{} = overlay) do
    {kept, dropped} = Overlay.without_tool_descriptions(overlay)
    file = Path.join(".lmx", Overlay.filename())

    dropped_note =
      if dropped == [],
        do: [],
        else: [
          "#{file}: a repository overlay may not re-describe tools, so its descriptions of " <>
            "#{Enum.join(dropped, ", ")} were not applied; only your own " <>
            "~/.lmx/#{Overlay.filename()} may"
        ]

    if kept.system_suffix in [nil, ""] do
      {nil, dropped_note}
    else
      applied =
        "#{file}: this repository's learned overlay (#{kept.qualification}, " <>
          "#{binary_part(kept.sha256, 0, 12)}) adds text to the system prompt; delete or " <>
          "revert the file to stop it"

      {kept, [applied | dropped_note]}
    end
  end

  defp overlay_prompt(%__MODULE__{overlay: nil}), do: ""

  defp overlay_prompt(%__MODULE__{overlay: overlay}) do
    case overlay.system_suffix do
      suffix when is_binary(suffix) and suffix != "" ->
        "## Learned harness (#{overlay.qualification}, #{binary_part(overlay.sha256, 0, 12)})

" <> suffix

      _none ->
        ""
    end
  end

  # Plugins' persistent data lives with the person's other state. A discovery
  # that reads nothing personal keeps nothing personal either — defaulting to
  # the personal directory regardless made `--config none` create
  # `~/.lmx/plugin-data` the first time a plugin's hook ran. Its plugins get
  # a directory of their own for the run, named unguessably because the
  # temporary directory is shared.
  defp plugin_data_root(true, personal_dir), do: Path.join(personal_dir, "plugin-data")

  defp plugin_data_root(false, _personal_dir) do
    token = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "lmx-plugin-data-" <> token)
  end

  defp repository_root(directory), do: find_repository_root(directory) || directory

  defp find_repository_root(directory) do
    cond do
      File.exists?(Path.join(directory, ".git")) -> directory
      Path.dirname(directory) == directory -> nil
      true -> find_repository_root(Path.dirname(directory))
    end
  end

  defp applicable_directories(root, root), do: [root]

  defp applicable_directories(root, cwd) do
    cwd
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
    |> then(&[root | &1])
  end

  defp persona(root, personal_dir, personal?, scope) do
    personal = if personal?, do: [{Path.join(personal_dir, "SOUL.md"), :personal}], else: []
    read_files(personal ++ [{Path.join(root, "SOUL.md"), :repository}], scope)
  end

  defp memory(root, personal_dir, personal?, scope) do
    personal = if personal?, do: [{Path.join(personal_dir, "MEMORY.md"), :personal}], else: []
    read_files(personal ++ [{Path.join(root, "MEMORY.md"), :repository}], scope)
  end

  defp instructions(
         directories,
         personal_dir,
         claude_personal_dir,
         codex_personal_dir,
         personal?,
         scope
       ) do
    personal =
      if personal? do
        [
          Path.join(claude_personal_dir, "CLAUDE.md"),
          Path.join(personal_dir, "AGENTS.md")
          | agents_file(codex_personal_dir)
        ]
      else
        []
      end

    repository =
      Enum.flat_map(directories, fn directory ->
        [Path.join(directory, "CLAUDE.md"), Path.join(directory, "CLAUDE.local.md")] ++
          agents_file(directory)
      end)

    read_files(
      Enum.map(personal, &{&1, :personal}) ++ Enum.map(repository, &{&1, :repository}),
      scope
    )
  end

  # Each entry is a path and whose file it is — `:personal` or
  # `:repository` — which decides where it may come from and where its
  # imports may reach. Each file, imported or not, is capped at
  # `@max_file_bytes`.
  defp read_files(entries, scope) do
    entries
    |> Enum.filter(fn {path, _owner} -> File.regular?(path) end)
    |> Enum.reduce_while({:ok, [], []}, fn {path, owner}, {:ok, files, notes} ->
      case read_entry(path, owner, scope) do
        {:ok, read, read_notes} -> {:cont, {:ok, Enum.reverse(read, files), notes ++ read_notes}}
        {:skip, note} -> {:cont, {:ok, files, notes ++ [note]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, files, notes} ->
        {capped, cap_notes} = files |> Enum.reverse() |> Enum.map_reduce([], &cap/2)
        {:ok, deduplicate_files(capped), notes ++ Enum.reverse(cap_notes)}

      error ->
        error
    end
  end

  # A repository's file is read from the real path that was checked, not
  # through the name again: what is judged is what is read.
  defp read_entry(path, owner, scope) do
    with {:ok, source} <- contained(path, owner, scope) do
      case File.read(source) do
        {:ok, contents} ->
          {read, notes} = with_imports(path, contents, owner, scope)
          {:ok, read, notes}

        {:error, reason} ->
          {:error, "could not read #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  # A repository's file that resolves outside the repository, or into a
  # credential location, is not the repository's to give. A person's own
  # files are theirs, links and all: `~/.claude/CLAUDE.md` is often a link
  # into a dotfiles checkout.
  defp contained(path, :personal, _scope), do: {:ok, path}

  defp contained(path, :repository, scope) do
    case Containment.check(path, scope) do
      {:ok, real} -> {:ok, real}
      refusal -> {:skip, Containment.refused(display_path(path, scope.root), refusal)}
    end
  end

  defp cap({path, contents}, notes) when byte_size(contents) <= @max_file_bytes,
    do: {{path, contents}, notes}

  # Cut on the last line boundary inside the budget, so no instruction is
  # left half-written, and say so both to the model and to the person.
  defp cap({path, contents}, notes) do
    head = binary_part(contents, 0, @max_file_bytes)

    kept =
      case :binary.matches(head, "\n") do
        [] -> head
        matches -> binary_part(head, 0, elem(List.last(matches), 0))
      end

    kept = if String.valid?(kept), do: kept, else: String.replace_invalid(kept)

    notice =
      "\n\n[lmx: this file is #{byte_size(contents)} bytes; only its first " <>
        "#{byte_size(kept)} are included here. Read the file itself for the rest.]"

    {{path, kept <> notice},
     ["#{path} is over #{div(@max_file_bytes, 1024)} KiB and was truncated in the prompt" | notes]}
  end

  # Claude Code's `@path` imports, in the files written for it: CLAUDE.md and
  # CLAUDE.local.md. An import is followed only when it names a regular file
  # its owner may reach (see the moduledoc); anything else that names a file
  # is refused with a diagnostic, and anything that names nothing — `@alice`,
  # a package scope, a path that does not exist — is left as the text it is.
  # Imported files are added right after the file that imports them rather
  # than spliced into its sentences, so "see @README for an overview" still
  # reads as written.
  defp with_imports(path, contents, owner, scope) do
    if String.starts_with?(Path.basename(path), "CLAUDE") do
      seen = MapSet.new([real_path(path)])
      {imported, notes, _seen} = imports(path, contents, owner, scope, 1, seen)
      {[{path, contents} | imported], notes}
    else
      {[{path, contents}], []}
    end
  end

  defp imports(path, contents, owner, scope, depth, seen) do
    contents
    |> import_references()
    |> Enum.reduce({[], [], seen}, fn reference, {files, notes, seen} ->
      case resolve_import(reference, Path.dirname(path), owner, scope) do
        {:ok, target, real} ->
          follow({target, real}, path, owner, scope, depth, {files, notes, seen})

        :not_a_file ->
          {files, notes, seen}

        {:refused, why} ->
          {files, notes ++ ["#{path}: import @#{reference} was not followed: #{why}"], seen}
      end
    end)
  end

  defp follow({target, real}, importer, owner, scope, depth, {files, notes, seen}) do
    cond do
      MapSet.member?(seen, real) ->
        {files, notes, seen}

      depth > @max_import_depth ->
        {files,
         notes ++
           [
             "#{importer}: imports nested deeper than #{@max_import_depth} levels were not followed"
           ], seen}

      true ->
        read_import({target, real}, owner, scope, depth, {files, notes, seen})
    end
  end

  defp read_import({target, real}, owner, scope, depth, {files, notes, seen}) do
    case File.read(real) do
      {:ok, imported} ->
        seen = MapSet.put(seen, real)
        # A file inside the repository is the repository's, whoever
        # imported it: its own imports stay inside the repository too.
        owner = if inside?(real, scope.real_root), do: :repository, else: owner
        {nested, nested_notes, seen} = imports(target, imported, owner, scope, depth + 1, seen)
        {files ++ [{target, imported} | nested], notes ++ nested_notes, seen}

      {:error, reason} ->
        {files, notes ++ ["could not read #{target}: #{:file.format_error(reason)}"], seen}
    end
  end

  # Code is not instructions: an `@decorator` in a fenced example or a
  # `@spec` in backticks is not an import. A reference is what Claude Code
  # reads as one: an `@` at the start of a word, then everything up to the
  # first space that is not escaped — `@Design\ Docs/api.md` names a folder
  # with a space in it — less the punctuation that closes a sentence. Reading
  # fewer characters than upstream does is not safer: a path with an
  # apostrophe in it was cut short and silently not followed, and the rules
  # that keep a repository's imports inside it are applied to what the
  # reference resolves to, not to how it is spelled. One with no letter or
  # digit in it — `@.` — is punctuation.
  defp import_references(contents) do
    prose =
      contents
      |> String.replace(~r/^(```|~~~).*?^\1/ms, "")
      |> String.replace(~r/`[^`\n]*`/, "")

    ~r/(?<!\S)@((?:[^\s\\]|\\ )+)/u
    |> Regex.scan(prose, capture: :all_but_first)
    |> Enum.map(fn [reference] -> String.replace(reference, ~r/[.,;:!?)\]}"'`]+\z/u, "") end)
    |> Enum.filter(&Regex.match?(~r/\w/u, &1))
    |> Enum.uniq()
  end

  defp resolve_import(reference, directory, owner, scope) do
    name = String.replace(reference, "\\ ", " ")

    target =
      case name do
        "~/" <> rest -> Path.expand(rest, scope.home)
        _relative_or_absolute -> Path.expand(name, directory)
      end

    real = real_path(target)

    cond do
      not File.regular?(real) ->
        :not_a_file

      shown = Containment.hidden(real, scope) ->
        {:refused, "it is in #{shown}, where credentials live; lmx never reads it into a prompt"}

      reachable?(real, owner, scope) ->
        {:ok, target, real}

      owner == :repository ->
        {:refused,
         "it is outside the repository, and a repository's instructions may import only " <>
           "files inside it"}

      true ->
        {:refused, "it is outside the repository and your home directory"}
    end
  end

  defp reachable?(real, :repository, scope), do: inside?(real, scope.real_root)

  defp reachable?(real, :personal, scope),
    do: inside?(real, scope.real_root) or inside?(real, scope.real_home)

  defp inside?(target, root), do: Containment.inside?(target, root)
  defp real_path(path), do: Containment.real_path(path)

  # Discovered lists in precedence order, as one list a later `Map.new`
  # resolves by name — the later entry winning — and their diagnostics in
  # the same order.
  defp concatenate(results) do
    {Enum.flat_map(results, &elem(&1, 0)), Enum.flat_map(results, &elem(&1, 1))}
  end

  # Each root read on its own, so every skill records which one it came from.
  defp skills_under(roots, kind, opts \\ []),
    do: under(roots, kind, opts, &Skill.discover_all/2)

  defp commands_under(roots, kind, opts \\ []),
    do: under(roots, kind, opts, &Skill.discover_all_commands/2)

  defp under(roots, kind, opts, read) do
    roots
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&read.([&1], [source: {kind, &1}] ++ opts))
    |> concatenate()
  end

  # Later wins by qualified name. What lost is kept, in the order it lost.
  defp by_name(skills) do
    {kept, shadowed} =
      Enum.reduce(skills, {%{}, []}, fn skill, {kept, shadowed} ->
        name = Skill.qualified_name(skill)

        case Map.fetch(kept, name) do
          {:ok, lost} -> {Map.put(kept, name, skill), [lost | shadowed]}
          :error -> {Map.put(kept, name, skill), shadowed}
        end
      end)

    {kept |> Map.values() |> Enum.sort_by(&Skill.qualified_name/1), Enum.reverse(shadowed)}
  end

  defp deduplicate_files(files) do
    files
    |> Enum.reduce({[], %{}}, &deduplicate_file/2)
    |> elem(0)
    |> Enum.reverse()
  end

  defp deduplicate_file({path, contents} = file, {kept, positions}) do
    case Map.fetch(positions, contents) do
      :error -> {[file | kept], Map.put(positions, contents, length(kept))}
      {:ok, position} -> prefer_agents_file(path, file, position, kept, positions)
    end
  end

  defp prefer_agents_file(path, file, position, kept, positions) do
    if Path.basename(path) == "AGENTS.md" do
      index = length(kept) - position - 1
      {List.replace_at(kept, index, file), positions}
    else
      {kept, positions}
    end
  end

  defp agents_file(directory) do
    override = Path.join(directory, "AGENTS.override.md")
    ordinary = Path.join(directory, "AGENTS.md")

    if File.regular?(override), do: [override], else: [ordinary]
  end

  defp default_skill_roots(directories) do
    Enum.flat_map(directories, fn directory ->
      [Path.join([directory, ".agents", "skills"]), Path.join([directory, ".claude", "skills"])]
    end)
  end

  # The TUI opts in; personal, project and explicit skills can override these
  # shipped instructions without changing an installed release.
  defp bundled_skill_roots(true), do: [Application.app_dir(:lemieux, "priv/skills")]
  defp bundled_skill_roots(false), do: []

  defp personal_skill_roots(_directories, false), do: []

  defp personal_skill_roots(directories, true),
    do: Enum.map(directories, &Path.join(&1, "skills"))

  defp default_command_roots(directories),
    do: Enum.map(directories, &Path.join([&1, ".claude", "commands"]))

  # Claude Code's subagent definitions: personal first, then the repository
  # from its root down to the starting directory, so the nearest definition
  # of a name is the one offered.
  defp default_agent_roots(directories),
    do: Enum.map(directories, &Path.join([&1, ".claude", "agents"]))

  defp personal_agent_roots(_personal_dir, _claude_personal_dir, false), do: []

  defp personal_agent_roots(personal_dir, claude_personal_dir, true),
    do: [Path.join(claude_personal_dir, "agents"), Path.join(personal_dir, "agents")]

  defp personal_command_roots(_personal_dir, _claude_personal_dir, false), do: []

  defp personal_command_roots(personal_dir, claude_personal_dir, true),
    do: [Path.join(claude_personal_dir, "commands"), Path.join(personal_dir, "commands")]

  # What a repository leaves lying about that this harness will not pick up on its
  # own, and what to pass if you want it to. `supplied` is what the caller was
  # already given explicitly: a warning whose remedy has been taken is not a
  # warning, and printing it anyway teaches people to stop reading these.
  #
  # `.mcp.json` is deliberately absent — `lmx` starts it, and there is a flag for
  # saying no — which is also why the settings entries below ask whether the file
  # declares a hook rather than whether it exists.
  defp experience_diagnostics(root, supplied) do
    [
      {:hooks, Path.join(".claude", "settings.json"), &declares_hooks?/1,
       "repository Claude hooks are not executed; pass --hooks explicitly for trusted hooks"},
      {:hooks, Path.join(".claude", "settings.local.json"), &declares_hooks?/1,
       "repository-local Claude hooks are not executed; pass --hooks explicitly for trusted hooks"},
      {nil, Path.join(".claude", "rules"), &File.exists?/1,
       "path-scoped Claude rules are not imported; use nested AGENTS.md or CLAUDE.md instructions"}
    ]
    |> Enum.reject(fn {remedy, _relative, _applies?, _message} -> remedy in supplied end)
    |> Enum.map(&explicit_config_diagnostic(root, &1))
    |> Enum.reject(&is_nil/1)
  end

  # Relative to the repository, because the absolute path is the part the
  # reader already knows and the part that pushes the remedy off the line.
  defp explicit_config_diagnostic(root, {_remedy, relative, applies?, message}) do
    if applies?.(Path.join(root, relative)), do: "#{relative}: #{message}", else: nil
  end

  # A Claude settings file mostly holds permissions and MCP enablement, neither of
  # which this harness has a concept of and neither of which is code. Warning on the
  # file's existence told every repository with a `.claude/settings.json` that its
  # hooks would not run when it had none. Unreadable or unparseable still warns: not
  # being able to tell is not the same as knowing there is nothing there.
  defp declares_hooks?(path) do
    case File.read(path) do
      {:ok, contents} -> hooks_declared?(JSON.decode(contents))
      {:error, :enoent} -> false
      {:error, _unreadable} -> true
    end
  end

  defp hooks_declared?({:ok, %{"hooks" => hooks}}) when is_map(hooks), do: map_size(hooks) > 0
  defp hooks_declared?({:ok, %{"hooks" => hooks}}) when is_list(hooks), do: hooks != []
  defp hooks_declared?({:ok, _document}), do: false
  defp hooks_declared?({:error, _undecodable}), do: true

  defp strip_workspace_context(prompt) do
    case String.split(prompt, @context_start, parts: 2) do
      [base, remainder] -> strip_workspace_context_end(base, remainder)
      [_unmarked] -> prompt
    end
  end

  defp strip_workspace_context_end(base, remainder) do
    case String.split(remainder, @context_end, parts: 2) do
      [_context, suffix] -> String.trim(base <> suffix)
      [_unterminated] -> base |> String.trim()
    end
  end

  # Each of these loads what it can and names what it could not. A selected
  # plugin that fails is one fewer plugin, said out loud — not a session that
  # never starts because a catalog was unreachable or a manifest used a
  # shape this reader does not know.
  defp plugins(paths, data_root) do
    collect(paths, &Plugin.read(&1, data_root: data_root), &"plugin #{&1} was not loaded: #{&2}")
  end

  defp marketplaces(sources, fetch_opts) do
    collect(
      sources,
      &Marketplace.read(&1, fetch_opts),
      &"marketplace #{&1} was not loaded: #{&2}"
    )
  end

  defp selected_plugins(marketplaces, selectors, fetch_opts) do
    collect(
      selectors,
      fn selector ->
        with {:ok, marketplace_name} <- selector_marketplace(selector),
             {:ok, marketplace} <- fetch_marketplace(marketplaces, marketplace_name) do
          Marketplace.resolve(marketplace, selector, fetch_opts)
        end
      end,
      &"plugin #{&1} was not loaded: #{&2}"
    )
  end

  defp selector_marketplace(selector) do
    case String.split(selector, "@", parts: 2) do
      [name, marketplace] when name != "" and marketplace != "" -> {:ok, marketplace}
      _other -> {:error, "plugin selection needs NAME@MARKETPLACE: #{selector}"}
    end
  end

  defp fetch_marketplace(marketplaces, name) do
    case Enum.find(marketplaces, &(&1.name == name)) do
      nil -> {:error, "no marketplace named #{name} was loaded"}
      marketplace -> {:ok, marketplace}
    end
  end

  defp collect(enumerable, fun, describe) do
    {loaded, notes} =
      Enum.reduce(enumerable, {[], []}, fn value, {loaded, notes} ->
        case fun.(value) do
          {:ok, result} -> {[result | loaded], notes}
          {:error, reason} -> {loaded, [describe.(value, reason) | notes]}
        end
      end)

    {Enum.reverse(loaded), Enum.reverse(notes)}
  end

  defp instruction_prompt(%__MODULE__{instruction_files: []}), do: ""

  defp instruction_prompt(workspace) do
    rendered =
      Enum.map_join(workspace.instruction_files, "\n\n", fn {path, contents} ->
        "### #{display_path(path, workspace.root)}\n\n#{String.trim(contents)}"
      end)

    """
    ## Workspace instructions

    Follow the applicable portable AGENTS.md and Claude-compatible CLAUDE.md
    files below. They are ordered from broadest to nearest; a later file is
    more specific. The user's explicit request overrides repository
    instructions. Before changing a file below the starting directory, check
    whether nearer instructions apply there.

    #{rendered}
    """
    |> String.trim()
  end

  defp skill_prompt(%__MODULE__{skills: []}), do: ""

  defp skill_prompt(workspace) do
    listed =
      workspace.skills
      |> Enum.filter(& &1.model_invocable?)
      |> Enum.map_join("\n", fn skill ->
        "- #{Skill.qualified_name(skill)}: #{skill.description}"
      end)

    if listed == "" do
      ""
    else
      """
      ## Available Agent Skills

      The following skills use progressive disclosure. When the task matches a
      skill, call the `skill` tool with its qualified name before acting. The
      loaded instructions name the skill's directory and list its files; when
      they refer to one (a reference, an example, a template), load it with
      the same tool, adding "file" with its path relative to that directory.
      The tool reads personal, system and plugin skills without widening
      normal filesystem access. Run a skill's scripts with bash from its
      directory. Frontmatter tool grants are informational here; host policy
      still controls tools.

      #{listed}
      """
      |> String.trim()
    end
  end

  defp file_prompt(_title, [], _workspace), do: ""

  defp file_prompt(title, files, workspace) do
    rendered =
      Enum.map_join(files, "\n\n", fn {path, contents} ->
        "### #{display_path(path, workspace.root)}\n\n#{String.trim(contents)}"
      end)

    "## #{title}\n\n#{rendered}"
  end

  defp display_path(path, root) do
    relative = Path.relative_to(path, root)

    if relative == ".." or String.starts_with?(relative, "../") do
      path
    else
      relative
    end
  end
end
