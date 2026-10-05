defmodule Lemieux.Environment.Sandbox.Bubblewrap do
  @moduledoc """
  The Linux half of `Lemieux.Environment.Sandbox`: a `bwrap` command line.

  The whole filesystem is bound read-only, then the writable roots are bound
  read-write on top and the hidden paths are covered — directories by an
  empty tmpfs, files by `/dev/null`. The network namespace is unshared unless
  network is allowed; a fresh namespace still has its own loopback, so a test
  server the command starts itself is reachable, but the host's services are
  not. That is stricter than the macOS profile's loopback rule, and there is no
  way to be as permissive without leaving the host's namespace.

  `--unshare-pid` with `--die-with-parent` is what makes cancellation work:
  when the local runner kills `bwrap`, the sandbox's init dies with it and
  the kernel takes every process in that namespace down, however deep the
  command's children went. `--new-session` detaches the command from any
  controlling terminal, so nothing inside can push keystrokes into the
  terminal the agent's own interface runs in.
  """

  alias Lemieux.Environment.Sandbox

  @doc "The shell command that runs `command` under `bwrap` from `cwd`."
  @spec wrap(sandbox :: Sandbox.t(), command :: String.t(), cwd :: Path.t()) :: String.t()
  def wrap(%Sandbox{} = sandbox, command, cwd) do
    [
      "exec"
      | Enum.map([sandbox.executable | arguments(sandbox, cwd, command)], &Sandbox.quote_shell/1)
    ]
    |> Enum.join(" ")
  end

  @doc "The `bwrap` arguments, in order, for `command` run from `cwd`."
  @spec arguments(sandbox :: Sandbox.t(), cwd :: Path.t(), command :: String.t()) :: [String.t()]
  def arguments(%Sandbox{} = sandbox, cwd, command) do
    root = Sandbox.real(cwd)
    roots = Enum.uniq([root | sandbox.writable])

    List.flatten([
      ["--die-with-parent", "--unshare-pid", "--new-session"],
      ["--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc"],
      Enum.map(roots, &["--bind", &1, &1]),
      Enum.map(sandbox.hidden, &hide/1),
      if(sandbox.network, do: [], else: ["--unshare-net"]),
      ["--chdir", root, "--", sandbox.shell, "-c", command]
    ])
  end

  defp hide(path) do
    if File.dir?(path),
      do: ["--tmpfs", path],
      else: ["--ro-bind", "/dev/null", path]
  end
end
