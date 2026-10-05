defmodule Lemieux.Tools.Search.Files do
  @moduledoc """
  The files under a directory that a search should consider, from the best
  source the environment has.

  In order:

    1. **`rg --files`**: fast, and it honours `.gitignore`, `.ignore` and
       global excludes the way a developer's own searches do. `--hidden`
       keeps dotfiles such as `.github/workflows/ci.yml` searchable; `.git`
       itself is excluded.
    2. **`git ls-files --cached --others --exclude-standard`**: the same
       ignore rules from git itself, for a machine without `rg`. Files the
       index knows but the working tree has lost are subtracted, so a listing
       never names a path that is not there.
    3. **A directory walk** through `Lemieux.Environment.list_dir/3`, with
       `Lemieux.Tools.Search.Ignore` reading `.gitignore` files on the way
       down, for a directory that is not a repository on a machine without
       `rg`.

  A backend is abandoned for the next one only when it is *unavailable*: the
  program is missing, or the directory is not a repository.

  Every listing is capped and says whether it is complete. The obvious
  alternative, listing everything and then cutting, holds a monorepo's
  million paths in memory before the first match is reported.
  """

  alias Lemieux.Environment
  alias Lemieux.Tools.Search.Command
  alias Lemieux.Tools.Search.Ignore

  @default_max_files 50_000
  @walk_budget_ms 15_000

  @typedoc "Paths relative to the listed directory, sorted, with where they came from."
  @type listing :: %{files: [String.t()], backend: :rg | :git | :walk, complete?: boolean()}

  @doc """
  Lists the files under `directory` (relative to `cwd`, `""` for `cwd`).

  Option: `:max_files` (default #{@default_max_files}).
  """
  @spec list(
          environment :: Environment.t(),
          cwd :: Path.t(),
          directory :: String.t(),
          opts :: keyword()
        ) :: {:ok, listing()} | {:error, String.t()}
  def list(environment, cwd, directory, opts \\ []) do
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    absolute = if directory == "", do: cwd, else: Path.join(cwd, directory)

    with :unavailable <- ripgrep(environment, absolute, max_files),
         :unavailable <- git(environment, absolute, max_files) do
      walk(environment, cwd, directory, max_files)
    end
  end

  @doc """
  Whether `rg` can be skipped without asking: the environment is the local
  machine and `rg` is not on its `PATH`.

  Asking a shell for a program it does not have costs a process start per
  search. For any other environment the answer comes from running it.
  """
  @spec ripgrep_absent?(environment :: Environment.t()) :: boolean()
  def ripgrep_absent?(environment) do
    Environment.name(environment) == "Lemieux.Environment.Local" and
      is_nil(System.find_executable("rg"))
  end

  defp ripgrep(environment, absolute, max_files) do
    if ripgrep_absent?(environment) do
      :unavailable
    else
      # stderr is discarded: the environment merges it into stdout, and a
      # warning about one unreadable directory would otherwise land inside the
      # NUL-separated list and turn into a path that does not exist.
      command =
        Command.join(
          ~w(rg --files --no-config --hidden --no-require-git --null --sort path) ++
            ["-g", "!.git", "--", "."]
        ) <> " 2>/dev/null"

      environment
      |> Command.run(absolute, command, max_bytes: max_files * 256)
      |> ripgrep_listing(max_files)
    end
  end

  defp ripgrep_listing({:ok, %{status: status, output: output}}, max_files)
       when status in [0, :truncated, :timeout] do
    {:ok, listing(split_null(output), :rg, status == 0, max_files)}
  end

  defp ripgrep_listing({:ok, %{status: 1}}, _max_files),
    do: {:ok, %{files: [], backend: :rg, complete?: true}}

  # Status 2 is "something went wrong along the way": an unreadable directory,
  # usually, after everything readable was listed. What was listed is still the
  # answer, marked incomplete; nothing listed means rg could not do the job.
  defp ripgrep_listing({:ok, %{status: 2, output: output}}, max_files) when output != "",
    do: {:ok, listing(split_null(output), :rg, false, max_files)}

  defp ripgrep_listing(_other, _max_files), do: :unavailable

  defp git(environment, absolute, max_files) do
    case Command.run(
           environment,
           absolute,
           # No fsmonitor (empty, which every git version reads as off):
           # listing files must not start a program the repository's
           # configuration names.
           "git -c core.fsmonitor= ls-files -z --cached --others --exclude-standard 2>/dev/null",
           max_bytes: max_files * 256
         ) do
      # Nothing listed usually means the directory is itself ignored — a
      # dependency tree the model asked about by name. `rg` searches a directory
      # it was given explicitly; git lists nothing in one it ignores. Walking it
      # keeps the two backends answering the same question.
      {:ok, %{status: 0, output: ""}} ->
        :unavailable

      {:ok, %{status: status, output: output}} when status in [0, :truncated, :timeout] ->
        missing = deleted(environment, absolute)
        files = output |> split_null() |> Enum.reject(&MapSet.member?(missing, &1))
        {:ok, listing(files, :git, status == 0, max_files)}

      _unavailable ->
        :unavailable
    end
  end

  defp deleted(environment, absolute) do
    case Command.run(environment, absolute, "git ls-files -z --deleted 2>/dev/null") do
      {:ok, %{status: 0, output: output}} -> output |> split_null() |> MapSet.new()
      _other -> MapSet.new()
    end
  end

  defp listing(files, backend, complete?, max_files) do
    files =
      files
      |> Enum.map(&String.replace_prefix(&1, "./", ""))
      |> Enum.reject(&(&1 == ""))
      |> Enum.sort()
      |> Enum.uniq()

    %{
      files: Enum.take(files, max_files),
      backend: backend,
      complete?: complete? and length(files) <= max_files
    }
  end

  defp split_null(output), do: String.split(output, <<0>>, trim: true)

  # Depth first in name order, so the listing comes out sorted without a second
  # pass and the budget cuts it at a predictable place.
  defp walk(environment, cwd, directory, max_files) do
    walk = %{
      environment: environment,
      cwd: cwd,
      root: directory,
      deadline: System.monotonic_time(:millisecond) + @walk_budget_ms,
      max_files: max_files
    }

    state = walk_directory(walk, "", Ignore.default(), %{files: [], count: 0, complete?: true})
    {:ok, %{files: Enum.reverse(state.files), backend: :walk, complete?: state.complete?}}
  end

  defp walk_directory(_walk, _relative, _rules, %{complete?: false} = state), do: state

  defp walk_directory(walk, relative, rules, state) do
    if System.monotonic_time(:millisecond) > walk.deadline do
      %{state | complete?: false}
    else
      location = join(walk.root, relative)
      listable = if location == "", do: ".", else: location

      case Environment.list_dir(walk.environment, walk.cwd, listable) do
        {:ok, entries} ->
          rules = rules ++ local_rules(walk, location, relative, entries)
          walk_entries(walk, relative, Enum.sort_by(entries, & &1.name), rules, state)

        {:error, _reason} ->
          state
      end
    end
  end

  defp walk_entries(walk, relative, entries, rules, state) do
    Enum.reduce_while(entries, state, fn entry, state ->
      path = join(relative, entry.name)
      state = visit(walk, entry.type, path, rules, state)
      if state.complete?, do: {:cont, state}, else: {:halt, state}
    end)
  end

  defp visit(walk, :directory, path, rules, state) do
    if Ignore.ignored?(rules, path, true),
      do: state,
      else: walk_directory(walk, path, rules, state)
  end

  # Symlinks are listed as files and never followed: following one is how a
  # walk reaches a directory twice, or a directory outside the tree, and
  # reading through it later goes through the environment's own confinement.
  defp visit(walk, _file_or_link, path, rules, state) do
    cond do
      Ignore.ignored?(rules, path, false) -> state
      state.count >= walk.max_files -> %{state | complete?: false}
      true -> %{state | files: [path | state.files], count: state.count + 1}
    end
  end

  defp local_rules(walk, location, relative, entries) do
    if Enum.any?(entries, &(&1.name == ".gitignore")) do
      case Environment.read_file(walk.environment, walk.cwd, join(location, ".gitignore")) do
        {:ok, contents} -> Ignore.parse(contents, relative)
        {:error, _reason} -> []
      end
    else
      []
    end
  end

  defp join("", name), do: name
  defp join(directory, name), do: directory <> "/" <> name
end
