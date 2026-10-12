defmodule Lemieux.Conversation.Command.Review do
  @moduledoc """
  `/review [working | staged | commit REF | range BASE..HEAD | end]`.

  Captures the selected diff through the checkpoint's private Git directory,
  with no repository hooks, filters, external diff drivers or network fetch.
  The stored target and digest make later findings attributable. The review
  remains read-only until the person explicitly ends it.
  """
  @behaviour Lemieux.Conversation.Command

  alias Lemieux.Checkpoint.Git.Repository
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Extensions.Workflow

  @impl true
  def spec,
    do: %{
      name: "review",
      description: "review working, staged, commit or range changes read-only",
      accepts_arguments?: true,
      action: {:review, "working"},
      actions: [{:review, "working"}]
    }

  @impl true
  def parse(_arguments, %{busy?: true}), do: Command.wait()

  def parse(arguments, _conversation),
    do: [{:review, if(String.trim(arguments) == "", do: "working", else: String.trim(arguments))}]

  @impl true
  def perform(acc, %Dispatch{session: nil} = host, _effect),
    do: Dispatch.say(acc, host, "no session is running")

  def perform(acc, host, {:review, target}) do
    session = host.session
    cwd = Dispatch.cwd(host)
    Dispatch.run(acc, host, fn -> begin_review(session, cwd, target) end)
  end

  defp begin_review(session, _cwd, "end") do
    case Workflow.enter(session, "idle") do
      {:ok, _document} -> {:said, "review ended"}
      error -> {:said, "could not end review: #{inspect(error)}"}
    end
  end

  defp begin_review(session, cwd, target) do
    with {:ok, selected} <- capture(cwd, target),
         {:ok, _document} <- Workflow.enter(session, "review", Map.delete(selected, "diff")) do
      {:send_prompt,
       "Review #{selected["target"]} read-only. Report only actionable findings with severity, file, line, explanation and evidence; say when no findings were observed. This diff excludes untracked file contents; read referenced files as needed.\n\n" <>
         selected["diff"], "reviewing #{target}; write and shell tools are restricted"}
    else
      error -> {:said, "could not start review: #{inspect(error)}"}
    end
  end

  @doc "Captures a bounded selected diff, with resolved commit identities."
  @spec capture(cwd :: Path.t(), target :: String.t()) :: {:ok, map()} | {:error, term()}
  def capture(cwd, target) do
    case Repository.locate(cwd) do
      {:ok, repository} ->
        Repository.with_private(repository, [index: :copy, refs: true], &captured(&1, target))

      :skipped ->
        {:error, :not_a_git_worktree}

      error ->
        error
    end
  end

  defp captured(private, target) do
    with {:ok, revisions, arguments} <- selection(private, target),
         {:ok, diff} <- Repository.run(private, arguments),
         true <- byte_size(diff) <= 48_000 do
      {:ok,
       %{
         "target" => target,
         "revisions" => revisions,
         "diff" => diff,
         "diff_sha256" => Base.encode16(:crypto.hash(:sha256, diff), case: :lower)
       }}
    else
      false -> {:error, :diff_too_large_select_a_smaller_range}
      error -> error
    end
  end

  defp selection(private, target) when target in ~w(working staged) do
    with {:ok, head} <- resolve(private, "HEAD") do
      args = if target == "staged", do: ["--cached"], else: []
      {:ok, [head], diff_args() ++ args ++ [head, "--"]}
    end
  end

  defp selection(private, "commit " <> ref) do
    with {:ok, commit} <- resolve(private, ref) do
      {:ok, [commit],
       [
         "diff-tree",
         "--root",
         "--no-commit-id",
         "-p",
         "--no-ext-diff",
         "--no-textconv",
         commit,
         "--"
       ]}
    end
  end

  defp selection(private, "range " <> range) do
    with [base, head] <- String.split(range, ".."),
         {:ok, base} <- resolve(private, base),
         {:ok, head} <- resolve(private, head) do
      {:ok, [base, head], diff_args() ++ [base, head, "--"]}
    else
      _error -> {:error, :invalid_range}
    end
  end

  defp selection(_private, _target), do: {:error, :use_working_staged_commit_or_range}
  defp diff_args, do: ["diff", "--no-ext-diff", "--no-textconv", "--no-renames"]

  defp resolve(private, ref) do
    case Repository.run(private, ["rev-parse", "--verify", "--end-of-options", ref <> "^{commit}"]) do
      {:ok, output} -> {:ok, String.trim(output)}
      _error -> {:error, :unknown_commit}
    end
  end
end
