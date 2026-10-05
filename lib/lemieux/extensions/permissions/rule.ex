defmodule Lemieux.Extensions.Permissions.Rule do
  @moduledoc """
  One permission rule, written the way Claude Code writes them.

      "Bash"                       every bash command
      "Bash(git status)"           exactly that command
      "Bash(npm run test:*)"       that command and any arguments after it
      "Bash(git * --help)"         a pattern, `*` matching anything
      "Edit"                       every file-editing tool (edit, write, apply_patch)
      "Edit(src/**)"               file edits under src/ (relative to the session directory)
      "Read(.env)"                 reading, grepping or globbing that file
      "WebFetch(domain:hex.pm)"    fetches from hex.pm and its subdomains
      "mcp__github"                every tool of the MCP server `github`
      "mcp__github__create_issue"  one MCP tool
      "todo"                       a Lemieux tool by its own name

  Tool names are case-insensitive and translated through
  `Lemieux.Hooks.Claude`, so `Edit` and `edit` both cover every tool that
  changes a file — the same breadth Claude Code gives its own `Edit` rule.
  Paths: relative patterns are resolved against the session's working
  directory, `~/` against the home directory, and a leading `/` (or Claude's
  `//`) is absolute. `**` matches any depth, `*` and `?` one path segment.

  A call has *parts*: the commands of a compound bash line
  (`Lemieux.Extensions.Permissions.Shell`), the files an `apply_patch`
  touches, the host a fetch goes to. `covers?/3` asks whether a set of allow
  rules approves *every* part; `hits?/3` asks whether any rule matches *any*
  part. Allow needs the former and deny the latter, which is the asymmetry
  that keeps `safe && unsafe` from riding on the safe half's approval.
  """

  alias Lemieux.Extensions.Permissions.Shell
  alias Lemieux.Hooks.Claude

  @typedoc "What a rule says about a call's arguments."
  @type specifier ::
          nil
          | {:command, :exact | :prefix, String.t()}
          | {:command, :pattern, Regex.t()}
          | {:path, String.t()}
          | {:domain, String.t()}

  @typedoc "Which tools a rule applies to."
  @type tools :: {:names, [String.t()]} | {:prefix, String.t()}

  @type t :: %__MODULE__{source: String.t(), tools: tools(), specifier: specifier()}

  @enforce_keys [:source, :tools, :specifier]
  defstruct [:source, :tools, :specifier]

  @doc """
  Parses one rule string.
  """
  @spec parse(source :: String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(source) when is_binary(source) do
    case Regex.run(~r/\A\s*([A-Za-z0-9_\-*]+)\s*(?:\((.*)\))?\s*\z/s, source) do
      [_whole, name] -> build(source, name, nil)
      [_whole, name, specifier] -> build(source, name, String.trim(specifier))
      nil -> {:error, "invalid permission rule #{inspect(source)}"}
    end
  end

  def parse(other), do: {:error, "a permission rule must be a string, got: #{inspect(other)}"}

  @doc "Parses a list of rule strings, failing on the first invalid one."
  @spec parse_all(sources :: [String.t()]) :: {:ok, [t()]} | {:error, String.t()}
  def parse_all(sources) when is_list(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, rules} ->
      case parse(source) do
        {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rules} -> {:ok, Enum.reverse(rules)}
      error -> error
    end
  end

  def parse_all(other), do: {:error, "permission rules must be a list, got: #{inspect(other)}"}

  defp build(source, name, specifier) do
    with {:ok, tools} <- tools(name),
         {:ok, specifier} <- specifier(tools, specifier) do
      {:ok, %__MODULE__{source: source, tools: tools, specifier: specifier}}
    end
  end

  defp tools("mcp__" <> rest = name) do
    cond do
      String.ends_with?(rest, "__*") -> {:ok, {:prefix, String.trim_trailing(name, "*")}}
      String.contains?(rest, "__") -> {:ok, {:names, [String.downcase(name)]}}
      true -> {:ok, {:prefix, name <> "__"}}
    end
  end

  defp tools(name) do
    case Claude.lemieux_tools(name) do
      :unknown -> {:ok, {:names, [String.downcase(name)]}}
      names -> {:ok, {:names, names}}
    end
  end

  defp specifier(_tools, nil), do: {:ok, nil}
  defp specifier(_tools, ""), do: {:ok, nil}
  defp specifier(_tools, "*"), do: {:ok, nil}

  defp specifier({:names, names}, specifier) do
    cond do
      "bash" in names ->
        {:ok, command(specifier)}

      Enum.any?(names, &(&1 in ["web_fetch"])) ->
        domain(specifier)

      Enum.any?(names, &(&1 in ["read", "write", "edit", "apply_patch", "grep", "glob"])) ->
        {:ok, {:path, specifier}}

      true ->
        {:error, "#{Enum.join(names, "/")} rules take no argument, got #{inspect(specifier)}"}
    end
  end

  defp specifier({:prefix, _prefix}, specifier),
    do: {:error, "MCP rules take no argument, got #{inspect(specifier)}"}

  defp command(specifier) do
    text = Shell.normalize(specifier)

    cond do
      String.ends_with?(text, ":*") ->
        {:command, :prefix, text |> String.trim_trailing(":*") |> String.trim()}

      String.contains?(text, "*") ->
        {:command, :pattern, glob(text)}

      true ->
        {:command, :exact, text}
    end
  end

  defp domain("domain:" <> host) when host != "", do: {:ok, {:domain, String.downcase(host)}}

  defp domain(other),
    do: {:error, "fetch rules name a domain, like domain:example.com; got #{inspect(other)}"}

  # `*` matches anything in a command, including spaces.
  defp glob(text) do
    source = text |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
    Regex.compile!("\\A" <> source <> "\\z")
  end

  @doc """
  Whether `rules`, taken together, approve every part of `call`.

  A complex shell command is approved only by an exact rule for the whole
  command: its parts cannot be trusted to be the whole story.
  """
  @spec covers?(rules :: [t()], call :: map(), context :: map()) :: boolean()
  def covers?([], _call, _context), do: false

  def covers?(rules, call, context) do
    rules = Enum.filter(rules, &applies?(&1, call, context))

    case parts(call, context) do
      [] ->
        false

      {:complex, command} ->
        Enum.any?(rules, &exact_command?(&1, command))

      {:whole, _whole} ->
        Enum.any?(rules, &(&1.specifier == nil))

      parts ->
        Enum.all?(parts, fn part -> Enum.any?(rules, &part_matches?(&1, part, context)) end)
    end
  end

  @doc """
  The first rule in `rules` that matches any part of `call`, or `nil`.
  """
  @spec hit(rules :: [t()], call :: map(), context :: map()) :: t() | nil
  def hit(rules, call, context) do
    candidates = deny_parts(call, context)

    rules
    |> Enum.filter(&applies?(&1, call, context))
    |> Enum.find(fn rule ->
      case candidates do
        {:whole, _whole} -> rule.specifier == nil
        [] -> rule.specifier == nil
        parts -> Enum.any?(parts, &part_matches?(rule, &1, context))
      end
    end)
  end

  # For a command, every piece `Shell.pieces/1` finds and the whole line;
  # for everything else, the same parts an allow rule sees.
  defp deny_parts(%{name: "bash", arguments: %{"command" => command}}, _context)
       when is_binary(command) do
    Enum.map([Shell.normalize(command) | Shell.pieces(command)], &{:command, &1})
  end

  defp deny_parts(call, context) do
    case parts(call, context) do
      {:complex, command} -> [{:command, command}]
      other -> other
    end
  end

  @doc "Whether any rule in `rules` matches any part of `call`."
  @spec hits?(rules :: [t()], call :: map(), context :: map()) :: boolean()
  def hits?(rules, call, context), do: hit(rules, call, context) != nil

  # --- Which tool -------------------------------------------------------------

  defp applies?(%__MODULE__{tools: tools}, call, context) do
    names = candidate_names(call, context)

    case tools do
      {:names, accepted} -> Enum.any?(names, &(&1 in accepted))
      {:prefix, prefix} -> Enum.any?(names, &String.starts_with?(&1, String.downcase(prefix)))
    end
  end

  defp candidate_names(call, context) do
    descriptor = Map.get(context, :tool_descriptor)
    Enum.map([call.name | Claude.tool_aliases(call.name, descriptor)], &String.downcase/1)
  end

  # --- The parts of a call ----------------------------------------------------

  defp parts(%{name: name, arguments: arguments}, context) do
    cond do
      is_binary(arguments["command"]) and name == "bash" -> command_parts(arguments["command"])
      is_binary(arguments["url"]) -> url_parts(arguments["url"])
      paths = paths(name, arguments, context) -> Enum.map(paths, &{:path, &1})
      true -> {:whole, name}
    end
  end

  defp command_parts(command) do
    case Shell.split(command) do
      {:simple, parts} -> Enum.map(parts, &{:command, &1})
      {:complex, _parts} -> {:complex, Shell.normalize(command)}
    end
  end

  defp url_parts(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> [{:domain, String.downcase(host)}]
      _other -> []
    end
  end

  # The files a call touches, absolute. `apply_patch` names its files inside
  # the patch; every other file tool takes a `path`, which for grep and glob
  # is the directory searched (the session directory when omitted).
  defp paths(name, arguments, context) do
    cwd = Map.get(context, :cwd, File.cwd!())

    cond do
      patch = patch_text(arguments) ->
        patch |> patch_paths() |> Enum.map(&Path.expand(&1, cwd))

      name in ["grep", "glob"] ->
        [Path.expand(arguments["path"] || ".", cwd)]

      is_binary(arguments["path"]) ->
        [Path.expand(arguments["path"], cwd)]

      true ->
        nil
    end
  end

  defp patch_text(arguments) do
    Enum.find_value(arguments, fn
      {_key, value} when is_binary(value) ->
        if String.contains?(value, "*** Begin Patch"), do: value

      _other ->
        nil
    end)
  end

  defp patch_paths(patch) do
    ~r/^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$/m
    |> Regex.scan(patch, capture: :all_but_first)
    |> Enum.map(fn [path] -> String.trim(path) end)
  end

  # --- Matching one part ------------------------------------------------------

  defp part_matches?(%__MODULE__{specifier: nil}, _part, _context), do: true

  defp part_matches?(
         %__MODULE__{specifier: {:command, :exact, text}},
         {:command, part},
         _context
       ),
       do: Shell.normalize(part) == text

  defp part_matches?(
         %__MODULE__{specifier: {:command, :prefix, prefix}},
         {:command, part},
         _context
       ) do
    part = Shell.normalize(part)
    part == prefix or String.starts_with?(part, prefix <> " ")
  end

  defp part_matches?(
         %__MODULE__{specifier: {:command, :pattern, regex}},
         {:command, part},
         _context
       ),
       do: Regex.match?(regex, Shell.normalize(part))

  defp part_matches?(%__MODULE__{specifier: {:path, pattern}}, {:path, path}, context),
    do: Regex.match?(path_regex(pattern, Map.get(context, :cwd, File.cwd!())), path)

  defp part_matches?(%__MODULE__{specifier: {:domain, domain}}, {:domain, host}, _context),
    do: host == domain or String.ends_with?(host, "." <> domain)

  defp part_matches?(_rule, _part, _context), do: false

  defp exact_command?(%__MODULE__{specifier: {:command, :exact, text}}, command),
    do: command == text

  defp exact_command?(_rule, _command), do: false

  defp path_regex(pattern, cwd) do
    base = pattern |> anchor(cwd) |> Path.expand()

    # A pattern naming a directory covers what is inside it too, as a
    # directory permission is read by a person.
    source =
      base
      |> String.split("**")
      |> Enum.map_join(".*", fn piece ->
        piece
        |> String.split("*")
        |> Enum.map_join("[^/]*", fn segment ->
          segment |> String.split("?") |> Enum.map_join("[^/]", &Regex.escape/1)
        end)
      end)

    Regex.compile!("\\A" <> source <> "(?:/.*)?\\z")
  end

  defp anchor("//" <> absolute, _cwd), do: "/" <> absolute
  defp anchor("/" <> _rest = absolute, _cwd), do: absolute
  defp anchor("~/" <> rest, _cwd), do: Path.join(System.user_home!(), rest)
  defp anchor(relative, cwd), do: Path.join(cwd, relative)
end
