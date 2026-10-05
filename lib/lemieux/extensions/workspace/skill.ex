defmodule Lemieux.Extensions.Workspace.Skill do
  @moduledoc """
  One Agent Skill discovered by the `lmx` host.

  Skills are prompt-time instructions, not Elixir plugins. At session start
  the TUI gives the model only each skill's name, description and path. A
  configured, allowlisted tool loads the complete body when the task calls for
  it. The separate loader matters because personal and revision-cached plugin
  skills are outside the repository boundary enforced by the ordinary `read`
  tool. Progressive disclosure lets a workspace carry many skills without
  paying for every body on every model request.

  The frontmatter is parsed as YAML rather than as hand-split `key: value`
  lines. Descriptions commonly use block scalars, and silently losing most of
  one would make activation fail while still looking like skill support.

  A repository's skill is confined to the repository twice: when it is
  discovered (`discover/2` with `within:`) and again when it is loaded
  (`render/2`), which reads it from the real path that check found. The
  file under a skill's name may have changed in between — the session's own
  tools can replace it with a link — and the loader reads it with the
  host's rights, outside any sandbox the session's commands run in.

  ## The skill's directory is where the file really is

  `path` is the `SKILL.md` as discovered, which is what a person recognises
  (`~/.claude/skills/omarchy/SKILL.md`); `real_path` is where it really
  is, every link resolved; and `root` — the "Skill directory:" the loader
  prints and what `${CLAUDE_SKILL_DIR}` expands to — is the directory of
  `real_path`. A `SKILL.md` that is itself a link, common in
  `~/.agents/skills`, sits in a directory with none of its sibling files:
  with `root` taken from `path`, Omarchy's "read `hyprland.md` before
  starting" pointed at a file that was not there.

  ## Files beside a skill

  A skill's instructions refer to files next to them — references, examples,
  templates. The ordinary `read` tool is confined to the working directory
  and cannot reach a personal, system or plugin skill's directory, so
  `file/3` loads them, and `render/2` lists them (two levels, at most 50
  entries, no dotfiles) with how to ask for one. A file is loaded only
  from inside the skill's real directory — a plugin's skill may also reach
  the rest of its plugin, whose `${CLAUDE_PLUGIN_ROOT}` references point
  there — after every link is resolved the way the kernel opens it, by
  the check discovery confines a repository with; never from a credential
  location, unless the skill's own directory is in that same location
  (`~/.lmx/skills` is inside `~/.lmx`); and, for a repository's skill, only
  inside the repository, checked again. Text only, up to 1 MiB: a script
  is for `bash` to run, and its bytes in a tool result are no use to
  anybody. A legacy command is one Markdown file in a directory of other
  commands, so it has no files of its own.
  """

  alias Lemieux.Extensions.Workspace.Containment
  alias Lemieux.Extensions.Workspace.Frontmatter

  @name ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  # A bound on reading a file into memory at discovery, not on how long a
  # skill may be. This used to be 24 kB, sized to fit a 30 kB tool-result
  # ceiling the session no longer has, and it refused perfectly good skills
  # written for agents with larger budgets. How much of a skill fits in one
  # result is the loader's question — `Lemieux.Extensions.Workspace.SkillTool`
  # pages a long one within the session's actual output cap.
  @max_bytes 1_048_576
  # How many of a skill's files its loaded header lists.
  @max_listed 50

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          path: Path.t(),
          real_path: Path.t() | nil,
          root: Path.t(),
          source: term(),
          kind: :skill | :command,
          namespace: String.t() | nil,
          plugin_root: Path.t() | nil,
          argument_hint: String.t() | nil,
          model_invocable?: boolean(),
          user_invocable?: boolean(),
          # The repository scope discovery confined the skill to, or `nil`.
          within: struct() | nil,
          diagnostics: [String.t()]
        }

  @enforce_keys [:name, :description, :path, :root, :source]
  defstruct [
    :name,
    :description,
    :path,
    :real_path,
    :root,
    :source,
    :namespace,
    :plugin_root,
    :argument_hint,
    :within,
    kind: :skill,
    model_invocable?: true,
    user_invocable?: true,
    diagnostics: []
  ]

  @doc """
  Reads and validates one `SKILL.md`.

  `within:` is the repository scope the file was confined to, kept so
  `render/2` can check it again.
  """
  @spec read(path :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def read(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path = Path.expand(path)

    with :ok <- confined(path, Keyword.get(opts, :plugin_root)),
         {:ok, contents} <- read_file(path),
         {:ok, frontmatter, body} <- document(contents, path),
         {:ok, attributes} <- yaml(frontmatter, path),
         {:ok, name} <- name(attributes, path, Path.basename(Path.dirname(path))),
         {:ok, description} <- description(attributes, path),
         {:ok, model_invocable?} <- model_invocable(attributes, path),
         {:ok, user_invocable?} <- user_invocable(attributes, path) do
      real = Containment.real_path(path)

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         path: path,
         real_path: real,
         root: Path.dirname(real),
         source: Keyword.get(opts, :source, :workspace),
         namespace: Keyword.get(opts, :namespace),
         plugin_root: Keyword.get(opts, :plugin_root),
         argument_hint: string(attributes, "argument-hint"),
         model_invocable?: model_invocable?,
         user_invocable?: user_invocable?,
         within: Keyword.get(opts, :within),
         diagnostics: compatibility_diagnostics(attributes, body, path)
       }}
    end
  end

  @doc "Reads one legacy flat command Markdown file as a user-invocable skill."
  @spec read_command(path :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def read_command(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path = Path.expand(path)
    fallback = Path.basename(path, Path.extname(path))

    with :ok <- confined(path, Keyword.get(opts, :plugin_root)),
         {:ok, contents} <- read_file(path),
         {:ok, attributes, body} <- optional_document(contents, path),
         {:ok, name} <- name(attributes, path, fallback),
         {:ok, description} <- command_description(attributes, body, path),
         {:ok, model_invocable?} <- model_invocable(attributes, path),
         {:ok, user_invocable?} <- user_invocable(attributes, path) do
      real = Containment.real_path(path)

      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         path: path,
         real_path: real,
         root: Path.dirname(real),
         kind: :command,
         source: Keyword.get(opts, :source, :workspace),
         namespace: Keyword.get(opts, :namespace),
         plugin_root: Keyword.get(opts, :plugin_root),
         argument_hint: string(attributes, "argument-hint"),
         model_invocable?: model_invocable?,
         user_invocable?: user_invocable?,
         within: Keyword.get(opts, :within),
         diagnostics: compatibility_diagnostics(attributes, body, path)
       }}
    end
  end

  @doc """
  Discovers the immediate child skills of each root.

  A malformed skill is returned as a diagnostic and does not hide the valid
  skills next to it. Later roots win by qualified name, which gives an explicit
  `--skill-dir` the expected precedence over repository defaults.

  `within:` a repository's scope, as discovery builds it, confines the files
  read to it: a `SKILL.md` whose real path is outside the repository, or in
  a credential location, is a diagnostic instead, which is how a
  repository's skills are read (`Lemieux.Extensions.Workspace.Discovery`).
  """
  @spec discover(roots :: [Path.t()], opts :: keyword()) :: {[t()], [String.t()]}
  def discover(roots, opts \\ []) when is_list(roots) and is_list(opts),
    do: roots |> discover_all(opts) |> by_name()

  @doc """
  Every readable skill under `roots`, in precedence order and not yet
  resolved by name, with a diagnostic for each file that could not be read
  or was not the repository's to give (`discover/2`'s `within:`). A skill's
  own compatibility notes stay on it (`diagnostics`), for the caller to
  report for the skills it keeps.

  What `Lemieux.Extensions.Workspace.Discovery` reads every root with, so it
  can say which copy of a name won and which it hid: Omarchy's skill reached
  through `~/.claude/skills` and `~/.codex/skills` is one skill, not three,
  and the two it hid are the same file.
  """
  @spec discover_all(roots :: [Path.t()], opts :: keyword()) :: {[t()], [String.t()]}
  def discover_all(roots, opts \\ []) when is_list(roots) and is_list(opts) do
    roots
    |> Enum.flat_map(&skill_files/1)
    |> read_all(&read(&1, opts), Keyword.get(opts, :within))
  end

  @doc """
  Discovers legacy Markdown slash commands beneath each supplied root, with
  `within:` as in `discover/2`. A command needs no frontmatter — its first
  paragraph is its description — so a repository's command that links to a
  short file in a home directory would otherwise put that file into the
  skill catalog of every request.
  """
  @spec discover_commands(roots :: [Path.t()], opts :: keyword()) :: {[t()], [String.t()]}
  def discover_commands(roots, opts \\ []) when is_list(roots) and is_list(opts),
    do: roots |> discover_all_commands(opts) |> by_name()

  @doc "Every readable legacy command under `roots`, as `discover_all/2` reads skills."
  @spec discover_all_commands(roots :: [Path.t()], opts :: keyword()) :: {[t()], [String.t()]}
  def discover_all_commands(roots, opts \\ []) when is_list(roots) and is_list(opts) do
    roots
    |> Enum.flat_map(&command_files/1)
    |> read_all(&read_command(&1, opts), Keyword.get(opts, :within))
  end

  @doc "The name shown to the model, namespaced for plugin skills."
  @spec qualified_name(skill :: t()) :: String.t()
  def qualified_name(%__MODULE__{name: name, namespace: nil}), do: name

  def qualified_name(%__MODULE__{name: name, namespace: namespace}),
    do: namespace <> ":" <> name

  @doc """
  Loads and renders a skill body with Agent Skills argument substitutions.

  A repository's skill is checked against its scope again and read from the
  real path the check found; one that now resolves outside the repository
  is an error naming it.
  """
  @spec render(skill :: t(), arguments :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def render(%__MODULE__{} = skill, arguments \\ "") when is_binary(arguments) do
    with :ok <- confined(skill.path, skill.plugin_root),
         {:ok, source} <- source(skill),
         {:ok, contents} <- read_file(source),
         {:ok, _attributes, body} <- optional_document(contents, skill.path) do
      rendered =
        body
        |> String.trim()
        |> expand_directories(skill)
        |> substitute(String.trim(arguments))

      {:ok,
       "Skill: #{qualified_name(skill)}\nSkill directory: #{skill.root}\n" <>
         files_header(skill) <> "\n#{rendered}"}
    end
  end

  @doc """
  The text of one file in the skill's directory: `relative` to its real
  directory, as `render/2` lists them (`"hyprland.md"`,
  `"references/api.md"`). See "Files beside a skill" above for what is
  refused. `:home` is the home directory the credential locations are
  under, the user's by default.
  """
  @spec file(skill :: t(), relative :: String.t(), opts :: keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def file(skill, relative, opts \\ [])

  def file(%__MODULE__{kind: :command} = skill, _relative, _opts),
    do:
      {:error,
       "#{qualified_name(skill)} is a command, a single file, so it has no files of its own to load"}

  def file(%__MODULE__{} = skill, relative, opts) when is_binary(relative) and is_list(opts) do
    home = Keyword.get_lazy(opts, :home, fn -> Path.expand("~") end)

    with :ok <- relative(relative),
         {:ok, real} <- inside_skill(skill, relative, home),
         :ok <- inside_repository(skill, relative, real) do
      read_text(skill, relative, real)
    end
  end

  defp relative(relative) do
    cond do
      String.trim(relative) == "" ->
        {:error, "file needs a path relative to the skill directory, such as \"reference.md\""}

      Path.type(relative) != :relative ->
        {:error,
         "file #{relative} is not relative; give a path relative to the skill directory, " <>
           "as the skill lists its files"}

      String.contains?(relative, <<0>>) ->
        {:error, "file names a path with a NUL byte in it"}

      true ->
        :ok
    end
  end

  # Inside the boundary first, after every link: then a credential location,
  # unless the skill's directory is itself in that location — `~/.lmx/skills`
  # is inside `~/.lmx`, and a skill's own notes there are the person's.
  defp inside_skill(skill, relative, home) do
    scope = Containment.scope(boundary(skill), home)
    real = Containment.real_path(Path.join(skill.root, relative))
    shown = Containment.hidden(real, scope)

    cond do
      not Containment.inside?(real, scope.real_root) ->
        {:error,
         "file #{relative} is outside #{boundary_name(skill)}; the skill tool loads only " <>
           "files inside it"}

      shown != nil and shown != Containment.hidden(scope.real_root, scope) ->
        {:error,
         "file #{relative} resolves into #{shown}, where credentials live; the skill tool " <>
           "never loads it"}

      true ->
        {:ok, real}
    end
  end

  # A plugin is the unit a person selected, and its skills' instructions name
  # files anywhere in it through `${CLAUDE_PLUGIN_ROOT}`; every other skill
  # is its own directory.
  defp boundary(%__MODULE__{plugin_root: nil, root: root}), do: root
  defp boundary(%__MODULE__{plugin_root: plugin_root}), do: Containment.real_path(plugin_root)

  defp boundary_name(%__MODULE__{plugin_root: nil}), do: "the skill's directory"
  defp boundary_name(%__MODULE__{}), do: "the skill's plugin"

  defp inside_repository(%__MODULE__{within: nil}, _relative, _real), do: :ok

  defp inside_repository(%__MODULE__{within: scope}, relative, real) do
    case Containment.check(real, scope) do
      {:ok, _real} -> :ok
      refusal -> {:error, Containment.refused("file #{relative}", refusal)}
    end
  end

  defp read_text(skill, relative, real) do
    case File.stat(real) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > @max_bytes ->
        {:error,
         "file #{relative} is #{size} bytes; the skill tool loads files up to #{@max_bytes}"}

      {:ok, %File.Stat{type: :regular}} ->
        real |> File.read() |> text(relative, real)

      {:ok, %File.Stat{type: :directory}} ->
        {:error, "file #{relative} is a directory#{listed(skill)}"}

      _absent_or_special ->
        {:error, "skill #{qualified_name(skill)} has no file #{relative}#{listed(skill)}"}
    end
  end

  defp text({:ok, contents}, relative, real) do
    if String.valid?(contents) and not String.contains?(contents, <<0>>),
      do: {:ok, contents},
      else:
        {:error,
         "file #{relative} is not text; if it is a script or a program, run it with bash: #{real}"}
  end

  defp text({:error, reason}, relative, _real),
    do: {:error, "could not read file #{relative}: #{:file.format_error(reason)}"}

  defp listed(skill) do
    case listing(skill) do
      {[], _more?} -> "; the skill directory has no other files"
      {files, more?} -> "; its files are #{Enum.join(files, ", ")}#{if more?, do: ", …"}"
    end
  end

  # The header's list of what `file/3` can load, and how to ask for it. A
  # skill the model may not invoke has no loader to ask, so it gets the list
  # without the instruction.
  defp files_header(skill) do
    case listing(skill) do
      {[], _more?} ->
        ""

      {files, more?} ->
        intro =
          if skill.model_invocable?,
            do:
              "Files in the skill directory, loaded with the skill tool as " <>
                ~s({"name": "#{qualified_name(skill)}", "file": "PATH"}:),
            else: "Files in the skill directory:"

        more = if more?, do: ["- … (more files; give a path relative to the directory)"], else: []
        Enum.join([intro | Enum.map(files, &("- " <> &1)) ++ more], "\n") <> "\n"
    end
  end

  # Regular files one and two levels down, dotfiles and `SKILL.md` left out,
  # stopping once it knows there are more than it lists. A link out of the
  # boundary is left out too: listing a file the loader refuses would only
  # invite the refusal.
  defp listing(%__MODULE__{kind: :command}), do: {[], false}

  defp listing(%__MODULE__{root: root} = skill) do
    boundary = boundary(skill)

    files =
      root
      |> entries()
      |> Stream.flat_map(&listed_entry(root, &1))
      |> Stream.reject(&(&1 == "SKILL.md"))
      |> Stream.filter(&Containment.inside?(Containment.real_path(Path.join(root, &1)), boundary))
      |> Enum.take(@max_listed + 1)

    {Enum.take(files, @max_listed), length(files) > @max_listed}
  end

  defp listed_entry(root, name) do
    path = Path.join(root, name)

    cond do
      File.regular?(path) ->
        [name]

      File.dir?(path) ->
        path
        |> entries()
        |> Enum.filter(&File.regular?(Path.join(path, &1)))
        |> Enum.map(&Path.join(name, &1))

      true ->
        []
    end
  end

  defp entries(directory) do
    case File.ls(directory) do
      {:ok, names} -> names |> Enum.reject(&String.starts_with?(&1, ".")) |> Enum.sort()
      {:error, _unreadable} -> []
    end
  end

  defp skill_files(root) do
    root = Path.expand(root)
    direct = Path.join(root, "SKILL.md")
    nested = root |> Path.join("*/SKILL.md") |> Path.wildcard() |> Enum.sort()

    if File.regular?(direct), do: [direct | nested], else: nested
  end

  defp command_files(root) do
    root = Path.expand(root)

    if File.regular?(root) and Path.extname(root) == ".md" do
      [root]
    else
      root |> Path.join("**/*.md") |> Path.wildcard() |> Enum.sort()
    end
  end

  defp read_all(paths, reader, within) do
    {paths, left_out} = Containment.split(paths, within)

    {skills, errors} =
      Enum.reduce(paths, {[], []}, fn path, {skills, errors} ->
        case reader.(path) do
          {:ok, skill} -> {[skill | skills], errors}
          {:error, reason} -> {skills, [reason | errors]}
        end
      end)

    {Enum.reverse(skills), left_out ++ Enum.reverse(errors)}
  end

  # Later wins by qualified name; every skill read reports its own notes.
  defp by_name({skills, diagnostics}) do
    named =
      skills
      |> Map.new(&{qualified_name(&1), &1})
      |> Map.values()
      |> Enum.sort_by(&qualified_name/1)

    {named, diagnostics ++ Enum.flat_map(skills, & &1.diagnostics)}
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} when byte_size(contents) <= @max_bytes ->
        {:ok, contents}

      {:ok, contents} ->
        {:error, "skill #{path} is #{byte_size(contents)} bytes; limit is #{@max_bytes}"}

      {:error, reason} ->
        {:error, "could not read skill #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp source(%__MODULE__{within: nil, path: path}), do: {:ok, path}

  defp source(%__MODULE__{within: scope, path: path}) do
    case Containment.check(path, scope) do
      {:ok, real} -> {:ok, real}
      refusal -> {:error, Containment.refused(path, refusal)}
    end
  end

  defp confined(_path, nil), do: :ok

  defp confined(path, plugin_root) do
    relative = Path.relative_to(path, plugin_root)

    case Path.safe_relative(relative, plugin_root) do
      {:ok, _safe} -> :ok
      :error -> {:error, "plugin skill path escapes plugin root: #{path}"}
    end
  end

  defp document(contents, path) do
    case Regex.run(
           ~r/\A---\r?\n(.*?)\r?\n---(?:\r?\n|\z)(.*)\z/s,
           contents,
           capture: :all_but_first
         ) do
      [frontmatter, body] -> {:ok, frontmatter, body}
      nil -> {:error, "#{path} needs YAML frontmatter between --- lines"}
    end
  end

  defp optional_document(contents, path) do
    case document(contents, path) do
      {:ok, frontmatter, body} ->
        with {:ok, attributes} <- yaml(frontmatter, path), do: {:ok, attributes, body}

      {:error, _reason} ->
        {:ok, %{}, contents}
    end
  end

  # Skills written for Claude Code are often not strict YAML; see
  # `Lemieux.Extensions.Workspace.Frontmatter`.
  defp yaml(frontmatter, path) do
    case Frontmatter.parse(frontmatter) do
      {:ok, attributes} -> {:ok, attributes}
      {:error, :not_an_object} -> {:error, "#{path} frontmatter must be a YAML object"}
      {:error, {:invalid, detail}} -> {:error, "could not read #{path} frontmatter (#{detail})"}
    end
  end

  defp name(attributes, path, fallback) do
    validate_name(Map.get(attributes, "name", fallback), path)
  end

  defp validate_name(name, path) when is_binary(name) do
    cond do
      String.length(name) > 64 -> {:error, "#{path} skill name is longer than 64 characters"}
      Regex.match?(@name, name) -> {:ok, name}
      true -> {:error, "#{path} skill name must contain lowercase letters, digits and hyphens"}
    end
  end

  defp validate_name(_name, path), do: {:error, "#{path} skill needs a name"}

  defp description(%{"description" => description}, path) when is_binary(description) do
    description = String.trim(description)

    cond do
      description == "" ->
        {:error, "#{path} skill needs a description"}

      String.length(description) > 1_024 ->
        {:error, "#{path} description is longer than 1024 characters"}

      true ->
        {:ok, description}
    end
  end

  defp description(_attributes, path), do: {:error, "#{path} skill needs a description"}

  defp command_description(attributes, body, path) do
    case Map.get(attributes, "description") do
      description when is_binary(description) ->
        description(%{"description" => description}, path)

      _missing ->
        description(%{"description" => first_paragraph(body)}, path)
    end
  end

  defp first_paragraph(body) do
    body
    |> String.trim()
    |> String.split(~r/\r?\n\s*\r?\n/, parts: 2)
    |> List.first()
    |> to_string()
    |> String.replace(~r/^#+\s*/, "")
    |> String.trim()
  end

  defp model_invocable(attributes, path) do
    with {:ok, disabled?} <- boolean(attributes, "disable-model-invocation", false, path) do
      {:ok, not disabled?}
    end
  end

  defp user_invocable(attributes, path),
    do: boolean(attributes, "user-invocable", true, path)

  defp boolean(attributes, key, default, path) do
    case Map.get(attributes, key, default) do
      value when is_boolean(value) -> {:ok, value}
      _invalid -> {:error, "#{path} #{key} must be true or false"}
    end
  end

  defp string(attributes, key) do
    case Map.get(attributes, key) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp compatibility_diagnostics(attributes, body, path) do
    [
      diagnostic(
        Map.has_key?(attributes, "allowed-tools"),
        "#{path}: allowed-tools is informational; lmx host policy remains authoritative"
      ),
      diagnostic(
        Map.get(attributes, "context") == "fork",
        "#{path}: context: fork is not supported by lmx; this skill runs inline"
      ),
      diagnostic(
        Map.has_key?(attributes, "model"),
        "#{path}: skill model override is not supported; the session model is unchanged"
      ),
      diagnostic(
        Map.has_key?(attributes, "agent"),
        "#{path}: skill agent selection is not supported; this skill runs in the main session"
      ),
      diagnostic(
        Map.has_key?(attributes, "hooks"),
        "#{path}: skill hooks are not executed; configure trusted lmx hooks explicitly"
      ),
      diagnostic(
        String.contains?(body, "!`"),
        "#{path}: dynamic command substitution is not executed; literal instructions are loaded"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp diagnostic(true, message), do: message
  defp diagnostic(false, _message), do: nil

  defp expand_directories(body, skill) do
    body = String.replace(body, "${CLAUDE_SKILL_DIR}", skill.root)

    case skill.plugin_root do
      nil -> body
      plugin_root -> String.replace(body, "${CLAUDE_PLUGIN_ROOT}", plugin_root)
    end
  end

  defp substitute(body, arguments) do
    positional = String.split(arguments, ~r/\s+/, trim: true)

    {body, indexed?} =
      Regex.replace(~r/\$ARGUMENTS\[(\d+)\]|\$(\d+)/, body, fn whole, long, short ->
        index = if long == "", do: short, else: long

        case Integer.parse(index) do
          {position, ""} -> Enum.at(positional, position, whole)
          _invalid -> whole
        end
      end)
      |> then(&{&1, &1 != body})

    replaced = String.replace(body, "$ARGUMENTS", arguments)

    if arguments != "" and replaced == body and not indexed?,
      do: body <> "\n\nARGUMENTS: " <> arguments,
      else: replaced
  end
end
