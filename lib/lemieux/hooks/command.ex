defmodule Lemieux.Hooks.Command do
  @moduledoc """
  An external command attached to an agent lifecycle event.

  Commands receive one JSON object on stdin and may return one JSON object on
  stdout. Exit `0` means success, exit `2` blocks an event that can still be
  blocked, and every other status is a warning. This is the convention shared
  by Claude Code and Gemini CLI; keeping it here means a policy script does
  not need an Elixir adapter just to run under lemieux.

  A hook is an explicit capability. It runs with the session's working
  directory and OS permissions, exactly like the `bash` tool. Lemieux never
  discovers or runs a hook file merely because a checkout contains one: a
  host passes hooks, and `lmx` does so only when a person configured them.

  ## Shell form and exec form

  A command without `args` is shell form: `command` is a script, run by
  `bash` (or `sh`), with the JSON input redirected from a file. A command
  with `args` is exec form, as Claude Code defines it: `command` is the
  program — a path, or a name looked up on `PATH` — and `args` its argument
  vector, each element one argument exactly as written. Nothing in either is
  read by a shell. `args` used to be ignored and the input JSON fed to a
  `bash` that read it as a script: a `$(…)` in a tool's arguments ran
  before any policy saw the call, under `read_only` and `--sandbox` too,
  and the hook's deny never applied.

  Exec form still starts through the shell, but only to run a fixed
  one-line script that connects stdin and stderr to their files and then
  `exec`s the program with the arguments as positional parameters, which a
  shell never parses. Erlang cannot give a port's program a file as stdin or
  close its stdin early, and a hook that reads its input to the end — `jq`,
  `json.load(sys.stdin)` — would otherwise wait for an end that never comes.

  On Windows the shell is Git for Windows' bash; WSL's `bash.exe` in the
  system directory is never used, because it runs the hook inside a Linux
  distribution that sees neither this environment nor these paths. Without
  Git Bash a hook is a warning that names what to install.

  ## Dialect

  `:dialect` says whose conventions the command was written for. A
  `:lemieux` command receives Lemieux's canonical event names and tool names,
  as it always has. A `:claude` command came from a Claude Code settings file
  and receives what such a script reads: `PreToolUse` rather than
  `preToolUse`, `Bash` rather than `bash`, `tool_input.file_path` beside
  `tool_input.path`, and a `tool_response` on `PostToolUse`. Translating the
  input rather than asking people to rewrite their scripts is the whole
  compatibility story; a script that silently never matched was the failure
  this replaced (`"matcher": "Bash"` compared against `bash`).

  A `:claude` command also gets what Claude Code exports to a hook:
  `CLAUDE_PROJECT_DIR`, the directory the session started in. Its project
  hooks are written as `"${CLAUDE_PROJECT_DIR}/.claude/hooks/check.sh"`;
  without the variable that path became `/.claude/hooks/check.sh`, the hook
  failed to start, and a hook that fails to start does not block — an
  `rm` guard written that way let the `rm` run. A plugin's commands get
  `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA` in `env`
  (`Lemieux.Extensions.Workspace.Plugin`); the data directory is created
  before the first command that is told about it runs. In exec form the
  three are also substituted into `command` and `args` wherever
  `${NAME}` appears, since there is no shell to expand them.

  A `"systemMessage"` in a command's JSON output is logged as a warning.
  Claude Code shows it to the person; a host decides whether warnings
  reach anyone, and `lmx` logs only errors unless `LMX_LOG_LEVEL` says
  otherwise, so there it appears with `LMX_LOG_LEVEL=warning`. A session
  event a screen could show is the missing piece.

  ## What a command inherits

  The command's environment follows the session's credential policy. A tool
  hook sees the policy of the environment the tool runs in
  (`Lemieux.Environment.credentials/1`), so a session whose `bash` cannot read
  `OPENAI_API_KEY` does not hand it to a hook script instead. `:credentials`
  on the command overrides that; `nil` follows the session.

  The JSON on stdin is written to a file in a directory only the launching
  user can open. The previous `/tmp/lemieux-hook-N.in` was created with the
  default umask, which on a shared Linux machine let any local user read every
  prompt and tool input a hook was shown.

  ## A command that runs too long

  Is stopped together with whatever it started. A port's program leads a
  process group of its own, so the group is signalled — with `kill`, or the
  shell's `kill` builtin on images that ship no `kill` executable (Debian
  slim images do not), or `taskkill /T` on Windows — and a hook's background
  `sleep` no longer outlives its timeout; where the program does not lead a
  group, it alone is signalled. Not being able to signal it is logged; it
  never takes the hook's caller down — `System.cmd("kill", …)` raised when
  there was no `kill`, and only `ArgumentError` was rescued.
  """

  require Logger

  alias Lemieux.Environment
  alias Lemieux.Environment.Credentials
  alias Lemieux.Environment.Inherited
  alias Lemieux.Environment.Local
  alias Lemieux.Tool

  @default_timeout 60_000
  @max_output 100_000

  # The only script exec form ever hands a shell. `$0` is a label; `$1` and
  # `$2` are the input and error files; everything after them is the
  # program and its arguments, as data.
  @exec_script ~S(input=$1; errors=$2; shift 2; exec "$@" < "$input" 2> "$errors")

  # What a Claude Code hook may name with `${…}` in exec form.
  @placeholders ~w(CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA)

  @type outcome :: {:ok, map()} | {:block, String.t()} | {:warning, String.t()}

  @typedoc "Whose event names, tool names and input fields the command expects."
  @type dialect :: :lemieux | :claude

  @type t :: %__MODULE__{
          command: String.t(),
          args: [String.t()] | nil,
          matcher: String.t() | nil,
          name: String.t() | nil,
          timeout: pos_integer(),
          cwd: Path.t() | nil,
          env: %{optional(String.t()) => String.t()},
          dialect: dialect(),
          credentials: Credentials.policy() | nil
        }

  @enforce_keys [:command]
  defstruct [
    :command,
    :args,
    :matcher,
    :name,
    :cwd,
    :credentials,
    timeout: @default_timeout,
    env: %{},
    dialect: :lemieux
  ]

  # Ordinary name characters. A matcher made only of these is a list of exact,
  # `|`-separated names; anything else is a regular expression.
  @simple_matcher ~r/^[A-Za-z0-9_.|:-]+$/

  @doc """
  Whether this hook's matcher accepts `value`.

  Empty and `*` match everything. A matcher made only of ordinary name
  characters uses exact `|`-separated alternatives; every other matcher is a
  regular expression. Both compare without regard to case: tool names are
  lower-case here and capitalised in Claude Code, and a gate that silently
  never matched because of a capital letter is a gate that was never there.
  """
  @spec matches?(command :: t(), value :: String.t()) :: boolean()
  def matches?(%__MODULE__{} = command, value) when is_binary(value),
    do: matches_any?(command, [value])

  @doc """
  Whether this hook's matcher accepts any of `values`.

  Tool hooks are matched against the tool's name and every alias it answers
  to (`Lemieux.Hooks.Claude.tool_aliases/2`), so `"Edit|Write"` written for
  Claude Code matches `edit` and `write`.
  """
  @spec matches_any?(command :: t(), values :: [String.t()]) :: boolean()
  def matches_any?(%__MODULE__{matcher: matcher}, _values) when matcher in [nil, "", "*"],
    do: true

  def matches_any?(%__MODULE__{matcher: matcher}, values) when is_list(values) do
    if Regex.match?(@simple_matcher, matcher) do
      names = matcher |> String.split("|") |> MapSet.new(&String.downcase/1)
      Enum.any?(values, &MapSet.member?(names, String.downcase(&1)))
    else
      case Regex.compile(matcher, "i") do
        {:ok, regex} -> Enum.any?(values, &Regex.match?(regex, &1))
        {:error, _reason} -> false
      end
    end
  end

  @doc """
  Whether `matcher` is one `matches?/2` can evaluate: empty, `*`, a list of
  names, or a regular expression that compiles.
  """
  @spec valid_matcher?(matcher :: String.t() | nil) :: boolean()
  def valid_matcher?(matcher) when matcher in [nil, "", "*"], do: true

  def valid_matcher?(matcher) when is_binary(matcher) do
    Regex.match?(@simple_matcher, matcher) or match?({:ok, _regex}, Regex.compile(matcher, "i"))
  end

  def valid_matcher?(_matcher), do: false

  @doc """
  The names this command's matcher lists when it is a plain name list, or
  `:pattern` when it is a regular expression or matches everything.

  For `Lemieux.Hooks.unmatched/2`, which can only say a list of names matches
  nothing; a pattern might match a tool that appears later.
  """
  @spec matcher_names(command :: t()) :: [String.t()] | :pattern
  def matcher_names(%__MODULE__{matcher: matcher}) when matcher in [nil, "", "*"], do: :pattern

  def matcher_names(%__MODULE__{matcher: matcher}) do
    if Regex.match?(@simple_matcher, matcher),
      do: String.split(matcher, "|"),
      else: :pattern
  end

  @doc """
  Runs the hook with `input` encoded as JSON on stdin.
  """
  @spec run(command :: t(), input :: map(), context :: map()) :: outcome()
  def run(%__MODULE__{} = command, input, context) do
    case private_directory() do
      {:ok, directory} ->
        try do
          command |> run_in(input, context, directory) |> said(command)
        after
          File.rm_rf(directory)
        end

      {:error, reason} ->
        {:warning, "could not run hook #{label(command)}: #{describe(reason)}"}
    end
  end

  defp run_in(command, input, context, directory) do
    input_path = Path.join(directory, "input.json")
    error_path = Path.join(directory, "stderr")

    with :ok <- File.write(input_path, JSON.encode!(input)),
         :ok <- File.chmod(input_path, 0o600),
         {:ok, port} <- open(command, input_path, error_path, context) do
      collect(port, command, error_path)
    else
      {:error, reason} ->
        {:warning, "could not run hook #{label(command)}: #{describe(reason)}"}
    end
  rescue
    error -> {:warning, "could not run hook #{label(command)}: #{Exception.message(error)}"}
  end

  defp said({:ok, %{"systemMessage" => message}} = outcome, command)
       when is_binary(message) and message != "" do
    Logger.warning("lemieux: hook #{label(command)} says: #{message}")
    outcome
  end

  defp said(outcome, _command), do: outcome

  defp open(command, input_path, error_path, context) do
    environment = environment(command, context)

    with {:ok, shell} <- shell(),
         {:ok, args} <- arguments(command, input_path, error_path, environment) do
      prepare_data_directory(command)

      options = [
        :binary,
        :exit_status,
        :hide,
        args: args,
        cd: cwd(command, context),
        env: environment
      ]

      {:ok, Port.open({:spawn_executable, shell}, options)}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp arguments(%__MODULE__{args: nil} = command, input_path, error_path, _environment) do
    {:ok,
     [
       "-c",
       "{\n#{command.command}\n} < #{shell_quote(input_path)} 2> #{shell_quote(error_path)}"
     ]}
  end

  defp arguments(%__MODULE__{} = command, input_path, error_path, environment) do
    values = placeholder_values(environment)
    program = substitute(command.command, values)

    if String.starts_with?(program, "-") do
      {:error, "an exec-form hook's command is a program, and #{inspect(program)} is not one"}
    else
      {:ok,
       [
         "-c",
         @exec_script,
         "lmx-hook",
         input_path,
         error_path,
         program | Enum.map(command.args, &substitute(&1, values))
       ]}
    end
  end

  defp placeholder_values(environment) do
    environment
    |> Enum.reject(fn {_name, value} -> value == false end)
    |> Map.new(fn {name, value} -> {to_string(name), to_string(value)} end)
    |> Map.take(@placeholders)
  end

  defp substitute(text, values) do
    Enum.reduce(values, text, fn {name, value}, acc ->
      String.replace(acc, "${#{name}}", value)
    end)
  end

  # Claude Code creates a plugin's data directory when a component first uses
  # it; one made here is the person's alone, since a plugin keeps tokens
  # there. A hook that cannot have one still runs: most never write there.
  defp prepare_data_directory(%__MODULE__{env: %{"CLAUDE_PLUGIN_DATA" => data}})
       when is_binary(data) and data != "" do
    if not File.dir?(data) and File.mkdir_p(data) == :ok, do: File.chmod(data, 0o700)
    :ok
  end

  defp prepare_data_directory(_command), do: :ok

  @doc """
  The environment changes a command runs with: the host's corrections to
  this VM's environment (`Lemieux.Environment.Inherited`, the person's own
  `PATH` under the installed lmx) and the credentials its policy withholds,
  unset; then, for a `:claude` command, `CLAUDE_PROJECT_DIR` — the session's
  working directory; and then the command's own `env`, which wins.

  The command's own variables come last on purpose. A hook file that sets
  `GITHUB_TOKEN` for its own script has said, in so many words, that this
  script may have it.
  """
  @spec environment(command :: t(), context :: map()) :: [{charlist(), charlist() | false}]
  def environment(%__MODULE__{} = command, context) do
    inherited =
      command
      |> credential_policy(context)
      |> Inherited.overrides()
      |> Enum.reject(fn {name, _value} -> Map.has_key?(command.env, name) end)
      |> Enum.map(fn {name, value} -> {to_charlist(name), value && to_charlist(value)} end)

    inherited ++
      Enum.map(exported(command, context), fn {key, value} ->
        {to_charlist(key), to_charlist(value)}
      end)
  end

  defp exported(%__MODULE__{dialect: :claude} = command, %{cwd: cwd}) when is_binary(cwd),
    do: Map.merge(%{"CLAUDE_PROJECT_DIR" => cwd}, command.env)

  defp exported(%__MODULE__{} = command, _context), do: command.env

  defp credential_policy(%__MODULE__{credentials: nil}, %{environment: environment}),
    do: Environment.credentials(environment)

  defp credential_policy(%__MODULE__{credentials: nil}, _context), do: :inherit
  defp credential_policy(%__MODULE__{credentials: policy}, _context), do: policy

  defp cwd(%__MODULE__{cwd: nil}, context), do: Map.fetch!(context, :cwd)
  defp cwd(%__MODULE__{cwd: cwd}, context), do: Path.expand(cwd, Map.fetch!(context, :cwd))

  defp shell do
    case find_bash() do
      {:ok, shell} -> {:ok, shell}
      :error -> {:error, no_shell(:os.type())}
    end
  end

  defp no_shell({:win32, _name}),
    do:
      "no Git Bash was found; hooks on Windows run in Git for Windows' bash " <>
        "(https://git-scm.com/download/win), and WSL's bash is not used"

  defp no_shell(_unix), do: "there is no bash or sh on this machine's PATH"

  # The same shell the `bash` tool uses, so a hook and a tool call never
  # disagree about which bash a machine has: Git for Windows' bash on Windows
  # (never WSL's launcher), elsewhere `bash`, then `sh`. Never a hard-coded
  # `/bin/sh`: on Windows that path does not exist, and the spawn failure it
  # produced pointed at the hook instead of the install.
  defp find_bash, do: Local.find_bash()

  defp collect(port, command, error_path) do
    deadline = System.monotonic_time(:millisecond) + command.timeout

    receive_output(port, [], 0, deadline, command, error_path)
  end

  defp receive_output(port, acc, size, deadline, command, error_path) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        kept = keep(data, size)
        receive_output(port, [kept | acc], size + byte_size(kept), deadline, command, error_path)

      {^port, {:exit_status, status}} ->
        stdout = acc |> Enum.reverse() |> IO.iodata_to_binary() |> Tool.sanitize()
        stderr = read_error(error_path)
        interpret(status, stdout, stderr, command)
    after
      remaining ->
        kill(port)
        {:warning, "hook #{label(command)} timed out after #{command.timeout}ms"}
    end
  end

  defp keep(_data, size) when size >= @max_output, do: ""
  defp keep(data, size), do: binary_part(data, 0, min(byte_size(data), @max_output - size))

  defp interpret(2, stdout, stderr, command) do
    {:block, reason(stdout, stderr, command)}
  end

  defp interpret(0, stdout, _stderr, _command) when stdout in ["", "\n"], do: {:ok, %{}}

  defp interpret(0, stdout, _stderr, command) do
    case JSON.decode(stdout) do
      {:ok, output} when is_map(output) ->
        {:ok, output}

      {:ok, _output} ->
        {:warning, "hook #{label(command)} returned JSON that was not an object"}

      # Claude Code treats plain text a prompt or session hook prints as context
      # for the model. Keeping the text lets `Lemieux.Hooks` do the same for a
      # command written for it, instead of warning about "invalid JSON" a script
      # never meant to produce.
      {:error, _reason} when command.dialect == :claude ->
        {:ok, %{"plain_output" => String.trim(stdout)}}

      {:error, _reason} ->
        {:warning, "hook #{label(command)} returned invalid JSON on stdout"}
    end
  end

  defp interpret(status, stdout, stderr, command) do
    detail = stderr |> present(stdout) |> present("no error output")
    {:warning, "hook #{label(command)} exited with status #{status}: #{detail}"}
  end

  defp reason(stdout, stderr, command) do
    parsed_reason =
      case JSON.decode(stdout) do
        {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
        _otherwise -> nil
      end

    parsed_reason
    |> present(stderr)
    |> present(stdout)
    |> present("hook #{label(command)} blocked the action")
  end

  defp present(value, fallback) when value in [nil, ""], do: fallback
  defp present(value, _fallback), do: String.trim(value)

  defp read_error(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, @max_output) do
            text when is_binary(text) -> Tool.sanitize(text)
            _otherwise -> ""
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        ""
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> stop(os_pid)
      nil -> :ok
    end

    close(port)
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # The group first, then — when there is no such group, because this
  # platform did not make the program its leader — the program alone.
  defp stop(os_pid) do
    targets = [{:group, os_pid}, {:process, os_pid}]

    unless Enum.any?(targets, &signalled?(:os.type(), &1)) do
      Logger.warning(
        "lemieux: could not stop hook process #{os_pid}; what it started may still be running"
      )
    end
  end

  defp signalled?(os, target) do
    case signal_command(os, target, &System.find_executable/1) do
      nil ->
        false

      {program, args} ->
        {_output, status} = System.cmd(program, args, stderr_to_stdout: true)
        status == 0
    end
  rescue
    # A program found a moment ago and gone now, or one that cannot be
    # spawned: the hook's caller still gets its warning, not a crash.
    _error in [ErlangError, ArgumentError] -> false
  end

  @doc false
  # How to send SIGKILL to a hook's process group or process: the `kill`
  # executable, else the `kill` builtin of whatever shell there is — Debian
  # slim images ship no `procps` — and on Windows `taskkill /T`, which takes
  # the tree. POSIX spelling (`-s KILL`) for the builtin, because `dash`
  # rejects `-KILL --`. `nil` when there is nothing to signal with. Public so
  # each branch is tested without removing binaries from the machine.
  @spec signal_command(
          os :: {atom(), atom()},
          target :: {:group | :process, pos_integer()},
          find :: (String.t() -> String.t() | nil)
        ) :: {String.t(), [String.t()]} | nil
  def signal_command({:win32, _name}, {:group, _pid}, _find), do: nil

  def signal_command({:win32, _name}, {:process, pid}, find) do
    case find.("taskkill") do
      nil -> nil
      taskkill -> {taskkill, ["/F", "/T", "/PID", Integer.to_string(pid)]}
    end
  end

  def signal_command(_unix, target, find) do
    id = target_id(target)

    cond do
      kill = find.("kill") -> {kill, ["-KILL", "--", id]}
      shell = find.("sh") || find.("bash") -> {shell, ["-c", "kill -s KILL -- " <> id]}
      true -> nil
    end
  end

  defp target_id({:group, pid}), do: "-" <> Integer.to_string(pid)
  defp target_id({:process, pid}), do: Integer.to_string(pid)

  @doc false
  # A fresh directory per run, created before anything is written into it and
  # made owner-only straight away. `File.mkdir/1` refuses an existing name —
  # including a symlink somebody planted at a name they guessed — so the random
  # suffix only has to make collisions unlikely, not impossible; a collision is
  # retried rather than reused. Public only so a test can check the mode.
  @spec private_directory(attempts :: non_neg_integer()) :: {:ok, Path.t()} | {:error, term()}
  def private_directory(attempts \\ 3)

  def private_directory(0), do: {:error, "could not create a private temporary directory"}

  def private_directory(attempts) do
    suffix = 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    directory = Path.join(System.tmp_dir!(), "lemieux-hook-" <> suffix)

    case File.mkdir(directory) do
      :ok ->
        with :ok <- File.chmod(directory, 0o700), do: {:ok, directory}

      {:error, :eexist} ->
        private_directory(attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp shell_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"
  defp label(%__MODULE__{name: name}) when is_binary(name), do: inspect(name)
  defp label(%__MODULE__{command: command}), do: inspect(String.slice(command, 0, 80))
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
end
