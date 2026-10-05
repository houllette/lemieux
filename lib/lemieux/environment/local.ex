defmodule Lemieux.Environment.Local do
  @moduledoc """
  The default environment: confined files and local command processes.

  File paths are relative to the session working directory. `..` and
  symlinks that escape that directory are rejected with `:outside_worktree`.
  `Path.safe_relative/2` performs the symlink-aware check; a lexical
  `Path.expand/2` check would approve `worktree/link/secret` when `link`
  points outside the worktree.

  An absolute path is accepted when it names something *inside* the working
  directory: it is made relative first and then goes through the same check.
  Models copy absolute paths out of compiler errors and stack traces all the
  time, and refusing `/repo/lib/app.ex` while accepting `lib/app.ex` taught
  them nothing except that the tool was broken — they retried, or reached for
  `cat`, which is not confined at all. An absolute path outside the directory
  is still `:outside_worktree`.

  Bash is still intentionally unsandboxed here. It runs with the launching
  user's permissions because a shell command can escape any path convention.
  Hosts that require isolation replace the environment, leaving the provider
  call and policy process in the host VM while relocating tool execution.

  ## What commands inherit

  `new/1` takes a `:credentials` policy (see
  `Lemieux.Environment.Credentials`). The bare module — what
  `Lemieux.Environment.local/0` returns — inherits the VM's environment
  unchanged, which is the library default; `lmx` builds
  `new(credentials: {:scrub, allow})` so the model's shell cannot read the
  provider key that pays for it. Either way the host's corrections come
  first (`Lemieux.Environment.Inherited`): a VM a release started is not
  started from the person's environment, and its `PATH` would hand their
  commands the release's own Erlang.

  Commands use `Lemieux.Environment.Local.ExCmd` so output crosses into the
  BEAM only when the stream consumer asks for another chunk. An ordinary Port
  eagerly turns every chunk into a mailbox message; a model-controlled command
  can fill that unbounded mailbox before the output cap gets a chance to stop
  it. Lemieux still owns the wall deadline, byte cap, and semantic terminal
  events rather than delegating those agent-facing contracts to ExCmd.

  Standalone installations are native OTP releases, so ExCmd's helper
  remains a real executable in the release `priv` tree. There is no
  eager Port fallback: silently changing buffering and cancellation semantics
  according to packaging made the same command behave differently by host.

  ## Which shell

  Commands run under `find_bash/0`'s answer: `bash`, else `sh`, on macOS
  and Linux. On Windows it is Git for Windows' bash, which has to be chosen
  deliberately: Git's installer puts only `Git\\cmd` on `PATH`, so from
  PowerShell or `cmd` the first `bash.exe` on `PATH` is usually WSL's
  `C:\\Windows\\System32\\bash.exe`. That one runs the command inside a Linux
  distribution, on `/mnt/c` paths, with only the variables `WSLENV` forwards
  — so the credential scrub, `GIT_TERMINAL_PROMPT=0` and the process-group
  teardown all stop applying — and it is never used. A person who wants WSL
  runs the Linux build of lmx inside it.
  """

  @behaviour Lemieux.Environment

  alias Lemieux.Environment.Credentials
  alias Lemieux.Environment.Inherited
  alias Lemieux.Environment.Local.ExCmd, as: ExCmdRunner

  # What a foreground command may produce before it is stopped. The tool that
  # collects it holds this much in memory; a caller that bounds its own memory
  # (a background task keeps a head and a tail) passes `:infinity` instead.
  @hard_cap 8_000_000
  @chunk_bytes 65_536

  @typedoc "Local environment state: the credential policy commands run under."
  @type t :: %__MODULE__{credentials: Credentials.policy()}

  defstruct credentials: :inherit

  @doc """
  An environment on this machine with explicit options.

    * `:credentials` — a `t:Lemieux.Environment.Credentials.policy/0`, or
      `true`/`false` as shorthand for `{:scrub, []}`/`:inherit`. Defaults to
      `:inherit`.

  Raises on an invalid policy: an environment that quietly fell back to
  inheriting would hand out exactly the keys the caller asked it to withhold.
  """
  @spec new(opts :: keyword()) :: {module(), t()}
  def new(opts \\ []) when is_list(opts) do
    case Credentials.policy(Keyword.get(opts, :credentials, :inherit)) do
      {:ok, policy} -> {__MODULE__, %__MODULE__{credentials: policy}}
      {:error, message} -> raise ArgumentError, message
    end
  end

  @impl Lemieux.Environment
  def credentials(%__MODULE__{credentials: policy}), do: policy
  def credentials(_state), do: :inherit

  @doc """
  The bash this machine runs commands under, or `:error` when there is none
  to use.

  On macOS and Linux: `bash` on `PATH`, else `sh`. On Windows: Git for
  Windows' bash — at Git's standard install locations, then the
  installation `git --exec-path` belongs to — then any other bash on `PATH`
  (MSYS2, Cygwin), and never WSL's launcher; see "Which shell" above for
  why. Public so that code running commands of its own — command hooks, an
  external editor — can resolve its shell the same way, rather than run a
  second kind of shell on the same machine.
  """
  @spec find_bash() :: {:ok, Path.t()} | :error
  def find_bash do
    find_bash(:os.type(), %{
      executable: &System.find_executable/1,
      env: &System.get_env/1,
      file?: &File.regular?/1,
      git_exec_path: &git_exec_path/0
    })
  end

  @doc false
  # The decision apart from the machine it is made on, so the Windows rules
  # are tested on whichever platform the suite runs: `probe` answers
  # `:executable` (a name on PATH), `:env` (a variable), `:file?` and
  # `:git_exec_path` (what `git --exec-path` printed, or nil).
  @spec find_bash(os_type :: {atom(), atom()}, probe :: map()) :: {:ok, Path.t()} | :error
  def find_bash({:win32, _name}, probe) do
    # In order, each asked only when the one before found nothing: the
    # `git --exec-path` fork is paid only by an installation in an unusual place.
    found =
      Enum.find(Enum.flat_map(standard_git_roots(probe), &git_bashes/1), probe.file?) ||
        Enum.find(exec_path_bashes(probe), probe.file?) ||
        Enum.find(on_path(probe), &(not wsl_bash?(&1)))

    if found, do: {:ok, found}, else: :error
  end

  def find_bash(_unix, probe) do
    case probe.executable.("bash") || probe.executable.("sh") do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @doc false
  # WSL's `bash.exe`: the System32 launcher (or its Sysnative and SysWOW64
  # views) and the Microsoft Store's app alias under WindowsApps.
  @spec wsl_bash?(path :: String.t()) :: boolean()
  def wsl_bash?(path) when is_binary(path) do
    normalized = path |> String.replace("\\", "/") |> String.downcase()

    String.ends_with?(normalized, [
      "/windows/system32/bash.exe",
      "/windows/sysnative/bash.exe",
      "/windows/syswow64/bash.exe"
    ]) or String.contains?(normalized, "/microsoft/windowsapps/")
  end

  # Where Git for Windows installs itself: machine-wide under Program Files
  # (either view of it), or per user under %LOCALAPPDATA%\Programs.
  defp standard_git_roots(probe) do
    [
      probe.env.("ProgramFiles"),
      probe.env.("ProgramW6432"),
      probe.env.("ProgramFiles(x86)"),
      probe.env.("LOCALAPPDATA") && Path.join(probe.env.("LOCALAPPDATA"), "Programs")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&Path.join(&1, "Git"))
  end

  # `bin\bash.exe` first: it is Git's launcher, which puts Git's own tools on
  # PATH for the command; `usr\bin\bash.exe` is the shell itself.
  defp git_bashes(root),
    do: [Path.join([root, "bin", "bash.exe"]), Path.join([root, "usr", "bin", "bash.exe"])]

  # `git --exec-path` prints `<root>/mingw64/libexec/git-core` (or
  # `clangarm64`, `mingw32`): three directories below the installation.
  defp exec_path_bashes(probe) do
    case probe.git_exec_path.() do
      path when is_binary(path) and path != "" ->
        path |> Path.dirname() |> Path.dirname() |> Path.dirname() |> git_bashes()

      _none ->
        []
    end
  end

  defp on_path(probe), do: ["bash", "sh"] |> Enum.map(probe.executable) |> Enum.reject(&is_nil/1)

  defp git_exec_path do
    with git when is_binary(git) <- System.find_executable("git"),
         {output, 0} <- System.cmd(git, ["--exec-path"], stderr_to_stdout: true) do
      String.trim(output)
    else
      _unavailable -> nil
    end
  rescue
    ErlangError -> nil
  end

  @impl Lemieux.Environment
  def read_file(_state, cwd, path) do
    with {:ok, full} <- confined(cwd, path) do
      File.read(full)
    end
  end

  # Opened here, in the caller, so the file belongs to the process that will
  # consume the stream and is closed when that process stops pulling — or
  # dies, since an open file is linked to its opener.
  @impl Lemieux.Environment
  def stream_file(_state, cwd, path) do
    with {:ok, full} <- confined(cwd, path),
         :ok <- regular(full),
         {:ok, device} <- File.open(full, [:read, :binary, :raw]) do
      {:ok, chunks(device)}
    end
  end

  @impl Lemieux.Environment
  def list_dir(_state, cwd, path) do
    with {:ok, full} <- confined(cwd, path),
         {:ok, names} <- File.ls(full) do
      entries =
        names
        |> Enum.map(&directory_entry(full, &1))
        |> Enum.sort_by(& &1.name)

      {:ok, entries}
    end
  end

  @impl Lemieux.Environment
  def write_file(_state, cwd, path, contents) do
    with {:ok, full} <- confined(cwd, path),
         existed? = File.regular?(full),
         :ok <- File.mkdir_p(Path.dirname(full)),
         # Parent creation changes the path graph. Check it again immediately
         # before mutation so a symlinked ancestor introduced concurrently is
         # not trusted on the strength of the earlier lookup.
         {:ok, checked} <- confined(cwd, path),
         :ok <- File.write(checked, contents) do
      {:ok, if(existed?, do: :overwritten, else: :created)}
    end
  end

  # Confined exactly as `write_file/4` is, so a path `write` would refuse is
  # one this refuses to delete, and never the working directory itself or a
  # directory under it: this removes files, the way `rm -f` without `-r`
  # does, and an absent file is already what the caller asked for.
  @impl Lemieux.Environment
  def delete_file(_state, cwd, path) when is_binary(path) do
    # The directory is confined, the last name is not resolved: deleting a
    # symbolic link removes the link. `confined/2` resolves every link on the
    # way, the last one too, so confining the whole path made deleting
    # `link -> README` delete README and leave the link (found in the launch
    # review, 2026-10). A link that points outside the tree is removed the
    # same way; what it points at is never touched.
    with {:ok, directory} <- confined(cwd, Path.dirname(path)),
         full = Path.join(directory, Path.basename(path)),
         :ok <- deletable(full, cwd) do
      absent_is_deleted(File.rm(full))
    end
  end

  def delete_file(_state, _cwd, _path), do: {:error, :invalid_path}

  defp deletable(cwd, cwd), do: {:error, :eisdir}

  defp deletable(full, _cwd) do
    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} -> {:error, :eisdir}
      _file_or_absent -> :ok
    end
  end

  defp absent_is_deleted({:error, :enoent}), do: :ok
  defp absent_is_deleted(result), do: result

  # What the command inherits: this VM's environment as the host corrected it
  # (`Lemieux.Environment.Inherited`: under the installed lmx, the person's
  # `PATH` back and none of the release's own variables), less what the
  # credential policy withholds. A variable the caller sets explicitly is
  # kept even when the policy would withhold it: the caller named it on
  # purpose, which is the one thing a name pattern cannot know.
  @impl Lemieux.Environment
  def run(state, command, opts) do
    explicit = Keyword.get(opts, :env, [])
    named = MapSet.new(explicit, fn {name, _value} -> name end)

    inherited =
      state
      |> credentials()
      |> Inherited.overrides()
      |> Enum.reject(fn {name, _value} -> MapSet.member?(named, name) end)

    env = inherited ++ explicit

    ExCmdRunner.run(
      command,
      opts
      |> Keyword.put(:env, env)
      |> Keyword.put(:max_output_bytes, Keyword.get(opts, :max_output_bytes, @hard_cap))
    )
  end

  @doc """
  Resolves `path` inside `cwd`, or says why it cannot be.

  Public so an environment that wraps this one — a sandbox that runs commands
  differently but keeps the same files — confines paths exactly as `read`,
  `write` and `edit` see them here, rather than reimplementing the rule.
  """
  @spec confined(cwd :: Path.t(), path :: term()) ::
          {:ok, Path.t()} | {:error, :outside_worktree | :invalid_path}
  def confined(cwd, path) when is_binary(path) do
    case Path.safe_relative(relative_inside(path, cwd), cwd) do
      {:ok, relative} -> {:ok, Path.join(cwd, relative)}
      :error -> {:error, :outside_worktree}
    end
  end

  def confined(_cwd, _path), do: {:error, :invalid_path}

  # Lexical on purpose. The symlink-aware judgement stays with
  # `Path.safe_relative/2`, which sees the relative path this produces; all
  # this decides is whether an absolute path *names* somewhere under `cwd`.
  # One that does not is left absolute, and `safe_relative/2` refuses it.
  defp relative_inside(path, cwd) do
    if Path.type(path) == :absolute do
      expanded = Path.expand(path)
      root = Path.expand(cwd)

      cond do
        expanded == root -> "."
        String.starts_with?(expanded, root <> "/") -> Path.relative_to(expanded, root)
        true -> path
      end
    else
      path
    end
  end

  defp regular(full) do
    case File.stat(full) do
      {:ok, %{type: :directory}} -> {:error, :eisdir}
      {:ok, _stat} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunks(device) do
    Stream.resource(
      fn -> device end,
      fn device ->
        case :file.read(device, @chunk_bytes) do
          {:ok, data} -> {[data], device}
          :eof -> {:halt, device}
          {:error, reason} -> raise File.Error, reason: reason, action: "read file"
        end
      end,
      &File.close/1
    )
  end

  defp directory_entry(directory, name) do
    type =
      case File.lstat(Path.join(directory, name)) do
        {:ok, %{type: :regular}} -> :file
        {:ok, %{type: :directory}} -> :directory
        {:ok, %{type: :symlink}} -> :symlink
        {:ok, _stat} -> :other
        {:error, _reason} -> :other
      end

    %{name: name, type: type}
  end
end
