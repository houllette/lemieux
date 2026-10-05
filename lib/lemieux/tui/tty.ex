defmodule Lemieux.TUI.Tty do
  @moduledoc """
  The path of the terminal this VM is attached to, for the commands it runs.

  A command the VM starts — `sh`, `stty`, an editor — is started by
  `erl_child_setup` in a session of its own, with no controlling terminal.
  `/dev/tty` means "my controlling terminal", so in that command it names
  nothing: `stty -g < /dev/tty` fails with "Device not configured", which
  is how the Ctrl-G editor handoff answered "this terminal could not be
  handed to an editor" on every terminal. The terminal's own device path —
  `/dev/ttys003`, `/dev/pts/2` — opens from any session the user owns, and
  `stty` sets its modes from there exactly as it would through `/dev/tty`.

  Found from the VM's own descriptors where the OS shows them (`/proc` on
  Linux, which also covers a BusyBox `ps` that cannot answer the question),
  and otherwise from `ps -o tty=`, which is how macOS says it. `nil` where
  the VM has no terminal, and on Windows, which has neither.
  """

  @doc "The terminal device the VM is attached to, or `nil`. See the moduledoc."
  @spec device() :: Path.t() | nil
  def device do
    case :os.type() do
      {:unix, _name} -> from_proc() || from_ps()
      _windows -> nil
    end
  end

  @doc false
  @spec device_path(name :: String.t()) :: Path.t() | nil
  # What `ps` prints is the device's name under `/dev`, or `?` (Linux) and
  # `??` (macOS) for a process with no terminal.
  def device_path(name) do
    case String.trim(name) do
      none when none in ["", "?", "??", "-"] -> nil
      "/dev/" <> _rest = path -> path
      name -> "/dev/" <> name
    end
  end

  @doc false
  @spec terminal_link(target :: String.t()) :: Path.t() | nil
  # What `/proc/PID/fd/N` points at, when that is a terminal: a
  # pseudo-terminal (`/dev/pts/2`) or a console (`/dev/tty1`, `/dev/ttyS0`).
  # `/dev/tty` itself is the one path that names nothing in a child, and a
  # pipe, a socket, a file or `/dev/null` is no terminal at all.
  def terminal_link("/dev/pts/" <> _rest = path), do: path
  def terminal_link("/dev/tty" <> rest = path) when rest != "", do: path
  def terminal_link(_other), do: nil

  defp from_proc do
    Enum.find_value(0..2, fn fd ->
      case File.read_link("/proc/#{System.pid()}/fd/#{fd}") do
        {:ok, target} -> terminal_link(target)
        {:error, _reason} -> nil
      end
    end)
  end

  defp from_ps do
    with ps when is_binary(ps) <- System.find_executable("ps"),
         {name, 0} <- System.cmd(ps, ["-o", "tty=", "-p", System.pid()], stderr_to_stdout: true),
         path when is_binary(path) <- device_path(name),
         true <- File.exists?(path) do
      path
    else
      _no_terminal -> nil
    end
  end
end
