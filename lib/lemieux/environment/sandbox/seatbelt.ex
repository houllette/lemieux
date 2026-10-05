defmodule Lemieux.Environment.Sandbox.Seatbelt do
  @moduledoc """
  The macOS half of `Lemieux.Environment.Sandbox`: a Seatbelt profile and the
  `sandbox-exec` command line that applies it.

  The profile starts from `(allow default)` and takes away what the sandbox
  exists to take away — writes outside the allowed roots, the network, and the
  credential directories — rather than starting from `(deny default)` and
  granting back what every build tool needs. A deny-by-default profile has to
  enumerate the Mach services, sysctls and IOKit classes that compilers, the
  BEAM and language servers use, and the first one it misses turns into a
  command that fails in a way nobody can read. The cost is that this profile
  is a boundary on writes and reach, not on every system interface — which is
  what the moduledoc of `Lemieux.Environment.Sandbox` promises and no more.

  Seatbelt applies the last matching rule, so the order below is the policy:
  deny all writes, allow the roots, then deny the hidden paths again even when
  they sit inside a root (a session started in `$HOME` must still not write
  `~/.ssh`).
  """

  alias Lemieux.Environment.Sandbox

  # Device files a command writes to without meaning to "write a file".
  @devices ~w(/dev/null /dev/zero /dev/stdout /dev/stderr /dev/dtracehelper)

  @doc """
  The shell command that runs `command` under `sandbox-exec` from `cwd`.

  `exec` replaces the launching shell, so the sandboxed process is the one the
  local runner signals when the command times out or is cancelled.
  """
  @spec wrap(sandbox :: Sandbox.t(), command :: String.t(), cwd :: Path.t()) :: String.t()
  def wrap(%Sandbox{} = sandbox, command, cwd) do
    Enum.join(
      [
        "exec",
        Sandbox.quote_shell(sandbox.executable),
        "-p",
        Sandbox.quote_shell(profile(sandbox, cwd)),
        Sandbox.quote_shell(sandbox.shell),
        "-c",
        Sandbox.quote_shell(command)
      ],
      " "
    )
  end

  @doc "The Seatbelt profile for `sandbox` with `cwd` as the working directory."
  @spec profile(sandbox :: Sandbox.t(), cwd :: Path.t()) :: String.t()
  def profile(%Sandbox{} = sandbox, cwd) do
    roots = Enum.uniq([Sandbox.real(cwd) | sandbox.writable])

    [
      "(version 1)",
      "(allow default)",
      network(sandbox, roots),
      "(deny file-write*)",
      "(allow file-write*",
      Enum.map(roots, &"  (subpath #{string(&1)})"),
      Enum.map(@devices, &"  (literal #{string(&1)})"),
      ~S|  (regex #"^/dev/fd/")|,
      ~S|  (regex #"^/dev/tty"))|,
      hidden(sandbox.hidden)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == []))
    |> Enum.join("\n")
  end

  defp network(%Sandbox{network: true}, _roots), do: []

  defp network(%Sandbox{localhost: localhost?}, roots) do
    loopback =
      if localhost?,
        do: [
          ~S|(allow network-outbound (remote ip "localhost:*"))|,
          ~S|(allow network-inbound (local ip "localhost:*"))|,
          ~S|(allow network-bind (local ip "localhost:*"))|
        ],
        else: []

    # Unix sockets under the writable roots only: a test server listening in
    # /tmp is local IPC, the Docker daemon's socket is a way out.
    sockets =
      Enum.map(roots, &"(allow network-outbound (remote unix-socket (path-regex #{prefix(&1)})))")

    ["(deny network*)" | loopback] ++ sockets
  end

  defp hidden([]), do: []

  defp hidden(paths) do
    ["(deny file-read* file-write*" | Enum.map(paths, &"  (subpath #{string(&1)})")]
    |> List.update_at(-1, &(&1 <> ")"))
  end

  # A Seatbelt string literal. Backslashes and double quotes are the only
  # characters with meaning inside one.
  defp string(value),
    do: ~s("#{value |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))}")

  defp prefix(path), do: ~s(#"^#{Regex.escape(path)}/")
end
