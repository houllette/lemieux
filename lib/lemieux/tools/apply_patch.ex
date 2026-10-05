defmodule Lemieux.Tools.ApplyPatch do
  @moduledoc """
  Adds, updates, moves and deletes files with one patch in the format
  GPT-5-family models are trained to write.

  ## Why a second editing tool

  `Lemieux.Tools.Edit` asks for an exact, unique string to replace. That is
  the smallest interface a model can use, and most models use it well; the
  GPT-5 family was instead trained on this format, and asked to use `edit`
  it spends turns on uniqueness errors it would not have made in its own
  dialect. `Lemieux.Extensions.ApplyPatch` puts this tool in `edit`'s place
  for those models only. The contract with the rest of the harness is the
  same: files go through `Lemieux.Environment`, so confinement, sandboxes and
  checkpoints see every write.

  ## All or nothing, as far as it can be

  Every operation is read and applied in memory first. A hunk that does not
  match, a file to add that already exists, a file to update that does not:
  any of these refuses the whole patch before anything is written, so a
  failed patch never leaves the tree half-changed for the model to reason
  about. Writes then happen before deletions, so a move whose write fails
  loses nothing. An I/O error part-way through the writes is the one case
  that can leave some files changed, and the result names exactly which.

  ## What the session has seen

  The same record `write` and `edit` keep (`Lemieux.Tool.FileState`), with
  the rule each operation deserves. Deleting a file discards all of it, so,
  like `write` replacing one, it is refused unless the session has read the
  file and it has not changed since. An update only changes lines its hunks
  matched in the file as it is now, so, like `edit`, it proceeds and says
  when the file had changed since the session last saw it. Adding a file
  needs nothing. Every file written is recorded as seen.

  The format itself is `Lemieux.Tools.ApplyPatch.Parser`'s; how hunks are
  located, and what is preserved (line endings, a byte-order mark, a missing
  final newline), is `Lemieux.Tools.ApplyPatch.Applier`'s.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool.FileState
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.ApplyPatch.Applier
  alias Lemieux.Tools.ApplyPatch.Parser
  alias Lemieux.Tools.FileOps
  alias Lemieux.Tools.Search.Scope

  @impl Lemieux.Tool
  def name, do: "apply_patch"

  @impl Lemieux.Tool
  def description do
    """
    Edit files with a patch. The input is the entire patch:

    *** Begin Patch
    *** Update File: path/to/file.py
    @@ def example():
    -    return 1
    +    return 2
    *** End Patch

    Operations, any number per patch:
    *** Add File: <path> — then every line of the new file prefixed with +
    *** Delete File: <path>
    *** Update File: <path> — optionally followed by *** Move to: <new path>,
    then hunks. Each hunk starts with @@ (optionally followed by a line to
    find first, such as a function signature), then lines prefixed with a
    space (unchanged context), - (remove) or + (add). Include about three
    lines of context before and after each change so the location is
    unambiguous. *** End of File marks a hunk at the end of the file.

    Paths are relative to the working directory. Read a file before
    updating it and copy context lines exactly. Nothing is written unless
    every hunk applies.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "input" => %{
          "type" => "string",
          "description" => "The entire patch, from *** Begin Patch to *** End Patch."
        }
      },
      "required" => ["input"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "write", resource_types: ["file"]},
      runtime: %{concurrency: %{class: "exclusive"}}
    }
  end

  @doc """
  The paths a patch would touch, destinations of moves included.

  For policy that must act before a patch runs: `Lemieux.Extensions.Checkpoints`
  saves each of these files' current contents first.
  """
  @spec paths(input :: String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def paths(input) do
    with {:ok, operations} <- Parser.parse(input), do: {:ok, Parser.paths(operations)}
  end

  @impl Lemieux.Tool
  def run(%{"input" => input}, context) when is_binary(input) do
    with {:ok, operations} <- parse(input),
         {:ok, plan} <- plan(context, operations) do
      execute(plan)
    end
  end

  # Some models put the patch under the name of the shell argument they learned.
  def run(%{"patch" => input}, context) when is_binary(input),
    do: run(%{"input" => input}, context)

  def run(_args, _context), do: {:error, "apply_patch needs input: the entire patch text"}

  defp parse(input) do
    case Parser.parse(input) do
      {:ok, operations} -> {:ok, operations}
      {:error, reason} -> {:error, "apply_patch: #{reason}"}
    end
  end

  ## planning, in memory

  # `files` is each touched path's state as the patch has left it so far:
  # `{:file, contents}` or `:absent`. `original` is the same before the patch,
  # which is what decides whether a path was added, modified or deleted.
  # `stale` lists files the session had seen in another state, for the note.
  defp plan(context, operations) do
    initial = %{
      context: context,
      environment: Environment.from_context(context),
      cwd: context.cwd,
      files: %{},
      original: %{},
      moves: %{},
      stale: []
    }

    Enum.reduce_while(operations, {:ok, initial}, fn operation, {:ok, plan} ->
      case step(plan, normalize(operation, context.cwd)) do
        {:ok, plan} -> {:cont, {:ok, plan}}
        {:error, reason} -> {:halt, {:error, "apply_patch: #{reason}. No files were changed."}}
      end
    end)
  end

  defp normalize(%{path: path} = operation, cwd) do
    operation = %{operation | path: Scope.relativize(cwd, path)}

    case operation do
      %{move_to: to} when is_binary(to) -> %{operation | move_to: Scope.relativize(cwd, to)}
      operation -> operation
    end
  end

  defp step(plan, %{type: :add, path: path, lines: lines}) do
    with {:ok, plan, :absent} <- current(plan, path, :exists) do
      {:ok, put(plan, path, {:file, Applier.new_file(lines)})}
    end
  end

  defp step(plan, %{type: :delete, path: path}) do
    with {:ok, plan, {:file, _contents}} <- current(plan, path, :missing),
         :ok <- seen_before_deleting(plan, path) do
      {:ok, put(plan, path, :absent)}
    end
  end

  defp step(plan, %{type: :update, path: path, move_to: move_to, chunks: chunks}) do
    with {:ok, plan, {:file, contents}} <- current(plan, path, :missing),
         {:ok, updated} <- Applier.update(contents, chunks, path) do
      plan |> note_stale(path) |> move(path, move_to, updated)
    end
  end

  # The rule `write` applies, for the one operation that discards a whole file:
  # deleting a file the session never read, or one that changed since it did,
  # throws away content the model has not seen. A file this patch created or
  # changed first is the model's own.
  defp seen_before_deleting(plan, path) do
    original = Map.fetch!(plan.original, path)

    if Map.fetch!(plan.files, path) == original,
      do: seen(original, FileState.seen(plan.context, path), path),
      else: :ok
  end

  defp seen(original, seen, path) do
    case {original, seen} do
      {_original, :untracked} ->
        :ok

      {:absent, _seen} ->
        :ok

      {{:file, _contents}, :unseen} ->
        {:error,
         "#{path} has not been read in this session; read it before deleting it, so that " <>
           "nothing you have not seen is thrown away"}

      {{:file, contents}, {:ok, fingerprint}} ->
        if fingerprint == FileState.fingerprint(contents),
          do: :ok,
          else:
            {:error,
             "#{path} has changed since this session last read or wrote it; read it again " <>
               "before deleting it"}
    end
  end

  # The rule `edit` applies: a hunk only changes lines its context matched in
  # the file as it is now, so an update proceeds, and says when the file is no
  # longer what the session last saw.
  defp note_stale(plan, path) do
    with {:file, original} <- Map.fetch!(plan.original, path),
         {:ok, fingerprint} <- FileState.seen(plan.context, path),
         false <- fingerprint == FileState.fingerprint(original) do
      %{plan | stale: Enum.uniq([path | plan.stale])}
    else
      _fresh_unseen_or_untracked -> plan
    end
  end

  defp move(plan, path, nil, updated), do: {:ok, put(plan, path, {:file, updated})}
  defp move(plan, path, path, updated), do: {:ok, put(plan, path, {:file, updated})}

  defp move(plan, path, destination, updated) do
    with {:ok, plan, :absent} <- current(plan, destination, :exists) do
      plan = plan |> put(destination, {:file, updated}) |> put(path, :absent)
      {:ok, %{plan | moves: Map.put(plan.moves, destination, path)}}
    end
  end

  defp put(plan, path, state), do: %{plan | files: Map.put(plan.files, path, state)}

  # Reads a path the patch has not touched yet. `refuse` is the state that makes
  # the operation impossible: adding over an existing file, or changing one
  # that is not there.
  defp current(plan, path, refuse) do
    with {:ok, plan, state} <- lookup(plan, path) do
      case {state, refuse} do
        {{:file, _contents}, :exists} ->
          {:error, "cannot add #{path}: it already exists (use *** Update File to change it)"}

        {:absent, :missing} ->
          {:error, "#{path}: no such file"}

        _possible ->
          {:ok, plan, state}
      end
    end
  end

  defp lookup(%{files: files} = plan, path) when is_map_key(files, path),
    do: {:ok, plan, Map.fetch!(files, path)}

  defp lookup(plan, path) do
    state =
      case Environment.read_file(plan.environment, plan.cwd, path) do
        {:ok, contents} -> {:ok, {:file, contents}}
        {:error, :enoent} -> {:ok, :absent}
        {:error, :outside_worktree} -> {:error, "#{path}: is outside the working directory"}
        {:error, :eisdir} -> {:error, "#{path}: is a directory"}
        {:error, reason} -> {:error, "#{path}: #{format(reason)}"}
      end

    with {:ok, state} <- state do
      {:ok,
       %{
         plan
         | files: Map.put(plan.files, path, state),
           original: Map.put(plan.original, path, state)
       }, state}
    end
  end

  ## writing

  defp execute(plan) do
    changes = changes(plan)
    {writes, deletes} = Enum.split_with(changes, &match?({_kind, _path, {:file, _}}, &1))

    result =
      Enum.reduce_while(writes ++ deletes, {:ok, []}, fn change, {:ok, done} ->
        case perform(plan, change) do
          :ok -> {:cont, {:ok, [change | done]}}
          {:error, reason} -> {:halt, {:error, change, reason, Enum.reverse(done)}}
        end
      end)

    case result do
      {:ok, done} -> {:ok, success(Enum.reverse(done), plan)}
      {:error, change, reason, done} -> {:error, partial(change, reason, done, plan)}
    end
  end

  # What actually differs from the start, per path, in path order: adding and
  # then deleting a file within one patch changes nothing on disk.
  defp changes(plan) do
    plan.files
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {path, final} ->
      case {Map.fetch!(plan.original, path), final} do
        {same, same} -> []
        {:absent, {:file, _contents} = file} -> [{:added, path, file}]
        {{:file, _before}, {:file, _after} = file} -> [{:modified, path, file}]
        {{:file, _before}, :absent} -> [{:deleted, path, :absent}]
      end
    end)
  end

  # What was written is what the session has now seen of it, as for `write`
  # and `edit`, so a later `write` of the same file is not refused.
  defp perform(plan, {_kind, path, {:file, contents}}) do
    case Environment.write_file(plan.environment, plan.cwd, path, contents) do
      {:ok, _disposition} ->
        FileState.record(plan.context, path, FileState.fingerprint(contents))

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp perform(plan, {:deleted, path, :absent}),
    do: FileOps.delete(plan.environment, plan.cwd, path)

  defp success(done, plan) do
    lines = Enum.map(done, &change_line(&1, plan))

    text =
      case lines do
        [] -> "Success. The patch left every file as it was."
        lines -> "Success. Updated the following files:\n" <> Enum.join(lines, "\n")
      end

    Result.new(text <> stale_notes(plan.stale), metadata: summary(done))
  end

  defp stale_notes([]), do: ""

  defp stale_notes(paths) do
    Enum.map_join(paths |> Enum.reverse(), "", fn path ->
      "\nNote: #{path} changed since this session last read or wrote it. The patch matched " <>
        "what is there now; read the file before relying on anything else in it."
    end)
  end

  defp partial({_kind, path, _state}, reason, done, plan) do
    changed =
      case done do
        [] ->
          "No files were changed."

        done ->
          "These were changed before it: " <> Enum.map_join(done, ", ", &change_line(&1, plan))
      end

    "apply_patch: could not write #{path}: #{format(reason)}. #{changed}"
  end

  defp change_line({:added, path, _state}, plan) do
    case Map.fetch(plan.moves, path) do
      {:ok, from} -> "A #{path} (moved from #{from})"
      :error -> "A #{path}"
    end
  end

  defp change_line({:modified, path, _state}, _plan), do: "M #{path}"
  defp change_line({:deleted, path, _state}, _plan), do: "D #{path}"

  defp summary(done) do
    Enum.reduce(done, %{"added" => [], "modified" => [], "deleted" => []}, fn {kind, path, _state},
                                                                              summary ->
      Map.update!(summary, Atom.to_string(kind), &(&1 ++ [path]))
    end)
  end

  defp format(:outside_worktree), do: "is outside the working directory"
  defp format(reason) when is_atom(reason), do: reason |> :file.format_error() |> to_string()
  defp format(reason), do: inspect(reason)
end
