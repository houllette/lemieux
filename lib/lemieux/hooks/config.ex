defmodule Lemieux.Hooks.Config do
  @moduledoc """
  Reads command hook files: Lemieux's versioned format, and Claude Code's
  settings file as it is.

  The versioned shape deliberately follows the convention established by
  coding-agent CLIs: an event owns a list, a list item may be a command
  directly or a matcher group with its own `hooks`, and commands receive JSON
  on stdin.

      {
        "version": 1,
        "hooks": {
          "preToolUse": [{
            "matcher": "bash|edit",
            "hooks": [{"type": "command", "command": "./policy.sh"}]
          }],
          "agentStop": [{"command": "./verify.sh", "timeout": 30000}]
        }
      }

  The canonical event names are `sessionStart`, `attention`,
  `userPromptSubmitted`, `preToolUse`, `postToolUse`, `agentStop`,
  `errorOccurred` and `sessionEnd`. Common Claude Code and Gemini CLI spellings
  are accepted too, which keeps a hook script portable even when its
  surrounding settings file is not.

  ## Claude Code settings files

  A document with a `"hooks"` object and no `"version"` is read as a Claude
  Code settings file — `.claude/settings.json` passed as it is. Three things
  change with it, because they are what such a file means:

    * a command's `"timeout"` is in **seconds**, as Claude Code documents it,
      not milliseconds (`"timeoutMs"` is still milliseconds anywhere);
    * the commands are `:claude` dialect (`Lemieux.Hooks.Command`): they are
      shown Claude's event names, tool names and input fields;
    * an event or hook type Lemieux has no equivalent for (`PreCompact`,
      `SubagentStop`, a `"prompt"` hook) is skipped with a warning instead of
      failing the file. A settings file written for another program is
      entitled to mention things this one does not do; a versioned Lemieux
      file is not, and still fails.

  Other settings keys (`permissions`, `env`, …) are ignored here.
  `"disableAllHooks": true` loads nothing, as it says. A versioned file that
  sets `"dialect": "claude"` is read exactly like a Claude Code settings file.

  ## Exec form

  A command with `"args"` — a list of strings — is exec form in either
  format: `command` is the program and `args` its arguments, each passed
  exactly as written, with no shell reading either (`Lemieux.Hooks.Command`).
  A bare program name with a space in it beside `args` (`"node script.js"`)
  is loaded with a warning, as Claude Code warns: there is no program by
  that name, and the extra words belong in `args`.

  Reading the file is still an explicit act: nothing here looks for
  `.claude/settings.json` in a checkout. Trust stays with whoever named it.
  """

  require Logger

  alias Lemieux.Environment.Credentials
  alias Lemieux.Hooks.Command

  @events %{
    "sessionStart" => :session_start,
    "SessionStart" => :session_start,
    "attention" => :attention,
    "Notification" => :attention,
    "userPromptSubmitted" => :user_prompt,
    "UserPromptSubmit" => :user_prompt,
    "BeforeAgent" => :user_prompt,
    "preToolUse" => :before_tool_call,
    "PreToolUse" => :before_tool_call,
    "BeforeTool" => :before_tool_call,
    "postToolUse" => :after_tool_call,
    "PostToolUse" => :after_tool_call,
    "AfterTool" => :after_tool_call,
    "agentStop" => :stop,
    "Stop" => :stop,
    "AfterAgent" => :stop,
    "errorOccurred" => :error,
    "sessionEnd" => :session_end,
    "SessionEnd" => :session_end
  }

  @default_timeout 60_000

  @typedoc "Hooks, and what could not be loaded from a file written for another program."
  @type loaded :: %{hooks: Lemieux.Hooks.t(), warnings: [String.t()]}

  @doc """
  Reads `path`, returning hooks suitable for `Lemieux.start_session/1`.

  Warnings (see `load/2`) are logged. A host that can show them to a person
  should call `load/2` instead.

  Options are those of `load/2`.
  """
  @spec read(path :: Path.t(), opts :: keyword()) ::
          {:ok, Lemieux.Hooks.t()} | {:error, String.t()}
  def read(path, opts \\ []) when is_binary(path) do
    with {:ok, %{hooks: hooks, warnings: warnings}} <- load(path, opts) do
      Enum.each(warnings, &Logger.warning("lemieux: " <> &1))
      {:ok, hooks}
    end
  end

  @doc """
  Loads hooks from a file path or an already-decoded document.

  A map may be a whole hooks document (versioned, or a Claude Code settings
  file) or just the events object — what `~/.lmx/config.json` holds under
  `"hooks"`. An events object is `:lemieux` dialect unless `:dialect` says
  otherwise.

  Options:

    * `:dialect` — `:lemieux` or `:claude`, for a bare events object.
    * `:credentials` — a `t:Lemieux.Environment.Credentials.policy/0` every
      loaded command runs under, overriding the session's. Omitted, commands
      follow the environment the session runs tools in.
  """
  @spec load(source :: Path.t() | map(), opts :: keyword()) ::
          {:ok, loaded()} | {:error, String.t()}
  def load(source, opts \\ [])

  def load(path, opts) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, document} <- JSON.decode(contents),
         {:ok, loaded} <- parse(document, opts) do
      {:ok, loaded}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "could not read hook config #{path}: #{:file.format_error(reason)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, "invalid hook config #{path}: #{reason}"}

      # `JSON.decode/1` failures are bare tuples, never the `DecodeError`
      # struct this clause used to match; interpolating them into the message
      # crashed instead of reporting. Every `parse/2` reason is a binary, so
      # what reaches here is the decoder's.
      {:error, reason} ->
        {:error, "could not parse hook config #{path}: #{Lemieux.JSON.describe_error(reason)}"}
    end
  end

  def load(document, opts) when is_map(document) do
    case parse(document, opts) do
      {:ok, loaded} -> {:ok, loaded}
      {:error, reason} -> {:error, "invalid hook config: #{reason}"}
    end
  end

  defp parse(document, opts) do
    with {:ok, credentials} <- credentials(opts) do
      document
      |> shape(opts)
      |> build(credentials)
    end
  end

  defp credentials(opts) do
    case Keyword.fetch(opts, :credentials) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, policy} -> Credentials.policy(policy)
    end
  end

  # Which document this is decides the dialect; see the moduledoc.
  defp shape(%{"version" => 1, "hooks" => hooks} = document, _opts) when is_map(hooks),
    do: {:ok, hooks, dialect(Map.get(document, "dialect"), :lemieux)}

  defp shape(%{"version" => 1}, _opts), do: {:error, "a version 1 document needs a hooks object"}

  defp shape(%{"version" => version}, _opts),
    do: {:error, "unsupported version #{inspect(version)}"}

  defp shape(%{"disableAllHooks" => true}, _opts), do: :disabled
  defp shape(%{"hooks" => hooks}, _opts) when is_map(hooks), do: {:ok, hooks, :claude}

  defp shape(%{} = events, opts) when map_size(events) > 0 do
    if Enum.all?(Map.keys(events), &Map.has_key?(@events, &1)),
      do: {:ok, events, Keyword.get(opts, :dialect, :lemieux)},
      else: {:error, "expected an object with version 1 and a hooks object"}
  end

  defp shape(%{}, _opts), do: {:ok, %{}, :lemieux}

  defp shape(_document, _opts),
    do: {:error, "expected an object with version 1 and a hooks object"}

  defp dialect("claude", _default), do: :claude
  defp dialect(_other, default), do: default

  defp build(:disabled, _credentials),
    do: {:ok, %{hooks: [], warnings: ["disableAllHooks is set, so no hooks were loaded"]}}

  defp build({:error, reason}, _credentials), do: {:error, reason}

  defp build({:ok, hooks, dialect}, credentials) do
    settings = %{dialect: dialect, credentials: credentials}

    hooks
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, [], []}, fn {name, groups}, {:ok, acc, warnings} ->
      case event(name, groups, settings) do
        {:ok, handlers, new_warnings} ->
          {:cont, {:ok, Enum.reverse(handlers, acc), warnings ++ new_warnings}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, handlers, warnings} -> {:ok, %{hooks: Enum.reverse(handlers), warnings: warnings}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp event(name, groups, settings) do
    case {Map.fetch(@events, name), settings.dialect} do
      {{:ok, event}, _dialect} ->
        with {:ok, commands, warnings} <- groups(groups, settings) do
          {:ok, Enum.map(commands, &{event, &1}), warnings}
        end

      {:error, :claude} ->
        {:ok, [], ["hook event #{inspect(name)} has no Lemieux equivalent and was skipped"]}

      {:error, :lemieux} ->
        {:error, "unknown hook event #{inspect(name)}"}
    end
  end

  defp groups(groups, settings) when is_list(groups) do
    groups
    |> Enum.reduce_while({:ok, [], []}, fn group, {:ok, acc, warnings} ->
      case group(group, settings) do
        {:ok, commands, new_warnings} ->
          {:cont, {:ok, Enum.reverse(commands, acc), warnings ++ new_warnings}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, commands, warnings} -> {:ok, Enum.reverse(commands), warnings}
      {:error, reason} -> {:error, reason}
    end
  end

  defp groups(_groups, _settings), do: {:error, "each hook event must contain a list"}

  defp group(%{"hooks" => hooks} = group, settings) when is_list(hooks) do
    matcher = Map.get(group, "matcher")

    hooks
    |> Enum.reduce_while({:ok, [], []}, fn hook, {:ok, acc, warnings} ->
      case command(hook, matcher, settings) do
        {:ok, command} -> {:cont, {:ok, [command | acc], warnings}}
        {:ok, command, warning} -> {:cont, {:ok, [command | acc], [warning | warnings]}}
        {:skip, warning} -> {:cont, {:ok, acc, [warning | warnings]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, commands, warnings} -> {:ok, Enum.reverse(commands), Enum.reverse(warnings)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp group(%{} = hook, settings) do
    case command(hook, Map.get(hook, "matcher"), settings) do
      {:ok, command} -> {:ok, [command], []}
      {:ok, command, warning} -> {:ok, [command], [warning]}
      {:skip, warning} -> {:ok, [], [warning]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp group(_group, _settings), do: {:error, "each hook must be an object"}

  defp command(%{"command" => command} = hook, matcher, settings)
       when is_binary(command) and command != "" do
    type = Map.get(hook, "type", "command")
    env = Map.get(hook, "env", %{})
    cwd = Map.get(hook, "cwd")
    name = Map.get(hook, "name")
    args = Map.get(hook, "args")

    with :ok <- validate_type(type, settings.dialect),
         {:ok, timeout} <- timeout(hook, settings.dialect),
         :ok <- validate_env(env),
         :ok <- validate_matcher(matcher),
         :ok <- validate_optional_string(cwd, "cwd"),
         :ok <- validate_optional_string(name, "name"),
         :ok <- validate_args(args) do
      %Command{
        command: command,
        args: args,
        matcher: matcher,
        name: name,
        timeout: timeout,
        cwd: cwd,
        env: env,
        dialect: settings.dialect,
        credentials: settings.credentials
      }
      |> with_exec_warning()
    end
  end

  defp command(%{"type" => type}, _matcher, %{dialect: :claude}) when type != "command",
    do: {:skip, "a #{inspect(type)} hook has no Lemieux equivalent and was skipped"}

  defp command(_hook, _matcher, _settings),
    do: {:error, "a command hook needs a non-empty command"}

  defp validate_type("command", _dialect), do: :ok

  defp validate_type(type, :claude),
    do: {:skip, "a #{inspect(type)} hook has no Lemieux equivalent and was skipped"}

  defp validate_type(type, _dialect), do: {:error, "unsupported hook type #{inspect(type)}"}

  # Milliseconds in a Lemieux file, seconds in a Claude Code one — each as its
  # own documentation says. Reading Claude's `"timeout": 30` as milliseconds
  # killed every such hook before it could start, which looked like a hook
  # that never ran rather than a unit mistake.
  defp timeout(%{"timeoutMs" => timeout}, _dialect), do: positive(timeout, 1)
  defp timeout(%{"timeout" => timeout}, :claude), do: positive(timeout, 1_000)
  defp timeout(%{"timeout" => timeout}, _dialect), do: positive(timeout, 1)
  defp timeout(_hook, _dialect), do: {:ok, @default_timeout}

  defp positive(value, scale) when is_integer(value) and value > 0, do: {:ok, value * scale}

  defp positive(value, 1_000) when is_float(value) and value > 0,
    do: {:ok, max(round(value * 1_000), 1)}

  defp positive(_value, _scale),
    do:
      {:error, "hook timeout must be a positive integer (milliseconds; seconds in Claude files)"}

  defp valid_env?(env) when is_map(env) do
    Enum.all?(env, fn {key, value} -> is_binary(key) and is_binary(value) end)
  end

  defp valid_env?(_env), do: false

  defp validate_env(env) do
    if valid_env?(env), do: :ok, else: {:error, "hook env must map strings to strings"}
  end

  defp validate_matcher(matcher) when not is_nil(matcher) and not is_binary(matcher),
    do: {:error, "hook matcher must be a string"}

  defp validate_matcher(matcher) do
    if Command.valid_matcher?(matcher),
      do: :ok,
      else: {:error, "hook matcher is not a valid regular expression"}
  end

  defp validate_optional_string(value, name) do
    if optional_string?(value), do: :ok, else: {:error, "hook #{name} must be a string"}
  end

  defp validate_args(nil), do: :ok

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &is_binary/1),
      do: :ok,
      else: {:error, "hook args must be a list of strings"}
  end

  defp validate_args(_args), do: {:error, "hook args must be a list of strings"}

  defp with_exec_warning(%Command{args: args, command: program} = command) when is_list(args) do
    if String.contains?(program, " ") and not String.contains?(program, ["/", "\\"]) do
      {:ok, command,
       "exec-form hook #{inspect(program)} names no program: with args, command is the " <>
         "program alone, so move the other words into args"}
    else
      {:ok, command}
    end
  end

  defp with_exec_warning(command), do: {:ok, command}

  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value)
end
