defmodule Lemieux.Conversation.Command.Diff do
  @moduledoc """
  `/diff`: what changed in the working tree since the last commit.

  The question a person asks after every turn that edited files — what did it
  actually do? — answered without leaving the conversation. It is git's
  answer, run through the session's environment like `!command` (see
  `Lemieux.Conversation.Shell`), so it shows the files the agent touched
  wherever they are. One command rather than three calls, because each
  call is a process start, and a script can fall back to the empty tree in a
  repository that has no commit yet instead of failing on `HEAD`.

  Bounded: the summary, then the diff up to 300 lines, then the untracked
  files. A long diff says how much more there is and where to see it; it is
  read on a screen, not paged.
  """

  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Conversation.Shell
  alias Lemieux.Environment
  alias Lemieux.Tools.Bash

  @max_lines 300
  @max_untracked 30
  @section "__lmx_diff_section__"
  @not_git "__lmx_not_a_git_repository__"

  @script """
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo #{@not_git}; exit 0; }
  if git rev-parse --verify -q HEAD >/dev/null 2>&1; then base=HEAD; \
  else base=$(git hash-object -t tree /dev/null); fi
  git -c core.fsmonitor= --no-pager diff --no-color --no-ext-diff --no-textconv --stat "$base" --
  echo #{@section}
  git -c core.fsmonitor= --no-pager diff --no-color --no-ext-diff --no-textconv "$base" --
  echo #{@section}
  git -c core.fsmonitor= --no-pager status --porcelain=v1 --untracked-files=normal
  """

  # The script runs as an ordinary command in the session's environment
  # (inside the sandbox when there is one), in a repository the agent's
  # commands can write. The flags above keep the repository's fsmonitor,
  # external diff driver and textconv programs from running when a person
  # types /diff (an empty core.fsmonitor turns it off on every git version;
  # before git 2.36 the setting is a hook path, so "false" would name a
  # program); git has no switch for a clean filter, which runs here as it
  # would for any git command the agent runs (SECURITY.md says so).

  @impl Lemieux.Conversation.Command
  def spec,
    do: %{name: "diff", description: "show what changed in the working tree", action: :diff}

  @impl Lemieux.Conversation.Command
  def parse(_arguments, _conversation), do: [:diff]

  @impl Lemieux.Conversation.Command
  def perform(acc, host, :diff) do
    environment = Dispatch.environment(host)

    Dispatch.run(acc, host, fn ->
      {:diff_result, diff(environment, Dispatch.cwd(host))}
    end)
  end

  @doc """
  The working tree's changes in `cwd`, as the text `/diff` shows.

  Public so a host can put the same answer somewhere else — and so it can be
  tested against a real repository without a front end.
  """
  @spec diff(environment :: Environment.t(), cwd :: Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def diff(environment, cwd) do
    with {:ok, result} <- Shell.run(environment, @script, cwd, keep_bytes: 400_000) do
      {:ok, render(result)}
    end
  end

  @doc """
  Changed files for an interactive host, including renames and untracked files.

  Git's NUL framing is retained until paths are decoded: splitting on lines
  makes a file containing a newline into two files. Collection is bounded and
  rejects incomplete output rather than presenting a truncated path as real.
  The environment is the same boundary the session's tools use.
  """
  @spec files(environment :: Environment.t(), cwd :: Path.t()) ::
          {:ok, map()} | {:error, String.t()}
  def files(environment, cwd) do
    command = "git -c core.fsmonitor= --no-pager status --porcelain=v1 -z --untracked-files=all"

    with {:ok, events} <-
           Environment.run(environment, command,
             cwd: cwd,
             timeout_ms: 120_000,
             max_output_bytes: 200_000,
             env: Bash.non_interactive_env()
           ),
         {:ok, output} <- status_output(events),
         {:ok, entries} <- status_entries(String.split(output, <<0>>, trim: true), []) do
      {:ok, %{files: Enum.take(entries, 256), omitted: max(length(entries) - 256, 0)}}
    else
      _failed ->
        {:error,
         "could not list changes · /diff needs a git working tree and complete status output"}
    end
  end

  @doc "A bounded per-file patch, with literal pathspecs and no external diff drivers."
  @spec preview(environment :: Environment.t(), cwd :: Path.t(), file :: map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def preview(environment, cwd, %{path: path, status: status} = file) do
    if safe_path?(path) and safe_path?(Map.get(file, :previous, path)) do
      paths = [path, Map.get(file, :previous)] |> Enum.reject(&is_nil/1) |> Enum.uniq()
      quoted = Enum.map_join(paths, " ", &quote_path/1)

      flags =
        "git --literal-pathspecs -C \"$root\" -c core.fsmonitor= --no-pager diff --no-color --no-ext-diff --no-textconv"

      command =
        if status == "??" do
          flags <> " --no-index -- /dev/null " <> quote_path(path)
        else
          "if git rev-parse --verify -q HEAD >/dev/null 2>&1; then base=HEAD; else base=$(git hash-object -t tree /dev/null); fi\n" <>
            flags <> " \"$base\" -- " <> quoted
        end

      command = "root=$(git rev-parse --show-toplevel) || exit 2\n" <> command

      with {:ok, result} <- Shell.run(environment, command, cwd, keep_bytes: 100_000),
           do: preview_result(result)
    else
      {:error, "could not read an invalid repository path"}
    end
  end

  defp preview_result(%{outcome: :exited, exit_status: exit, output: output})
       when exit in [0, 1] do
    text =
      if String.trim(output) == "",
        do: "No patch for this file (its status may have changed).",
        else: output

    {:ok, bounded(text)}
  end

  defp preview_result(result), do: {:error, "could not read file diff: #{Shell.ending(result)}"}

  defp status_output(events) do
    events
    |> Enum.reduce({[], 0, false}, fn
      {:data, bytes}, {parts, size, ok?} when size + byte_size(bytes) <= 200_000 ->
        {[bytes | parts], size + byte_size(bytes), ok?}

      {:exit_status, 0}, {parts, size, _ok?} ->
        {parts, size, true}

      _failure, {parts, _size, _ok?} ->
        {parts, 200_001, false}
    end)
    |> then(fn
      {parts, size, true} when size <= 200_000 ->
        output = parts |> Enum.reverse() |> IO.iodata_to_binary()

        if String.valid?(output) and (output == "" or String.ends_with?(output, <<0>>)),
          do: {:ok, output},
          else: :error

      _failed ->
        :error
    end)
  end

  defp status_entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp status_entries([<<x, y, 32, path::binary>> | rest], acc) when path != "" do
    status = <<x, y>>

    if x in ~c"RC" or y in ~c"RC" do
      case rest do
        [previous | rest] ->
          status_entries(rest, [%{path: path, status: status, previous: previous} | acc])

        [] ->
          :error
      end
    else
      status_entries(rest, [%{path: path, status: status} | acc])
    end
  end

  defp status_entries(_unexpected, _acc), do: :error

  defp safe_path?(path),
    do:
      is_binary(path) and path != "" and Path.type(path) == :relative and
        not String.contains?(path, <<0>>) and ".." not in Path.split(path)

  defp quote_path(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  defp render(%{outcome: :exited, output: output}) do
    if String.contains?(output, @not_git),
      do: "not a git repository · /diff shows a git working tree's changes",
      else: output |> String.split(@section <> "\n") |> sections()
  end

  defp render(result), do: "could not read the diff: #{Shell.ending(result)}"

  defp sections([stat, diff, status]) do
    untracked =
      status
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn
        "?? " <> path -> [path]
        _tracked -> []
      end)

    case {String.trim(diff), untracked} do
      {"", []} -> "no changes in the working tree"
      {diff, untracked} -> Enum.join(parts(stat, diff, untracked), "\n\n")
    end
  end

  defp sections(_unexpected), do: "could not read the diff: git answered in an unexpected shape"

  defp parts(stat, diff, untracked) do
    [summary(stat), bounded(diff), untracked_files(untracked)]
    |> Enum.reject(&(&1 == ""))
  end

  defp summary(stat) do
    case String.trim(stat) do
      "" -> ""
      stat -> "changes since the last commit:\n" <> stat
    end
  end

  defp bounded(""), do: ""

  defp bounded(diff) do
    lines = String.split(diff, "\n")

    case length(lines) - @max_lines do
      more when more > 0 ->
        Enum.join(Enum.take(lines, @max_lines), "\n") <>
          "\n… #{more} more lines · run git diff to see them all"

      _fits ->
        diff
    end
  end

  defp untracked_files([]), do: ""

  defp untracked_files(paths) do
    shown = Enum.take(paths, @max_untracked)
    more = length(paths) - length(shown)
    listed = Enum.map_join(shown, "\n", &("  " <> &1))
    rest = if more > 0, do: "\n  … and #{more} more", else: ""

    "untracked:\n" <> listed <> rest
  end
end
