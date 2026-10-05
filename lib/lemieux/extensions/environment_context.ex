defmodule Lemieux.Extensions.EnvironmentContext do
  @moduledoc """
  Tells the model where it is: the date, the platform, the shell, the working
  directory and the repository's state, once, at the end of the system prompt.

  Without it the model guesses. It reaches for GNU flags on a BSD userland,
  assumes a training-era date when reasoning about releases or certificates,
  and has to spend a command discovering what branch it is on and whether
  the tree was already dirty before it touched anything. Every leading
  coding agent supplies these facts for that reason; the library does not,
  because a host that runs its sessions in a container or on a remote
  workspace knows its environment better than the BEAM's own machine does.
  So this is an extension a host applies — `Lemieux.Extensions.coding/3`
  includes it with `environment_context: true`, and `lmx` turns that on —
  and never something the session does.

  ## Once per session

  The block is computed in `init/1` and applied as it stands. A block that
  changed per request would move the end of the system prompt on every
  call and break every provider's prompt cache from that point on, which is
  the one part of a request that is otherwise identical from turn to turn.
  The price is that the git status is the status *when the session started*,
  and the block says so: the model runs `git status` when it needs the
  current one, exactly as it would have without the block.

  ## Bounded, and never a lock

  The status is capped at twenty entries and the git command at two seconds,
  so a repository with a hundred thousand untracked files or a hung
  filesystem costs a line saying so rather than a slow start. Git runs with
  `GIT_OPTIONAL_LOCKS=0`: `git status` otherwise refreshes the index and
  takes `index.lock` to do it, and a person running `git commit` in another
  terminal while `lmx` starts would get "another git process seems to be
  running" from a tool that only meant to look.

  It runs as `Lemieux.Checkpoint.Git.status/2` runs it: in a git directory
  of its own, from a copy of the index, so nothing the repository configures
  runs here — no `core.fsmonitor`, no filter, no submodule's own
  configuration. A plain `git status` in a repository a sandboxed command
  had written ran whatever that command put in `.git/config` the next time a
  session started there. One past the two seconds is left to finish and
  remove its copy, not killed half-way.

  ## Resume

  The block sits between markers, and `apply/2` removes a previous block
  before adding the current one, so a prompt composed over a recorded one
  carries today's facts once rather than last week's beside them.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Checkpoint.Git
  alias Lemieux.Harness

  @start "<!-- lmx-environment:start -->"
  @finish "<!-- lmx-environment:end -->"
  @max_status_lines 20
  @max_line_bytes 200
  @git_timeout_ms 2_000

  @type state :: %{block: String.t(), cwd: Path.t(), git?: boolean(), date: String.t()}

  @doc """
  Reads the environment once.

  Options: `:cwd`, the session's working directory (default the current
  directory); `:now`, the moment to report (default the local time), for a
  host whose clock is not the machine's or a test that needs one.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, state()}
  def init(opts) do
    cwd = opts |> Keyword.get_lazy(:cwd, &File.cwd!/0) |> Path.expand()
    date = opts |> Keyword.get_lazy(:now, &NaiveDateTime.local_now/0) |> to_date()
    {git_lines, git?} = git(cwd)

    lines =
      [
        "- Date: #{date} (when this session started)",
        "- Platform: #{platform()}",
        shell(),
        "- Working directory: #{cwd}"
      ] ++ git_lines

    block =
      [
        "## Environment",
        "",
        Enum.join(Enum.reject(lines, &is_nil/1), "\n")
      ]
      |> Enum.join("\n")

    {:ok, %{block: block, cwd: cwd, git?: git?, date: date}}
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %{block: block}) do
    Harness.update_system(harness, &compose(&1, block))
  end

  @impl Lemieux.Extension
  def describe(%{cwd: cwd, git?: git?, date: date}),
    do: %{"cwd" => cwd, "git" => git?, "date" => date}

  @doc """
  `system` with its environment block replaced by `block`.

  Public so a host that builds its prompt by hand composes the same way;
  a `nil` prompt (a host that disabled it) stays `nil`, because an
  environment block alone is not a system prompt anyone asked for.
  """
  @spec compose(system :: String.t() | nil, block :: String.t()) :: String.t() | nil
  def compose(nil, _block), do: nil

  def compose(system, block) when is_binary(system) and is_binary(block) do
    base = strip(system)
    Enum.join([base, @start, block, @finish], "\n\n")
  end

  defp strip(system) do
    case String.split(system, @start, parts: 2) do
      [base, rest] ->
        case String.split(rest, @finish, parts: 2) do
          [_old, after_block] -> String.trim(base <> after_block)
          [_unterminated] -> String.trim(base)
        end

      [unmarked] ->
        String.trim_trailing(unmarked)
    end
  end

  defp to_date(%DateTime{} = now), do: now |> DateTime.to_date() |> Date.to_iso8601()
  defp to_date(%NaiveDateTime{} = now), do: now |> NaiveDateTime.to_date() |> Date.to_iso8601()
  defp to_date(%Date{} = today), do: Date.to_iso8601(today)

  defp platform do
    architecture =
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.split("-", parts: 2)
      |> hd()

    "#{os_name()} (#{os_version()}, #{architecture})"
  end

  defp os_name do
    case :os.type() do
      {:unix, :darwin} -> "macOS"
      {:unix, :linux} -> "Linux"
      {:unix, other} -> Atom.to_string(other)
      {:win32, _flavour} -> "Windows"
    end
  end

  defp os_version do
    case :os.version() do
      {major, minor, patch} -> "#{elem(:os.type(), 1)} #{major}.#{minor}.#{patch}"
      version when is_list(version) -> List.to_string(version)
    end
  end

  defp shell do
    case System.get_env("SHELL") || System.get_env("COMSPEC") do
      nil -> nil
      "" -> nil
      path -> "- Shell: #{Path.basename(path)}"
    end
  end

  # One status for everything: `--branch` puts the branch and its upstream
  # on the first line, so the repository costs a single status however much
  # the block says about it.
  defp git(cwd) do
    case status(cwd) do
      {:ok, output} -> {status_lines(output), true}
      {:error, :not_a_repository} -> {["- Git: not a repository"], false}
      {:error, :timeout} -> {["- Git: status took too long to read at startup"], false}
      {:error, :unavailable} -> {["- Git: not installed"], false}
    end
  end

  defp status_lines(output) do
    {branch, changes} =
      case String.split(output, "\n", trim: true) do
        ["## " <> branch | changes] -> {branch, changes}
        changes -> {nil, changes}
      end

    head = "- Git: repository#{branch_text(branch)}"

    case changes do
      [] ->
        [head <> "; no uncommitted changes when the session started"]

      changes ->
        shown = Enum.take(changes, @max_status_lines)
        more = length(changes) - length(shown)

        [head <> "; uncommitted changes when the session started (git status --short):"] ++
          Enum.map(shown, &("    " <> clip(&1))) ++
          if(more > 0, do: ["    … and #{more} more"], else: [])
    end
  end

  defp branch_text(nil), do: ""
  defp branch_text("No commits yet on " <> branch), do: " on branch #{branch}, no commits yet"
  defp branch_text("HEAD (no branch)"), do: " with a detached HEAD"
  defp branch_text(branch), do: " on branch #{clip(branch)}"

  defp clip(line) when byte_size(line) <= @max_line_bytes, do: line

  defp clip(line) do
    clipped = binary_part(line, 0, @max_line_bytes)
    if String.valid?(clipped), do: clipped <> "…", else: String.replace_invalid(clipped) <> "…"
  end

  defp status(cwd) do
    task = Task.async(fn -> Git.status(cwd) end)

    case Task.yield(task, @git_timeout_ms) || Task.ignore(task) do
      {:ok, {:ok, output}} -> {:ok, output}
      {:ok, {:error, :git_not_found}} -> {:error, :unavailable}
      {:ok, {:error, _not_a_repository}} -> {:error, :not_a_repository}
      nil -> {:error, :timeout}
      {:exit, _reason} -> {:error, :timeout}
    end
  end
end
