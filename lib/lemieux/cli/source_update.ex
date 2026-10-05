defmodule Lemieux.CLI.SourceUpdate do
  @moduledoc """
  Explicit Git updates for the source TUI host.

  The checkout is the one this module was compiled from, never the agent's
  workspace or the shell's current directory. A Hex dependency nested in a
  different Git repository therefore cannot update its embedding application.
  Nothing is checked automatically; only `/update` fetches the configured
  branch upstream, including commits that do not change the package version.

  Fetching leaves the working tree alone. Activation uses a pinned commit and
  checks the branch, HEAD, upstream and cleanliness again after the TUI's idle
  gate. Local work is never stashed, reset, rebased or merged. Git's own
  fast-forward and overwrite checks remain the final guard against concurrent
  edits. Source updates require a restart: recompiling into a running source
  VM has none of the installed host's reviewed OTP compatibility guarantees.
  """

  alias Lemieux.Environment.Local.ExCmd

  @source_path Path.expand("../../..", __DIR__)
  @operations ~w(MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG)

  @type result :: {:error, {:source_update, atom()}}

  @doc "Fetches the upstream and returns a pinned fast-forward candidate."
  @spec check(opts :: keyword()) :: :current | {:ok, map()} | result()
  def check(opts \\ []) do
    with {:ok, snapshot} <- snapshot(opts),
         {:ok, _output} <-
           git(
             [
               "fetch",
               "--quiet",
               "--no-tags",
               "--no-recurse-submodules",
               "--",
               snapshot["remote"],
               "+#{snapshot["merge"]}:#{snapshot["upstream"]}"
             ],
             fetch_options(opts),
             :fetch_failed
           ),
         {:ok, target} <-
           git(["rev-parse", "--verify", snapshot["upstream"] <> "^{commit}"], opts) do
      candidate(snapshot, target, opts)
    end
  end

  defp candidate(%{"head" => head}, head, _opts), do: :current

  defp candidate(snapshot, target, opts) do
    with :ok <- fast_forward(snapshot["head"], target, opts) do
      {:ok,
       Map.merge(snapshot, %{
         "version" => target,
         "notice" => "Git update #{String.slice(target, 0, 12)} is available · /update"
       })}
    end
  end

  @doc "Fast-forwards a checked candidate without compiling or replacing live code."
  @spec apply(info :: map(), opts :: keyword()) :: {:ok, :restart} | result()
  def apply(info, opts \\ []) do
    with {:ok, current} <- snapshot(opts),
         :ok <- unchanged(info, current),
         :ok <- fast_forward(current["head"], info["version"], opts),
         {:ok, _output} <-
           git(
             [
               "merge",
               "--quiet",
               "--ff-only",
               "--no-autostash",
               "--no-overwrite-ignore",
               "--",
               info["version"]
             ],
             opts,
             :apply_failed
           ) do
      {:ok, :restart}
    end
  end

  @doc """
  Source-specific restart instructions, also used by persistent reminders.

  Names `mix lmx`, the command a source checkout runs every lmx command
  through (`Mix.Tasks.Lmx`); `mix lmx.tui` still works, but a person told to
  restart it learns the older of two spellings for the same screen.
  """
  @spec restart_notice(revision :: String.t()) :: String.t()
  def restart_notice(revision) do
    "Source updated to #{String.slice(revision, 0, 12)} · run mix deps.get in your launch directory, then restart mix lmx to load it."
  end

  defp snapshot(opts) do
    source = source_path(opts)

    with :ok <- checkout(source, opts),
         {:ok, git_dir} <- git(["rev-parse", "--absolute-git-dir"], opts),
         :ok <- no_operation(git_dir),
         {:ok, branch} <- git(["symbolic-ref", "--quiet", "--short", "HEAD"], opts, :detached),
         {:ok, head} <- git(["rev-parse", "--verify", "HEAD"], opts),
         {:ok, remote} <- git(["config", "--get", "branch.#{branch}.remote"], opts, :no_upstream),
         {:ok, merge} <- git(["config", "--get", "branch.#{branch}.merge"], opts, :no_upstream),
         {:ok, upstream} <- upstream(opts),
         :ok <- clean(opts) do
      {:ok,
       %{
         "source" => source,
         "branch" => branch,
         "head" => head,
         "remote" => remote,
         "merge" => merge,
         "upstream" => upstream
       }}
    end
  end

  defp checkout(source, opts) do
    case git(["rev-parse", "--show-toplevel"], opts, :not_checkout) do
      {:ok, root} -> if same_directory?(source, root), do: :ok, else: error(:not_checkout)
      {:error, _} = failure -> failure
    end
  end

  # Git resolves symlinks in its root path (including macOS's /var alias).
  # Compare directory identity so an alias is accepted without allowing a
  # dependency subdirectory to update the surrounding application's checkout.
  defp same_directory?(left, right) do
    with {:ok, left} <- File.stat(left),
         {:ok, right} <- File.stat(right) do
      left.type == :directory and
        {left.inode, left.major_device, left.minor_device} ==
          {right.inode, right.major_device, right.minor_device}
    else
      _unavailable -> false
    end
  end

  defp upstream(opts) do
    case git(["rev-parse", "--symbolic-full-name", "@{upstream}"], opts, :no_upstream) do
      {:ok, "refs/remotes/" <> _ = ref} -> {:ok, ref}
      _other -> error(:no_upstream)
    end
  end

  defp clean(opts) do
    case git(["status", "--porcelain", "--untracked-files=all"], opts) do
      {:ok, ""} -> :ok
      {:ok, _changes} -> error(:dirty)
      failure -> failure
    end
  end

  @doc "Actionable update errors without Git output or remote credentials."
  @spec error_notice(reason :: term()) :: String.t()
  def error_notice({:source_update, :dirty}),
    do:
      "Source update paused: the checkout has local changes. Commit or stash them, then retry /update."

  def error_notice({:source_update, :detached}),
    do:
      "Source update paused: HEAD is detached. Check out a branch with a remote upstream, then retry /update."

  def error_notice({:source_update, :no_upstream}),
    do:
      "Source update paused: this branch needs a remote upstream. Configure it with git branch --set-upstream-to, then retry /update."

  def error_notice({:source_update, :not_fast_forward}),
    do:
      "Source update paused: the branch is ahead of or diverged from its upstream. Resolve its history through Git, then retry /update."

  def error_notice({:source_update, :git_busy}),
    do: "Source update paused: a Git operation is in progress. Finish it, then retry /update."

  def error_notice({:source_update, :checkout_changed}),
    do: "The source checkout changed after the update check. Retry /update to check it again."

  def error_notice({:source_update, :not_checkout}),
    do:
      "This Lemieux installation has no source Git checkout. Update it through its package or installation manager."

  def error_notice({:source_update, :git_missing}),
    do: "Source updates require Git on PATH. Install Git, then retry /update."

  def error_notice({:source_update, :fetch_failed}),
    do:
      "Could not fetch the Git upstream. Check connectivity and Git authentication, then retry /update."

  def error_notice(_reason),
    do:
      "The Git update could not be completed. Inspect the source checkout through Git, then retry /update. Your session is still open."

  defp no_operation(git_dir) do
    if Enum.any?(@operations, &File.exists?(Path.join(git_dir, &1))),
      do: error(:git_busy),
      else: :ok
  end

  defp unchanged(info, current) do
    if Map.take(info, Map.keys(current)) == current, do: :ok, else: error(:checkout_changed)
  end

  defp fast_forward(head, target, opts) do
    with {:ok, _output} <-
           git(["merge-base", "--is-ancestor", head, target], opts, :not_fast_forward),
         do: :ok
  end

  defp source_path(opts), do: opts |> Keyword.get(:source_path, @source_path) |> Path.expand()

  # Use the local runner's deadline and process cleanup. Plain System.cmd/3
  # has no timeout and can strand an SSH child when its task is killed. Quote
  # every argument, discard diagnostics (remote URLs can carry credentials),
  # and disable interactive credential prompts while the terminal is in raw mode.
  defp git(args, opts, reason \\ :git_failed) do
    with executable when is_binary(executable) <- System.find_executable("git"),
         {:ok, stream} <-
           ExCmd.run(command(executable, args, opts),
             cwd: source_path(opts),
             timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
             max_output_bytes: 65_536
           ) do
      {output, status} = Enum.reduce(stream, {[], nil}, &collect/2)

      if status == 0,
        do: {:ok, output |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()},
        else: error(reason)
    else
      nil -> error(:git_missing)
      _failure -> error(reason)
    end
  end

  defp fetch_options(opts) do
    configured = git(["config", "--get", "core.sshCommand"], opts)

    ssh =
      case {System.get_env("GIT_SSH_COMMAND"), configured, System.get_env("GIT_SSH")} do
        {command, _, _} when is_binary(command) -> command
        {_, {:ok, command}, _} -> command
        {_, _, executable} when is_binary(executable) -> shell_quote(executable)
        _default -> "ssh"
      end

    Keyword.put(opts, :ssh_command, ssh)
  end

  defp command(executable, args, opts) do
    ssh = Keyword.get(opts, :ssh_command, "ssh") <> " -oBatchMode=yes -oConnectTimeout=10"

    env = [
      "env",
      "-u",
      "GIT_DIR",
      "-u",
      "GIT_WORK_TREE",
      "-u",
      "GIT_INDEX_FILE",
      "-u",
      "GIT_COMMON_DIR",
      "GIT_TERMINAL_PROMPT=0",
      "GIT_SSH_COMMAND=#{ssh}"
    ]

    Enum.map_join(env ++ [executable | args], " ", &shell_quote/1)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
  defp collect({:data, data}, {output, status}), do: {[data | output], status}
  defp collect({:exit_status, status}, {output, _}), do: {output, status}
  defp collect(_failure, {output, _}), do: {output, :failed}
  defp error(reason), do: {:error, {:source_update, reason}}
end
