defmodule Lemieux.Environment do
  @moduledoc """
  The boundary between agent tools and the machine they act on.

  The loop never needs to know whether a file lives on the host, in a
  container, or behind a host-owned sandbox runner. It gives tools this
  environment through `t:Lemieux.Tool.context/0`; the bundled tools perform all
  filesystem and command work through the callbacks here.

  This is deliberately smaller than a virtual filesystem. Coding tools need
  three file operations and one streaming command operation, and every extra
  callback is another contract an embedder has to reproduce. The default
  `Lemieux.Environment.Local` uses the launching user's machine while
  confining file tools to the session working directory. A host supplies a
  different `{module, state}` to the session's `:environment` option when the
  real boundary is a container, microVM, remote workspace, or policy service.

  Command streams use semantic events rather than captured output:

    * `{:data, bytes}` as stdout or stderr arrives;
    * `{:exit_status, status}` when the command exits;
    * `{:timeout, timeout_ms}` after the environment kills it;
    * `{:output_limit, bytes}` after the environment stops runaway output;
    * `{:failed, reason}` when the command could not be run to completion —
      the transport broke, not the command.

  The last of those is separate from `{:exit_status, 1}` on purpose. A
  consumer that cannot tell a dead pipe from a command which genuinely
  returned one has no way to say which happened, and the difference decides
  whether the next thing to look at is the command or the machine.

  Keeping the provider call on the host and relocating only these callbacks
  is the useful process boundary: a tool sandbox can have no network and no
  provider credentials without moving the transcript or policy engine into
  it.

  ## Command options

  `run/3` receives `:cwd` and `:timeout_ms` from every caller, and may receive:

    * `:env` — `[{name, value | false}]` applied on top of what the command
      would otherwise inherit, `false` meaning "unset". `Lemieux.Tools.Bash`
      uses it to make commands non-interactive (no pager, no git credential
      prompt), because a command waiting for a person who is not there waits
      out its whole deadline.
    * `:max_output_bytes` — a positive integer or `:infinity`. The local
      environment stops a foreground command after eight megabytes because the
      tool collecting it holds that output in memory; a background task keeps
      only a bounded head and tail, so it passes `:infinity` rather than being
      killed for being chatty.

  An environment that cannot honour an option ignores it rather than failing
  the command; each one is a refinement, not a precondition.

  ## Optional callbacks

    * `list_dir/3` — directory listing for `read` on a directory.
    * `stream_file/3` — a file as a stream of binary chunks, so `read` on a
      multi-gigabyte log keeps only the window it shows. Without it,
      `stream_file/3` below falls back to `read_file/3`.
    * `credentials/1` — the `t:Lemieux.Environment.Credentials.policy/0` the
      environment applies to what it spawns, so the processes a session starts
      *around* the environment (an evaluation node, a hook) can apply the same
      one. Without it the answer is `:inherit`.
  """

  alias Lemieux.Environment.Credentials

  @typedoc "An environment module, or a module paired with host-owned state."
  @type t :: module() | {module(), term()}

  @typedoc "One event from a command as it runs."
  @type command_event ::
          {:data, binary()}
          | {:exit_status, non_neg_integer()}
          | {:timeout, pos_integer()}
          | {:output_limit, pos_integer()}
          | {:failed, reason :: term()}

  @typedoc "One immediate child of a directory, without following symlinks."
  @type directory_entry :: %{
          name: String.t(),
          type: :file | :directory | :symlink | :other
        }

  @callback read_file(state :: term(), cwd :: Path.t(), path :: Path.t()) ::
              {:ok, binary()} | {:error, term()}

  @callback list_dir(state :: term(), cwd :: Path.t(), path :: Path.t()) ::
              {:ok, [directory_entry()]} | {:error, term()}

  @callback write_file(
              state :: term(),
              cwd :: Path.t(),
              path :: Path.t(),
              contents :: iodata()
            ) :: {:ok, :created | :overwritten} | {:error, term()}

  @callback run(
              state :: term(),
              command :: String.t(),
              opts :: keyword()
            ) :: {:ok, Enumerable.t()} | {:error, term()}

  @callback stream_file(state :: term(), cwd :: Path.t(), path :: Path.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback credentials(state :: term()) :: Credentials.policy()

  @callback delete_file(state :: term(), cwd :: Path.t(), path :: Path.t()) ::
              :ok | {:error, term()}

  @optional_callbacks list_dir: 3, stream_file: 3, credentials: 1, delete_file: 3

  @doc """
  The module behind an environment, for records: `{module, state}` names the
  module and a bare module names itself. The state is never included; it is
  where a container handle or a remote workspace's credentials would live.
  """
  @spec name(environment :: t()) :: String.t()
  def name({module, _state}) when is_atom(module), do: inspect(module)
  def name(module) when is_atom(module), do: inspect(module)

  @doc """
  The launching user's machine, with file tools confined to the working directory.

  What `Lemieux.Session` uses when a host supplies no `:environment`. Pass it
  explicitly everywhere else — a tool context built by hand, a
  `Lemieux.Background.start/1` — because nothing below the session falls back
  to it (see `from_context/1`).
  """
  @spec local() :: t()
  def local, do: Lemieux.Environment.Local

  @doc "Reads a path through `environment`."
  @spec read_file(t(), Path.t(), Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_file(environment, cwd, path), do: call(environment, :read_file, [cwd, path])

  @doc "Lists a directory through `environment` when it supports directory discovery."
  @spec list_dir(t(), Path.t(), Path.t()) ::
          {:ok, [directory_entry()]} | {:error, :unsupported | term()}
  def list_dir(environment, cwd, path), do: optional_call(environment, :list_dir, [cwd, path])

  @doc "Writes a path through `environment`."
  @spec write_file(t(), Path.t(), Path.t(), iodata()) ::
          {:ok, :created | :overwritten} | {:error, term()}
  def write_file(environment, cwd, path, contents),
    do: call(environment, :write_file, [cwd, path, contents])

  @doc """
  Deletes the file at `path`, relative to `cwd`, through `environment`.

  Answers `{:error, :unsupported}` for an environment without
  `c:delete_file/3`; `Lemieux.Tools.FileOps` then deletes through the
  environment's own command runner instead. A file that is already absent is
  not an error, the way `rm -f` treats it: undoing a turn and applying a patch
  both ask for "not there afterwards", which an absent file already is.
  """
  @spec delete_file(environment :: t(), cwd :: Path.t(), path :: Path.t()) ::
          :ok | {:error, :unsupported | term()}
  def delete_file(environment, cwd, path),
    do: optional_call(environment, :delete_file, [cwd, path])

  @doc "Starts a command stream through `environment`."
  @spec run(t(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}
  def run(environment, command, opts), do: call(environment, :run, [command, opts])

  @doc """
  Reads a path through `environment` as a stream of binary chunks.

  An environment without `c:stream_file/3` answers through `read_file/3`, as a
  one-chunk stream: the caller keeps working, it only loses the memory bound.
  Errors are returned before any chunk is produced, exactly as `read_file/3`
  returns them — `:enoent`, `:eisdir`, `:outside_worktree`.
  """
  @spec stream_file(t(), Path.t(), Path.t()) :: {:ok, Enumerable.t()} | {:error, term()}
  def stream_file(environment, cwd, path) do
    case optional_call(environment, :stream_file, [cwd, path]) do
      {:error, :unsupported} ->
        with {:ok, contents} <- read_file(environment, cwd, path), do: {:ok, [contents]}

      other ->
        other
    end
  end

  @doc """
  The credential policy `environment` applies to the commands it runs.

  `:inherit` for an environment that does not say — a container or a remote
  runner whose processes never see this VM's environment in the first place.
  A caller that spawns a process of its own beside the environment (the
  Elixir evaluation node, a command hook) applies the same policy through
  `Lemieux.Environment.Credentials.overrides/2`.
  """
  @spec credentials(t()) :: Credentials.policy()
  def credentials(environment) do
    case optional_call(environment, :credentials, []) do
      {:error, :unsupported} -> :inherit
      policy -> policy
    end
  end

  @doc """
  The environment a tool context carries.

  There is no fallback. This used to answer `local/0` when the key was absent,
  which made a host that forgot to thread the session's environment into a
  context — or a test that built one by hand — indistinguishable from one
  that chose unconfined execution on its own machine, and nothing said so. A
  session always sets the key; a context built anywhere else must set it too,
  to `local/0` when that is what is meant.
  """
  @spec from_context(context :: map()) :: t()
  def from_context(%{environment: environment}), do: environment

  def from_context(context) when is_map(context) do
    raise ArgumentError,
          "the tool context has no :environment. Pass `environment: Lemieux.Environment.local()` " <>
            "for the launching machine, or a `{module, state}` implementing Lemieux.Environment; " <>
            "a session sets it from its :environment option. " <>
            "Context keys: #{inspect(Map.keys(context))}"
  end

  defp call({module, state}, function, args) when is_atom(module),
    do: apply(module, function, [state | args])

  defp call(module, function, args) when is_atom(module),
    do: apply(module, function, [nil | args])

  defp optional_call({module, state}, function, args) when is_atom(module) do
    if exported?(module, function, length(args) + 1),
      do: apply(module, function, [state | args]),
      else: {:error, :unsupported}
  end

  defp optional_call(module, function, args) when is_atom(module) do
    if exported?(module, function, length(args) + 1),
      do: apply(module, function, [nil | args]),
      else: {:error, :unsupported}
  end

  # `function_exported?/3` answers about a *loaded* module, and code loading is lazy
  # outside a release built in embedded mode. Without the ensure, the first call in
  # a fresh VM reports that the environment cannot list directories at all — and the
  # caller believes it, because that is what an environment which genuinely cannot
  # would say. It showed up as `read` refusing to list a directory once, then
  # listing it happily on the retry.
  defp exported?(module, function, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)
end
