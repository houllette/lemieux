defmodule Lemieux.Extensions.Workspace.Memory do
  @moduledoc """
  Where durable memory lives, and how a host adds to it — what `/memory`
  does.

  `Lemieux.Extensions.Workspace.Discovery` already reads two `MEMORY.md`
  files into every prompt: the person's (`~/.lmx/MEMORY.md`) and the
  repository's (`MEMORY.md` at its root). Nothing could write them from a
  session: the agent's file tools are confined to the working directory, so
  the personal file was out of reach, and asking the model to edit the
  repository's by hand means an `edit` against a file it may never have
  read. A person saying "remember this" is not a task for the model at all
  — it is a line to append — so this module does exactly that.

  Entries are appended, never rewritten: memory is a log a person curates
  by editing the file, and a tool that reorganised it would be the one
  thing guaranteed to lose something they wrote by hand.

  A `MEMORY.md` inside a repository is written only inside that
  repository, and through the real path that was checked rather than the
  name again. The file is the repository's to commit, so it may be a
  symlink somebody else chose: `MEMORY.md -> ../../.bashrc` would have had
  `/memory --project` append to a shell's startup file, and so did
  `MEMORY.md -> d/../.bashrc` beside a `d` linked elsewhere, while the
  check resolved `..` as text. Discovery refuses to read such a file for the
  same reason (`Lemieux.Extensions.Workspace.Discovery`); a personal memory
  outside any repository may be a link wherever its owner put it.
  """

  alias Lemieux.Extensions.Workspace.Containment

  @max_entry_bytes 4_000

  @typedoc "`:personal` is `~/.lmx/MEMORY.md`; `:project` is the repository's."
  @type scope :: :personal | :project

  @doc """
  The memory file for `scope`.

  `:root` is the repository root (a `Discovery` has it as `root`), required
  for `:project`; `:personal_dir` defaults to `~/.lmx`.
  """
  @spec path(scope :: scope(), opts :: keyword()) :: Path.t()
  def path(scope, opts \\ [])

  def path(:personal, opts),
    do: opts |> Keyword.get_lazy(:personal_dir, fn -> Path.expand("~/.lmx") end) |> memory()

  def path(:project, opts), do: opts |> Keyword.fetch!(:root) |> memory()

  defp memory(directory), do: Path.join(directory, "MEMORY.md")

  @doc """
  Appends `text` to the memory file at `path` as one dated bullet, creating
  the file (and a personal directory, privately) when there is none.

  Refuses an empty entry and one over #{@max_entry_bytes} bytes — memory is
  read into every prompt, and a pasted log would be paid for on every
  request of every session afterwards.
  """
  @spec append(path :: Path.t(), text :: String.t(), opts :: keyword()) ::
          :ok | {:error, String.t()}
  def append(path, text, opts \\ []) when is_binary(path) and is_binary(text) do
    entry = text |> String.trim() |> String.replace(~r/\s*\n\s*/, " ")
    today = opts |> Keyword.get_lazy(:today, &Date.utc_today/0) |> Date.to_iso8601()

    cond do
      entry == "" ->
        {:error, "nothing to remember"}

      byte_size(entry) > @max_entry_bytes ->
        {:error, "a memory entry is limited to #{@max_entry_bytes} bytes"}

      true ->
        with {:ok, target} <- contained(path), do: write(target, "- #{today}: #{entry}\n")
    end
  end

  # Where to write: the real path, when the file is in a repository and that
  # path is still inside it.
  defp contained(path) do
    path = Path.expand(path)

    case repository(Path.dirname(path)) do
      nil ->
        {:ok, path}

      root ->
        real = Containment.real_path(path)

        if Containment.inside?(real, Containment.real_path(root)),
          do: {:ok, real},
          else:
            {:error,
             "#{path} is a symlink to a file outside the repository, and lmx does not write " <>
               "through it"}
    end
  end

  defp repository(directory) do
    cond do
      File.exists?(Path.join(directory, ".git")) -> directory
      Path.dirname(directory) == directory -> nil
      true -> repository(Path.dirname(directory))
    end
  end

  defp write(path, line) do
    with :ok <- directory(Path.dirname(path)),
         {:ok, prefix} <- separator(path),
         :ok <- File.write(path, [prefix, line], [:append]) do
      :ok
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "could not write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # A new personal directory is created private, like the rest of `~/.lmx`.
  defp directory(directory) do
    if File.dir?(directory) do
      :ok
    else
      with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)
    end
  end

  # A file that does not end in a newline would glue the entry onto its last
  # line; a new file gets a heading so it reads as what it is.
  defp separator(path) do
    case File.read(path) do
      {:ok, ""} -> {:ok, "# Memory\n\n"}
      {:ok, contents} -> {:ok, if(String.ends_with?(contents, "\n"), do: "", else: "\n")}
      {:error, :enoent} -> {:ok, "# Memory\n\n"}
      {:error, reason} -> {:error, reason}
    end
  end
end
