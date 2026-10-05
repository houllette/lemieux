defmodule Lemieux.MCP.Transport.Stdio do
  @moduledoc """
  An MCP server run as a child process, spoken to over its pipes.

  The common case: a server distributed as a command, started per client,
  exchanging newline-delimited JSON on stdin and stdout.

  ## Framing

  Messages are separated by newlines, and a message may arrive in any number
  of chunks — a port hands over whatever the OS had ready, which is not the
  same as whatever the server wrote. So bytes are accumulated and split on
  newlines, and a partial line is kept for the next chunk. Reading a fixed
  amount, or assuming one chunk is one message, works until a server returns
  a large tool result and then fails in a way that looks like corruption.

  Anything that is not JSON is skipped rather than fatal. Servers print
  warnings and startup banners to stdout despite the specification asking them
  not to, and one stray line should not take down a session that is otherwise
  working.

  ## Two ways to wait for a reply

  During the handshake the client is the only thing talking to the server, and
  `call/3` blocks until the reply for its id arrives, taking port messages out
  of the mailbox as they come.

  After it, this transport is **duplex** (see `Lemieux.MCP.Transport`): the
  client writes with `notify/2` and hands every port message to
  `handle_message/2`, which decodes whatever complete lines have arrived. That
  is what lets several calls be in flight on one pipe, lets an abandoned call be
  cancelled rather than waited out, and lets the server's own notifications —
  progress, a changed tool list — be heard at all; the selective receive dropped
  them as replies to nobody.

  ## The environment a server inherits

  A server runs with the environment of the VM that started it, less what the
  `:credentials` policy withholds (`Lemieux.Environment.Credentials`): a
  scrubbing policy unsets every credential-shaped variable the configuration did
  not name in its own `"env"`. A server written as

      "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}

  still gets its token, because somebody wrote down that it should; it no longer
  gets `OPENAI_API_KEY` as well because it happened to be exported. The library
  default inherits everything, and `lmx` scrubs.

  ## Host-owned launch

  The default launcher opens a local Port and leaves stderr attached to
  lemieux's own. An embedding host passes `:mcp_stdio_launcher` to the session
  to own the process boundary instead. The launcher receives the unmodified
  command, arguments, expanded environment map and effective working directory,
  and returns `{:ok, port}` or `{:ok, %{port: port, close: close_fun}}`. The
  second form lets a host couple Port closure to container or microVM teardown
  and termination escalation. That callback is also where it applies its
  environment allowlist, mounts, network policy and bounded diagnostics — the
  `:credentials` policy applies only to the default launcher, because a host
  that owns the launch owns what the process inherits. It is executable
  authority, so it is never written to or restored from the transcript.
  """

  @behaviour Lemieux.MCP.Transport

  require Logger

  alias Lemieux.Environment.Credentials
  alias Lemieux.Environment.Inherited
  alias Lemieux.MCP

  @typedoc "A Port with optional host-owned lifecycle teardown."
  @type process :: port() | %{required(:port) => port(), optional(:close) => (-> term())}

  @typedoc "A host-owned stdio process launcher."
  @type launcher ::
          (command :: String.t(), args :: [String.t()], env :: map(), cwd :: Path.t() ->
             {:ok, process()} | {:error, term()})

  # `args` and `env` are expanded; `command` and `cwd` are not. A token belongs
  # in an argument or the environment, and a command whose path depends on a
  # variable is better written out than resolved at connect time.
  #
  # The session's directory is also `CLAUDE_PROJECT_DIR` unless the
  # configuration sets it: Claude Code exports it to every stdio server, and a
  # server written for Claude Code — imported with `lmx mcp import`, or
  # declared by a plugin — finds its project files through it.
  @impl Lemieux.MCP.Transport
  def configure(%{"command" => command} = config, opts) do
    expansion = MCP.expansion(config, opts)

    with {:ok, args} <- MCP.expand(Map.get(config, "args", []), expansion),
         {:ok, env} <- MCP.expand(Map.get(config, "env", %{}), expansion),
         {:ok, credentials} <- Credentials.policy(Keyword.get(opts, :credentials, :inherit)) do
      {:ok,
       %{
         command: command,
         args: args,
         env: project_dir(env, Keyword.get(opts, :cwd)),
         cwd: Map.get(config, "cwd") || Keyword.get(opts, :cwd),
         launcher: Keyword.get(opts, :stdio_launcher),
         credentials: credentials
       }}
    end
  end

  def configure(_config, _opts), do: {:error, "a stdio MCP server needs a command"}

  defp project_dir(env, cwd) when is_binary(cwd), do: Map.put_new(env, "CLAUDE_PROJECT_DIR", cwd)
  defp project_dir(env, _cwd), do: env

  defp private_directory(path) do
    if not File.dir?(path) and File.mkdir_p(path) == :ok, do: File.chmod(path, 0o700)
    :ok
  end

  @impl Lemieux.MCP.Transport
  def connect(config) do
    command = Map.fetch!(config, :command)
    args = Map.get(config, :args, [])
    environment = Map.get(config, :env, %{})
    cwd = Map.get(config, :cwd) || File.cwd!()
    credentials = Map.get(config, :credentials, :inherit)

    launcher =
      Map.get(config, :launcher) ||
        fn command, args, env, cwd -> launch_local(command, args, env, cwd, credentials) end

    with {:ok, process} <- invoke_launcher(launcher, command, args, environment, cwd),
         {:ok, port, close} <- process(process) do
      {:ok, %{port: port, close: close, buffer: "", command: command}}
    else
      {:error, reason} -> {:error, reason}
      invalid -> {:error, "the stdio launcher returned #{inspect(invalid)}"}
    end
  end

  @impl Lemieux.MCP.Transport
  def mode(_state), do: :duplex

  @impl Lemieux.MCP.Transport
  def handle_message(%{port: port} = state, {port, {:data, data}}) do
    {messages, state} = take_all(%{state | buffer: state.buffer <> data}, [])
    {:ok, messages, state}
  end

  def handle_message(%{port: port} = state, {port, {:exit_status, status}}),
    do: {:closed, "the MCP server #{state.command} exited with status #{status}", state}

  def handle_message(%{port: port} = state, {:EXIT, port, reason}),
    do: {:closed, "the MCP server #{state.command} stopped: #{inspect(reason)}", state}

  def handle_message(_state, _message), do: :unknown

  defp take_all(state, acc) do
    case take_message(state) do
      {:ok, message, state} -> take_all(state, [message | acc])
      {:none, state} -> {Enum.reverse(acc), state}
    end
  end

  defp process(port) when is_port(port), do: {:ok, port, fn -> close_port(port) end}

  defp process(%{port: port, close: close}) when is_port(port) and is_function(close, 0),
    do: {:ok, port, close}

  defp process(%{port: port}) when is_port(port), do: process(port)

  defp process(invalid),
    do: {:error, "the stdio launcher returned #{inspect(invalid)}, not a port-like process"}

  defp invoke_launcher(launcher, command, args, environment, cwd) do
    launcher.(command, args, environment, cwd)
  rescue
    error -> {:error, "the stdio launcher failed: #{Exception.message(error)}"}
  catch
    kind, reason -> {:error, "the stdio launcher failed: #{inspect({kind, reason})}"}
  end

  # A plugin's server is told its persistent data directory
  # (`Lemieux.Extensions.Workspace.Plugin`), which Claude Code creates when a
  # component first uses it — owner-only, as a plugin keeps tokens there;
  # one that cannot be made is the server's to report when it tries to
  # write there.
  defp launch_local(command, args, environment, cwd, credentials) do
    case Map.get(environment, "CLAUDE_PLUGIN_DATA") do
      data when is_binary(data) and data != "" -> private_directory(data)
      _none -> :ok
    end

    with {:ok, executable} <- executable(command) do
      {:ok,
       Port.open({:spawn_executable, executable}, [
         :binary,
         :exit_status,
         :hide,
         args: args,
         env: port_env(environment, credentials),
         cd: cwd
       ])}
    end
  end

  # On the PATH the server will see (`Lemieux.Environment.Inherited`), not
  # this VM's: under the installed lmx that one starts with the release's
  # own ERTS, and a server started as `erl` there could not boot.
  defp executable(command) do
    case Inherited.find_executable(command) do
      nil -> {:error, "there is no #{command} on this machine"}
      path -> {:ok, path}
    end
  end

  @doc false
  # The environment handed to `Port.open/2`: what the configuration set, and,
  # for every inherited variable the configuration did not name, the host's
  # correction (`Lemieux.Environment.Inherited`: the person's own `PATH`
  # under the installed lmx) or an unset where the policy withholds it.
  # Public for the test that proves the shape without spawning a server per
  # case.
  @spec port_env(env :: map(), credentials :: Credentials.policy()) ::
          [{charlist(), charlist() | false}]
  def port_env(env, credentials) do
    set = Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end)

    inherited =
      for {name, value} <- Inherited.overrides(credentials, System.get_env()),
          not Map.has_key?(env, name),
          do: {to_charlist(name), value && to_charlist(value)}

    set ++ inherited
  end

  @impl Lemieux.MCP.Transport
  def call(state, request, timeout) do
    with {:ok, state} <- write(state, request) do
      await(state, request["id"], deadline(timeout))
    end
  end

  @impl Lemieux.MCP.Transport
  def notify(state, notification), do: write(state, notification)

  defp write(state, message) do
    Port.command(state.port, JSON.encode!(message) <> "\n")

    {:ok, state}
  rescue
    ArgumentError -> {:error, "the MCP server #{state.command} is no longer running", state}
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp await(state, id, deadline) do
    case take_message(state) do
      {:ok, message, state} -> match(state, message, id, deadline)
      {:none, state} -> read_more(state, id, deadline)
    end
  end

  # A reply for a different id: a notification the server sent unprompted, or
  # a late answer to something that already timed out. Dropped, and the wait
  # goes on for the id that was asked for.
  defp match(state, %{"id" => id} = message, id, _deadline), do: {:ok, message, state}
  defp match(state, _message, id, deadline), do: await(state, id, deadline)

  defp read_more(state, id, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, "the MCP server #{state.command} did not answer in time", state}
    else
      receive_chunk(state, id, deadline, remaining)
    end
  end

  defp receive_chunk(state, id, deadline, remaining) do
    port = state.port

    receive do
      {^port, {:data, data}} ->
        await(%{state | buffer: state.buffer <> data}, id, deadline)

      {^port, {:exit_status, status}} ->
        {:error, "the MCP server #{state.command} exited with status #{status}", state}

      {:EXIT, ^port, reason} ->
        {:error, "the MCP server #{state.command} stopped: #{inspect(reason)}", state}
    after
      remaining ->
        {:error, "the MCP server #{state.command} did not answer in time", state}
    end
  end

  # Takes one decodable message out of the buffer, skipping anything that is
  # not JSON.
  defp take_message(state) do
    case String.split(state.buffer, "\n", parts: 2) do
      [_partial] ->
        {:none, state}

      [line, rest] ->
        state = %{state | buffer: rest}

        case decode(line) do
          {:ok, message} -> {:ok, message, state}
          :error -> take_message(state)
        end
    end
  end

  defp decode(line) do
    case line |> String.trim() |> JSON.decode() do
      {:ok, message} when is_map(message) ->
        {:ok, message}

      _otherwise ->
        unless String.trim(line) == "",
          do: Logger.debug("lemieux: ignoring non-JSON line from an MCP server: #{inspect(line)}")

        :error
    end
  end

  # `x-mcp-header` annotations say which HTTP headers a parameter should be
  # mirrored into, and there are no headers here. The specification lets
  # clients on other transports ignore them, so a tool annotated for HTTP is
  # perfectly usable over a pipe.
  @impl Lemieux.MCP.Transport
  def prepare_tools(state, tools), do: {tools, state}

  @impl Lemieux.MCP.Transport
  def close(state) do
    state.close.()

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  end
end
