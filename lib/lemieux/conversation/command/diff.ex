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
  @spec diff(environment :: Lemieux.Environment.t(), cwd :: Path.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def diff(environment, cwd) do
    with {:ok, result} <- Shell.run(environment, @script, cwd, keep_bytes: 400_000) do
      {:ok, render(result)}
    end
  end

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
