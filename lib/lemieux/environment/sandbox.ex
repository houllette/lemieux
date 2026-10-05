defmodule Lemieux.Environment.Sandbox do
  @moduledoc """
  An environment whose commands run inside an operating-system sandbox.

  Files go through the wrapped environment — by default
  `Lemieux.Environment.Local`, so `read`, `write` and `edit` keep the
  confinement they already had — with one addition: a path the sandbox hides
  is refused there too (`:eacces`, which the file tools report as
  "permission denied"). Without it a hidden file inside the working
  directory — `lmx --config ./lmx.json`, its saved key with it — was out of
  `cat`'s reach and in `read`'s (2026-10, found in review). What changes
  most is `run/3`: every command the model starts (`bash`, a background
  task) is launched through the platform's sandbox, which the operating
  system enforces on the command and on everything it starts.

    * **macOS** — `sandbox-exec` with a generated Seatbelt profile
      (`Lemieux.Environment.Sandbox.Seatbelt`).
    * **Linux** — `bwrap` (bubblewrap) with the root filesystem read-only
      (`Lemieux.Environment.Sandbox.Bubblewrap`).

  Both enforce the same policy:

    * **Writes** are allowed only under the session's working directory, the
      temporary directories, the common tool caches (`~/.cache`,
      `~/Library/Caches`, `~/.npm`, `~/.hex`, `~/.mix`, `~/.cargo/registry`,
      …) and whatever `:writable` adds. A build that writes `_build/` works; a
      command that edits `~/.bashrc` fails with "Operation not permitted".
    * **Network** is off by default, apart from loopback. Test suites talk to
      a database on `localhost` far more often than an agent needs the
      internet, and loopback is not an exfiltration path. `network: true`
      turns the internet on; `localhost: false` turns loopback off too.
    * **Credential locations** are unreadable and unwritable, by commands
      and file tools alike: `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`,
      `~/.git-credentials` and `~/.config/git/credentials` (git's credential
      store, in either place), `~/.pypirc`, `~/.config/gh`,
      `~/.config/gcloud`, `~/.azure`, `~/.docker`, `~/.kube`,
      `~/.codex/auth.json`, `~/.claude/.credentials.json`, `~/.lmx` and
      `~/.lemieux` (where `Lemieux.MCP.Auth.Store.File` keeps OAuth tokens by
      default), plus whatever `:hidden` adds — `lmx` adds the config file,
      state, transcript and token locations its options resolved, wherever
      they point (`Lemieux.CLI.Runtime.SecretPaths`). The list is exactly
      that, not every credential a machine can hold: `~/.hex/hex.config` and
      `~/.npmrc` stay readable, because `mix deps.get` and `npm install`
      read them. Everything else stays readable too, because a coding agent
      that cannot read the compiler it runs is not one.

  ## What it is not

  It bounds what a command can *write* and *reach*. It is not a
  confidentiality boundary for the rest of the disk, and it does not cover
  what runs beside the environment rather than through it: the Elixir
  evaluation node, MCP stdio servers, command hooks and the web tools run in
  or from this VM, outside the sandbox. `Lemieux.Extensions.Permissions`
  knows the difference — its `:auto` mode lets only commands and file edits
  run unasked in a sandbox, never those.

  Missing tools are an error at construction, not a quiet fallback to an
  unsandboxed shell: a session somebody asked to sandbox and that ran
  unconfined would be the worst answer.

      {:ok, environment} = Lemieux.Environment.Sandbox.new()
      Lemieux.start_session(environment: environment, ...)
  """

  @behaviour Lemieux.Environment

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox.Bubblewrap
  alias Lemieux.Environment.Sandbox.Seatbelt

  @typedoc "Which sandbox a platform provides."
  @type backend :: :seatbelt | :bubblewrap

  @typedoc "The sandbox's policy, resolved once at construction."
  @type t :: %__MODULE__{
          backend: backend(),
          executable: Path.t(),
          inner: Environment.t(),
          network: boolean(),
          localhost: boolean(),
          writable: [Path.t()],
          hidden: [Path.t()],
          shell: Path.t()
        }

  @enforce_keys [:backend, :executable, :inner, :shell]
  defstruct [
    :backend,
    :executable,
    :inner,
    :shell,
    network: false,
    localhost: true,
    writable: [],
    hidden: []
  ]

  # Tool caches under $HOME that ordinary builds write to. Only the ones that
  # exist are passed on; bubblewrap refuses to bind a path that is not there.
  @caches ~w(.cache Library/Caches .npm .yarn .pnpm-store .hex .mix .cargo/registry .cargo/git
             go/pkg/mod .gradle .m2 .bun .deno .nuget)

  # Where credentials live. Hidden rather than merely unwritable, because
  # reading them is the whole attack: a key read into the conversation is sent
  # to the model provider with the next request. `.lemieux` is the library's
  # own default token store (`Lemieux.MCP.Auth.Store.File.default_path/0`):
  # leaving it out let `cat ~/.lemieux/credentials.json` print every MCP
  # OAuth token from inside a sandbox that hid `~/.lmx`.
  #
  # Files as well as directories. gcloud and the Azure CLI keep tokens
  # throughout their directories, which go whole; git's credential store is
  # one file — `~/.git-credentials`, or `~/.config/git/credentials` beside
  # git's own `config` and `ignore`, which commands need — and so are the
  # sign-ins Codex and Claude Code keep beside their settings, skills and
  # instructions: hiding `~/.codex` or `~/.claude` whole would take those
  # from every command too. `~/.pypirc` holds the token `twine upload`
  # publishes with; installing reads `pip.conf`, never it.
  #
  # Not `~/.hex/hex.config` or `~/.npmrc`, though each can hold a token:
  # `mix deps.get` and `npm install` read them, and a sandbox that hid them
  # would fail the build the agent was asked to run. The workspace's
  # containment list (`Lemieux.Extensions.Workspace.Containment`) has
  # `.npmrc` too because it guards only what is read into a prompt, which no
  # build needs.
  @hidden ~w(.ssh .aws .gnupg .netrc .git-credentials .config/git/credentials .pypirc
             .config/gh .config/gcloud .azure .docker .kube .codex/auth.json
             .claude/.credentials.json .lmx .lemieux)

  @doc """
  Builds a sandboxed environment, or says why this machine cannot.

  Options:

    * `:backend` — `:auto` (default), `:seatbelt` or `:bubblewrap`.
    * `:network` — allow outbound network (default `false`).
    * `:localhost` — allow loopback when network is off (default `true`).
    * `:writable` — extra paths commands may write to.
    * `:hidden` — extra paths commands may not read; replaces nothing, adds.
    * `:inner` — the environment files and commands go through (default
      `Lemieux.Environment.Local`). Pass `Lemieux.Environment.Local.new/1`'s
      result to keep a credential policy.
    * `:probe` — run a trivial command through the sandbox first (default
      `true`), so a machine where bubblewrap is installed but user namespaces
      are forbidden fails here, with the reason, rather than on the model's
      first command.
  """
  @spec new(opts :: keyword()) :: {:ok, {module(), t()}} | {:error, String.t()}
  def new(opts \\ []) when is_list(opts) do
    with {:ok, backend, executable} <- available(Keyword.get(opts, :backend, :auto)) do
      sandbox = %__MODULE__{
        backend: backend,
        executable: executable,
        inner: Keyword.get(opts, :inner, Local),
        shell: sandbox_shell(),
        network: Keyword.get(opts, :network, false) == true,
        localhost: Keyword.get(opts, :localhost, true) != false,
        writable: existing(Keyword.get(opts, :writable, []) ++ default_writable()),
        hidden: existing(Keyword.get(opts, :hidden, []) ++ default_hidden())
      }

      if Keyword.get(opts, :probe, true), do: probe(sandbox), else: {:ok, {__MODULE__, sandbox}}
    end
  end

  # The shell inside the sandbox is the one commands run under anywhere else
  # (`Lemieux.Environment.Local.find_bash/0`); `/bin/sh` is only the last
  # resort on the two platforms a sandbox exists for, where it always exists.
  defp sandbox_shell do
    case Local.find_bash() do
      {:ok, path} -> path
      :error -> "/bin/sh"
    end
  end

  @doc """
  The sandbox this machine provides, or why there is none.

  `:auto` picks by operating system. Naming a backend checks for that one.
  """
  @spec available(backend :: :auto | backend()) ::
          {:ok, backend(), Path.t()} | {:error, String.t()}
  def available(:auto) do
    case :os.type() do
      {:unix, :darwin} -> available(:seatbelt)
      {:unix, :linux} -> available(:bubblewrap)
      _other -> {:error, "no command sandbox is available on this platform"}
    end
  end

  def available(:seatbelt) do
    case System.find_executable("sandbox-exec") do
      nil ->
        {:error, "sandbox-exec is not available on this system, so commands cannot be sandboxed"}

      executable ->
        {:ok, :seatbelt, executable}
    end
  end

  def available(:bubblewrap) do
    case System.find_executable("bwrap") do
      nil ->
        {:error,
         "bubblewrap (bwrap) is not installed, so commands cannot be sandboxed; " <>
           "install it (for example `apt install bubblewrap`) or turn the sandbox off"}

      executable ->
        {:ok, :bubblewrap, executable}
    end
  end

  def available(other), do: {:error, "unknown sandbox backend #{inspect(other)}"}

  @doc """
  Whether `environment` runs its commands in a sandbox.

  True for this module, and for any environment module that says so by
  exporting `sandboxed?/1`. What `Lemieux.Extensions.Permissions` asks before
  letting `:auto` mode run a command unasked.
  """
  @spec sandboxed?(environment :: Environment.t() | nil) :: boolean()
  def sandboxed?({__MODULE__, %__MODULE__{}}), do: true

  def sandboxed?({module, state}) when is_atom(module),
    do: exports?(module, :sandboxed?, 1) and module.sandboxed?(state) == true

  def sandboxed?(module) when is_atom(module) and not is_nil(module),
    do: exports?(module, :sandboxed?, 1) and module.sandboxed?(nil) == true

  def sandboxed?(_environment), do: false

  defp exports?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  @doc """
  JSON-shaped facts about a sandboxed environment, for a status line or a
  diagnostic; `nil` for one that is not.
  """
  @spec describe(environment :: Environment.t() | nil) :: map() | nil
  def describe({__MODULE__, %__MODULE__{} = sandbox}) do
    %{
      "backend" => Atom.to_string(sandbox.backend),
      "network" => sandbox.network,
      "localhost" => sandbox.localhost,
      "writable" => sandbox.writable,
      "hidden" => sandbox.hidden
    }
  end

  def describe(_environment), do: nil

  @doc """
  The shell command that runs `command` inside the sandbox from `cwd`.

  Public so the construction can be tested on a machine without the sandbox
  tool; `run/3` is the only caller that executes it.
  """
  @spec wrap(sandbox :: t(), command :: String.t(), cwd :: Path.t()) :: String.t()
  def wrap(%__MODULE__{backend: :seatbelt} = sandbox, command, cwd),
    do: Seatbelt.wrap(sandbox, command, cwd)

  def wrap(%__MODULE__{backend: :bubblewrap} = sandbox, command, cwd),
    do: Bubblewrap.wrap(sandbox, command, cwd)

  @impl Environment
  def run(%__MODULE__{} = sandbox, command, opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    Environment.run(sandbox.inner, wrap(sandbox, command, cwd), opts)
  end

  @impl Environment
  def read_file(%__MODULE__{inner: inner} = sandbox, cwd, path) do
    with :ok <- visible(sandbox, cwd, path), do: Environment.read_file(inner, cwd, path)
  end

  @impl Environment
  def stream_file(%__MODULE__{inner: inner} = sandbox, cwd, path) do
    with :ok <- visible(sandbox, cwd, path), do: Environment.stream_file(inner, cwd, path)
  end

  @impl Environment
  def list_dir(%__MODULE__{inner: inner} = sandbox, cwd, path) do
    with :ok <- visible(sandbox, cwd, path), do: Environment.list_dir(inner, cwd, path)
  end

  @impl Environment
  def write_file(%__MODULE__{inner: inner} = sandbox, cwd, path, contents) do
    with :ok <- visible(sandbox, cwd, path),
         do: Environment.write_file(inner, cwd, path, contents)
  end

  @impl Environment
  def credentials(%__MODULE__{inner: inner}), do: Environment.credentials(inner)

  @impl Environment
  def delete_file(%__MODULE__{inner: inner} = sandbox, cwd, path) do
    with :ok <- visible(sandbox, cwd, path), do: Environment.delete_file(inner, cwd, path)
  end

  # The file tools' half of "hidden" (see the moduledoc). Judged on the real
  # path, as the kernel judges a command's open, so a link in the working
  # directory to a hidden file is the hidden file. Relative paths are taken
  # from `cwd` as `Lemieux.Environment.Local` takes them — a leading `~` is a
  # directory name there, not the home directory. A directory around a
  # hidden path stays listable, names included, as it is to `ls`.
  defp visible(%__MODULE__{hidden: []}, _cwd, _path), do: :ok

  defp visible(%__MODULE__{hidden: hidden}, cwd, path) when is_binary(cwd) and is_binary(path) do
    target = real(if Path.type(path) == :absolute, do: path, else: Path.join(cwd, path))
    if Enum.any?(hidden, &within?(target, &1)), do: {:error, :eacces}, else: :ok
  end

  # Not a path the inner environment will accept either; it says why.
  defp visible(_sandbox, _cwd, _path), do: :ok

  @doc false
  # Whether `path` is `directory` or lies under it, both real paths. The
  # root is a prefix of everything; `"/" <> "/"` would be a prefix of nothing.
  @spec within?(path :: Path.t(), directory :: Path.t()) :: boolean()
  def within?(path, directory) when is_binary(path) and is_binary(directory),
    do:
      path == directory or String.starts_with?(path, String.trim_trailing(directory, "/") <> "/")

  @doc false
  @spec quote_shell(value :: String.t()) :: String.t()
  def quote_shell(value) when is_binary(value),
    do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc false
  # The real path, because both sandboxes match the path the kernel sees:
  # `/tmp` is `/private/tmp` on macOS, and a profile naming the former allows
  # nothing.
  @spec real(path :: Path.t()) :: Path.t()
  def real(path), do: path |> Path.expand() |> Path.split() |> resolve("/", 0)

  # Component by component: a symlink anywhere on the path is replaced by its
  # target, which is then resolved from the root again. The depth bound stops
  # a symlink loop; past it the path is returned as far as it got.
  defp resolve([], resolved, _depth), do: resolved
  defp resolve(["/" | rest], _resolved, depth), do: resolve(rest, "/", depth)

  defp resolve([part | rest], resolved, depth) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} when depth < 32 ->
        target
        |> Path.expand(resolved)
        |> Path.split()
        |> Kernel.++(rest)
        |> resolve("/", depth + 1)

      _not_a_link ->
        resolve(rest, candidate, depth)
    end
  end

  defp default_writable do
    home = System.user_home()
    temporary = [System.tmp_dir(), "/tmp", "/var/tmp", "/private/tmp"]
    darwin_user = darwin_user_directory()
    caches = if home, do: Enum.map(@caches, &Path.join(home, &1)), else: []

    Enum.reject(temporary ++ darwin_user ++ caches, &is_nil/1)
  end

  # On macOS a user's temporary and cache directories share a parent under
  # /var/folders (`…/T` and `…/C`); tools use both, so the parent is the root.
  defp darwin_user_directory do
    case {:os.type(), System.tmp_dir()} do
      {{:unix, :darwin}, temporary} when is_binary(temporary) ->
        real = real(temporary)
        if String.starts_with?(real, "/private/var/folders/"), do: [Path.dirname(real)], else: []

      _other ->
        []
    end
  end

  @doc """
  The credential locations every sandbox hides, under `home` — by default the
  user's home directory; none without one. Only those that exist when a
  sandbox is built are passed on, so this is the list before that filter.
  """
  @spec default_hidden(home :: Path.t() | nil) :: [Path.t()]
  def default_hidden(home \\ System.user_home())
  def default_hidden(nil), do: []
  def default_hidden(home) when is_binary(home), do: Enum.map(@hidden, &Path.join(home, &1))

  defp existing(paths) do
    paths
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(&File.exists?/1)
    |> Enum.map(&real/1)
    |> Enum.uniq()
  end

  defp probe(sandbox) do
    cwd = File.cwd!()
    script = wrap(sandbox, "true", cwd)

    case System.cmd(sandbox.shell, ["-c", script], cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok, {__MODULE__, sandbox}}

      {output, status} ->
        {:error,
         "#{sandbox.backend} is installed but could not start a sandbox (exit #{status}): " <>
           String.trim(output) <> probe_hint(sandbox.backend)}
    end
  end

  defp probe_hint(:bubblewrap),
    do:
      ". On some distributions (Ubuntu 24.04 and later) unprivileged user namespaces " <>
        "are restricted by AppArmor, which bubblewrap needs."

  defp probe_hint(_backend), do: ""
end
