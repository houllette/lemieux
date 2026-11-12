defmodule Lemieux.CLI.BugReport do
  @moduledoc """
  A small, reviewed bug report, separate from conversation instructions.

  Reports include only allowlisted diagnostic provenance and stack locations,
  never tool arguments, output, exception messages, a conversation excerpt or
  host/account metadata. Those can contain arbitrary secrets. Full evidence
  stays local in the transcript. A user-authored summary is scrubbed as an
  additional precaution and still requires review.

  Preparation exports a private Markdown draft and records anchored bug
  feedback in the existing ledger. Submission rechecks the reviewed digest;
  edits produce a fresh sanitized preview before another explicit submission.
  No model or account-authorization flow is involved.
  """
  alias Lemieux.CLI.Feedback
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Contract
  alias Lemieux.Diagnostic
  alias Lemieux.ID
  alias Lemieux.Tool

  @max_bytes 16_384
  @title "Bug report: unexpected Lemieux behavior"
  @repo "houllette/lemieux"

  @doc "Prepares the latest errored turn, or the summary at :turn_seq, for review."
  @spec prepare(snapshot :: map(), summary :: String.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(snapshot, summary, opts \\ []) do
    with {:ok, entries} <- select_errors(snapshot.entries, opts[:turn_seq]),
         [anchor | _] <- entries,
         body = markdown(entries, summary),
         {:ok, path} <- export(body, opts) do
      submission = %{
        text: body,
        session_id: snapshot.id,
        entry_id: anchor.id,
        type: :bug,
        scope: :project,
        durability: :one_off
      }

      {feedback_id, notice} =
        case Feedback.capture(submission, opts) do
          {:ok, feedback} ->
            {feedback.id, nil}

          {:error, _reason} ->
            {nil,
             "The local feedback ledger could not be written; the draft export remains available."}
        end

      {:ok,
       %{
         path: path,
         body: body,
         sha256: Contract.sha256(body),
         feedback_id: feedback_id,
         notice: notice
       }}
    else
      [] -> {:error, "no classified Lemieux errors in that turn"}
      error -> error
    end
  end

  defp select_errors(entries, seq) do
    summary =
      entries
      |> Enum.reverse()
      |> Enum.find(fn entry ->
        entry.type == :extension_state and entry.payload["namespace"] == "lemieux.errors" and
          (is_nil(seq) or entry.seq == seq)
      end)

    case summary do
      nil ->
        {:error, "no completed error turn found; use /feedback for ordinary feedback"}

      summary ->
        ids = summary.payload["value"]["error_ids"]

        {:ok,
         Enum.filter(entries, fn entry ->
           diagnostic = Diagnostic.from_payload(entry.payload)
           diagnostic && diagnostic["id"] in ids
         end)
         |> Enum.uniq_by(& &1.payload["diagnostic"]["id"])}
    end
  end

  @doc "Checks the exact reviewed draft and submits only after explicit invocation."
  @spec submit(report :: map(), opts :: keyword()) ::
          {:ok, String.t()} | {:preview, map()} | {:error, term()}
  def submit(report, opts \\ []) do
    with {:ok, %{type: :regular} = stat} <- File.lstat(report.path),
         true <- stat.size <= @max_bytes,
         {:ok, bytes} <- File.read(report.path),
         true <- byte_size(bytes) <= @max_bytes do
      body = sanitize(bytes)

      checked_submit(report, body, bytes, opts)
    else
      false ->
        {:error, "draft exceeds the 16 KiB report limit; edit it before submitting"}

      {:error, _reason} ->
        {:error, "could not read the draft; the prepared report remains available"}

      _not_regular ->
        {:error, "the draft must be a regular file; the prepared report remains available"}
    end
  end

  defp checked_submit(report, body, bytes, opts) do
    if body == bytes and Contract.sha256(body) == report.sha256 do
      run = Keyword.get(opts, :submit, fn body -> github(body, opts) end)
      run.(body)
    else
      with :ok <- File.write(report.path, body) do
        {:preview, %{report | body: body, sha256: Contract.sha256(body)}}
      end
    end
  end

  defp github(body, opts) do
    case Keyword.get_lazy(opts, :github_command, fn -> System.find_executable("gh") end) do
      nil ->
        {:error, "GitHub CLI is unavailable. The draft is ready to copy into a repository issue."}

      executable ->
        # Freeze the checked bytes into a new private file. gh must never read
        # the editable draft again after its digest has been approved.
        submit_file(executable, body)
    end
  end

  defp submitted({:ok, {output, 0}}) do
    case Regex.run(~r{https://github\.com/houllette/lemieux/issues/\d+}, output) do
      [url] -> {:ok, url}
      _unknown -> {:error, "GitHub returned no issue URL; check the repository before retrying"}
    end
  end

  defp submitted(_failure),
    do:
      {:error,
       "GitHub submission did not return an issue URL. The draft is preserved; check the repository before retrying."}

  defp submit_file(executable, body) do
    root = Path.join(System.tmp_dir!(), "lmx-bug-" <> ID.generate())
    path = Path.join(root, "body.md")

    with :ok <- File.mkdir(root), :ok <- File.chmod(root, 0o700) do
      try do
        File.write!(path, "", [:exclusive])
        File.chmod!(path, 0o600)
        File.write!(path, body)

        run_submission(executable, path)
      after
        File.rm_rf(root)
      end
    end
  rescue
    _error -> {:error, "Could not start GitHub submission. The reviewed draft is preserved."}
  end

  defp run_submission(executable, path) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task =
        Task.Supervisor.async_nolink(supervisor, fn ->
          System.cmd(
            executable,
            ["issue", "create", "--repo", @repo, "--title", @title, "--body-file", path],
            stderr_to_stdout: true,
            env: [{"GH_PROMPT_DISABLED", "1"}, {"GIT_TERMINAL_PROMPT", "0"}]
          )
        end)

      submitted(Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill))
    after
      Supervisor.stop(supervisor)
    end
  end

  defp export(body, opts) do
    root =
      Keyword.get_lazy(opts, :bug_reports_dir, fn ->
        case opts[:sessions_dir] do
          dir when is_binary(dir) -> Path.join(Path.dirname(Path.expand(dir)), "bug-reports")
          _default -> Path.expand("~/.lmx/bug-reports")
        end
      end)

    path = Path.join(root, "bug-#{ID.generate()}.md")

    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         {:ok, file} <- File.open(path, [:write, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- IO.binwrite(file, body), do: {:ok, path}
      after
        File.close(file)
      end
    end
  end

  defp markdown(entries, summary) do
    version = Application.spec(:lemieux, :vsn) |> to_string()

    diagnostics =
      Enum.map(entries, fn entry ->
        diagnostic = entry.payload["diagnostic"]

        %{
          "component" => safe_component(diagnostic["component"]),
          "category" => "internal",
          "stack" => stack(diagnostic["details"])
        }
      end)

    ("## What happened\n\n" <>
       if(String.trim(summary) == "",
         do: "An internal Lemieux operation failed. Add reproduction steps here.",
         else: summary
       ) <>
       "\n\n## Diagnostics\n\nLemieux #{version}; #{length(diagnostics)} distinct internal error(s).\n\n```json\n" <>
       JSON.encode!(diagnostics) <>
       "\n```\n\nNo conversation, tool input/output, credentials or host metadata are attached.\n")
    |> sanitize()
    |> Tool.truncate(@max_bytes - 256)
  end

  defp safe_component(component) when component in ["tool", "runtime", "hook", "presentation"],
    do: component

  defp safe_component(_component), do: "runtime"

  defp stack([_exception, frames]) when is_list(frames) do
    frames
    |> Enum.take(8)
    |> Enum.flat_map(fn
      ["Elixir.Lemieux." <> module, function, arity, _location]
      when is_binary(function) and is_integer(arity) ->
        [%{"module" => "Lemieux." <> module, "function" => function, "arity" => arity}]

      _frame ->
        []
    end)
  end

  defp stack(_details), do: []

  @doc "Scrubs common secret, identifier and path forms from a user-edited draft."
  @spec sanitize(text :: String.t()) :: String.t()
  def sanitize(text) do
    text
    |> Sanitize.text()
    |> String.replace(
      ~r/(?im)^.*\b(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|account[_-]?id|tenant[_-]?id|hostname)\b["']?\s*[=:].*$/u,
      "[redacted credential or identifier]"
    )
    |> String.replace(
      ~r/(?i)\b(?:authorization|api[_-]?key|access[_-]?token|refresh[_-]?token|password|secret|cookie|account[_-]?id|tenant[_-]?id)\s*[=:]\s*[^\s,;]+/u,
      "[redacted credential or identifier]"
    )
    |> String.replace(~r/(?i)\bBearer\s+[^\s,;]+/u, "Bearer [redacted]")
    |> String.replace(~r/\b(?:sk-|gh[pousr]_|github_pat_)[A-Za-z0-9_-]+/u, "[redacted token]")
    |> String.replace(
      ~r/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/u,
      "[redacted token]"
    )
    |> String.replace(
      ~r{(?:[A-Za-z]:\\|(?<![\w:])/)[^\s`"<>]+}u,
      "[private path]"
    )
    |> String.replace(~r/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/u, "[email]")
    |> String.replace(~r{https?://[^\s`<>]+}u, "[URL omitted]")
  end
end
