defmodule Lemieux.Clipboard do
  @moduledoc """
  Copies text to the clipboard of the machine a person is sitting at.

  For the local TUI that is usually this machine, and its own clipboard tool
  is the reliable way in: `pbcopy` on macOS, `wl-copy` under Wayland, `xclip`
  or `xsel` under X11. OSC 52 — asking the terminal to set the clipboard —
  is the fallback, and the only answer over SSH, where this machine's
  clipboard is not the person's. It is best-effort: tmux ignores it by
  default, terminals may disable it as a security policy, and nothing
  acknowledges it, so a copy that silently did nothing looked the same as
  one that worked. That is why the native tool comes first.

  A byte-stream transport supplies its own writer and gets OSC 52 through
  it. Cell and distributed transports need a host-specific clipboard intent
  and are reported as unsupported rather than writing to the wrong machine.
  """

  alias Lemieux.Environment.Local

  @type transport :: :local | {:session, term(), (iodata() -> :ok)} | term()

  @doc """
  Copies `text` to the clipboard owned by the given terminal transport.

  For `:local`, `opts` may replace what is detected — `:os`, `:env` — and
  `:native`, the call that runs a clipboard tool, which is how a test reaches
  each branch without touching the real clipboard.
  """
  @spec copy(text :: String.t(), transport(), opts :: keyword()) :: :ok | {:error, term()}
  def copy(text, transport, opts \\ [])

  def copy(text, :local, opts) when is_binary(text) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    os = Keyword.get_lazy(opts, :os, &:os.type/0)
    native = Keyword.get(opts, :native, &native_copy/2)

    with {:ok, tool} <- native_tool(os, env),
         :ok <- native.(tool, text) do
      :ok
    else
      _no_native_copy -> emit(fn bytes -> IO.binwrite(:stdio, bytes) end, text)
    end
  end

  def copy(text, {:session, _session, writer}, _opts)
      when is_binary(text) and is_function(writer, 1),
      do: emit(writer, text)

  def copy(text, _transport, _opts) when is_binary(text), do: {:error, :unsupported_transport}

  @doc """
  The clipboard tool this machine would copy with, as `{executable, args}`,
  or `:none` when OSC 52 is the only way.

  Over SSH the answer is always `:none`: the tool would fill the clipboard of
  the machine being logged into, which is not the one being looked at.
  """
  @spec native_tool(os :: {atom(), atom()}, env :: %{optional(String.t()) => String.t()}) ::
          {:ok, {String.t(), [String.t()]}} | :none
  def native_tool(os, env) do
    cond do
      present?(env, "SSH_CONNECTION") or present?(env, "SSH_TTY") -> :none
      os == {:unix, :darwin} -> found("pbcopy", [])
      match?({:unix, _name}, os) -> unix_tool(env)
      true -> :none
    end
  end

  defp unix_tool(env) do
    cond do
      present?(env, "WAYLAND_DISPLAY") and found("wl-copy", []) != :none ->
        found("wl-copy", [])

      present?(env, "DISPLAY") and found("xclip", []) != :none ->
        found("xclip", ["-selection", "clipboard"])

      present?(env, "DISPLAY") ->
        found("xsel", ["--clipboard", "--input"])

      true ->
        :none
    end
  end

  defp found(executable, args) do
    case System.find_executable(executable) do
      nil -> :none
      path -> {:ok, {path, args}}
    end
  end

  defp native_copy(tool, text), do: native_copy(tool, text, &Local.find_bash/0)

  @doc false
  # Runs a clipboard tool with `text` on its standard input, through the
  # shell `shell` finds — `Lemieux.Environment.Local.find_bash/0`, the one
  # commands run under — so a test can take the shell away.
  #
  # Through a file rather than an argument or the environment: a selection
  # can be longer than either allows. The file is made inside a directory of
  # the copy's own, narrowed to `0700` before the selection is written: the
  # file itself was written first and narrowed after, so for that moment,
  # under the usual umask, anyone on the machine could read what was copied
  # — a key, a token — from the shared temporary directory. `mkdir` fails on
  # anything already at the name, and the name is random, so the directory
  # is never one somebody else planted. Output goes to /dev/null because
  # `xclip` and `wl-copy` fork a process that serves the selection, and it
  # would otherwise hold the pipe `System.cmd/3` waits on until somebody else
  # copied something.
  #
  # The shell was a bare `"sh"`, which `System.cmd/3` raises over when it is
  # not on PATH — a minimal image, a PATH that leaves out `/bin` — and a copy
  # runs in the terminal UI's own process, so the raise took the screen with
  # it. No shell, or one that will not start, is now a native copy that did
  # not happen: `copy/3` falls back to OSC 52, as for any other failure here.
  #
  # `temporary` is where that directory is made, the system's temporary
  # directory unless a test names its own.
  @spec native_copy(
          tool :: {Path.t(), [String.t()]},
          text :: String.t(),
          shell :: (-> {:ok, Path.t()} | :error),
          temporary :: Path.t() | nil
        ) :: :ok | {:error, term()}
  def native_copy({executable, args}, text, shell, temporary \\ nil)
      when is_function(shell, 0) do
    case shell.() do
      {:ok, shell} -> through_file(shell, executable, args, text, temporary || System.tmp_dir!())
      :error -> {:error, :no_shell}
    end
  end

  defp through_file(shell, executable, args, text, temporary) do
    with {:ok, dir} <- private_dir(temporary) do
      path = Path.join(dir, "selection")

      try do
        with :ok <- File.write(path, text, [:exclusive]) do
          command = ~s("$0" "$@" < "$LMX_SELECTION" > /dev/null 2>&1)
          run_tool(shell, ["-c", command, executable | args], [{"LMX_SELECTION", path}])
        end
      after
        File.rm_rf(dir)
      end
    end
  end

  defp private_dir(temporary) do
    name = "lmx-copy-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(temporary, name)

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    end
  end

  defp run_tool(shell, arguments, env) do
    case System.cmd(shell, arguments, env: env) do
      {_output, 0} -> :ok
      {_output, status} -> {:error, {:exit_status, status}}
    end
  rescue
    # The spawn itself failed — a shell that vanished or will not execute.
    error in ErlangError -> {:error, {:shell, error.original}}
  end

  defp present?(env, name), do: Map.get(env, name, "") != ""

  @doc false
  @spec sequence(text :: String.t()) :: String.t()
  def sequence(text) when is_binary(text), do: "\e]52;c;" <> Base.encode64(text) <> "\a"

  defp emit(writer, text) do
    case writer.(sequence(text)) do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_writer_result, other}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
