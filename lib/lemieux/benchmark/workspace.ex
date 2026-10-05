defmodule Lemieux.Benchmark.Workspace do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Prepares one disposable working directory per benchmark attempt.

  Copying is deliberately the portable default. A host evaluating large Git
  repositories should pass its own workspace callback to
  `Lemieux.Benchmark.run/3` and use worktrees, snapshots or another cheap copy
  mechanism it already trusts.

  Attempt directories use random IDs and are exclusively reserved before copy.
  A VM-local integer let independent benchmark processes overwrite the same
  task workspace and delete each other's files during cleanup. Per-VM process
  isolation does not isolate a shared temporary directory.

  Every copy is initialized as its own Git repository so that Git commands
  the evaluated agent runs stop at the workspace instead of reaching a
  repository that happens to enclose it. This is the only containment the
  copy provides: the agent's shell is otherwise the host's.
  """

  alias Lemieux.Benchmark.Task

  @typedoc "A function that removes resources created for an attempt."
  @type cleanup :: (-> term())

  @doc "Copies a task's working directory and returns the task pointed at the copy."
  @spec copy(task :: Task.t(), context :: map()) ::
          {:ok, Task.t(), cleanup()} | {:error, term()}
  def copy(%Task{} = task, context) when is_map(context) do
    root = Map.get(context, :workspace_root) || default_root()
    attempt = Map.fetch!(context, :attempt)
    runtime = Map.fetch!(context, :runtime)
    destination = Path.join(root, safe("#{task.id}-#{runtime}-#{attempt}-#{unique()}"))

    with :ok <- File.mkdir_p(root),
         :ok <- File.mkdir(destination) do
      copy_reserved(task, destination)
    end
  end

  defp copy_reserved(task, destination) do
    with {:ok, _files} <- File.cp_r(task.cwd, destination),
         :ok <- isolate_git(destination) do
      {:ok, %{task | cwd: destination}, fn -> File.rm_rf(destination) end}
    else
      {:error, reason, _file} ->
        File.rm_rf(destination)
        {:error, reason}

      {:error, reason} ->
        File.rm_rf(destination)
        {:error, reason}
    end
  end

  # To Git, a copy under a directory inside a repository is part of that
  # repository: `git add -A && git commit` from the copy walks up and commits the
  # enclosing tree, which an evaluated session once did to this repository under a
  # fixture task's title. An empty repository at the copy's root ends the walk, and
  # `Lemieux.Benchmark.WorkspaceSnapshot` already ignores `.git`. Without a git
  # binary there is no walk to end.
  defp isolate_git(destination) do
    case System.find_executable("git") do
      nil ->
        :ok

      git ->
        case System.cmd(git, ["init", "-q"], cd: destination, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:git_init_failed, status, String.trim(output)}}
        end
    end
  end

  @doc "Uses the manifest directory directly. Intended only for pre-isolated inputs."
  @spec in_place(task :: Task.t(), context :: map()) :: {:ok, Task.t(), cleanup()}
  def in_place(%Task{} = task, _context), do: {:ok, task, fn -> :ok end}

  defp default_root, do: Path.join(System.tmp_dir!(), "lemieux-benchmark-workspaces")
  defp unique, do: Lemieux.ID.generate()
  defp safe(name), do: String.replace(name, ~r/[^A-Za-z0-9_.-]/, "-")
end
