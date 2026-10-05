defmodule Lemieux.Feedback.CaseDraft do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A frozen, reviewable benchmark case derived from verifiable feedback.

  `create/4` copies the starting repository before returning a task and writes
  a draft record beside it. It never modifies the approved corpus. A human (or
  later an independently authorized curator) must inspect secrets, confirm the
  grader reproduces the observed failure, and explicitly move the case into a
  corpus before an optimizer may see it.

  The copy leaves out secret-shaped files (`Lemieux.Benchmark.SecretFiles`
  says which) and records each one in `skipped_files` and in the draft's
  `"skipped"` list, so a reviewer sees what is missing rather than a fixture
  that silently differs from the workspace. Copying first and deleting after
  would put the key on disk inside a directory meant to be committed; the
  files are never copied at all. A case that genuinely needs one gets it back
  by hand, and promotion then has to be told so (see
  `Lemieux.Benchmark.Corpus.Promote`).
  """

  alias Lemieux.Benchmark.SecretFiles
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.Feedback

  @version 1

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          feedback_id: String.t(),
          fixture_digest: String.t(),
          task: Task.t(),
          manifest_fragment: map(),
          provenance: map(),
          review_checklist: [String.t()],
          skipped_files: [Path.t()],
          record_path: Path.t(),
          status: :draft
        }

  @enforce_keys [
    :id,
    :feedback_id,
    :fixture_digest,
    :task,
    :manifest_fragment,
    :provenance,
    :record_path
  ]
  defstruct schema_version: @version,
            id: nil,
            feedback_id: nil,
            fixture_digest: nil,
            task: nil,
            manifest_fragment: nil,
            provenance: nil,
            review_checklist: [
              "review fixture for secrets",
              "confirm grader fails on the frozen control",
              "confirm acceptance criteria match the feedback"
            ],
            skipped_files: [],
            record_path: nil,
            status: :draft

  @doc """
  Copies a fixture, leaving out secret-shaped files, and emits an unapproved
  case draft.
  """
  @spec create(
          feedback :: Feedback.t(),
          source_dir :: Path.t(),
          output_dir :: Path.t(),
          opts :: keyword()
        ) :: {:ok, t()} | {:error, term()}
  def create(%Feedback{} = feedback, source_dir, output_dir, opts)
      when is_binary(source_dir) and is_binary(output_dir) and is_list(opts) do
    with :ok <- eligible(feedback),
         {:ok, prompt} <- required_string(opts, :prompt),
         {:ok, verifier} <- verifier(opts),
         :ok <- source_directory(source_dir),
         :ok <- separate_paths(source_dir, output_dir) do
      id = Keyword.get(opts, :id, "case_" <> String.trim_leading(feedback.id, "fb_"))
      root = Path.join(output_dir, id)
      fixture = Path.join(root, "fixture")

      with :ok <- unused(root),
           :ok <- File.mkdir_p(root),
           {:ok, skipped} <- SecretFiles.copy(source_dir, fixture),
           {:ok, snapshot} <- WorkspaceSnapshot.capture(fixture),
           {:ok, task} <- task(id, feedback.id, prompt, fixture, verifier, opts) do
        finalize(feedback, id, root, task, snapshot, skipped)
      end
    end
  end

  defp finalize(feedback, id, root, task, snapshot, skipped) do
    record_path = Path.join(root, "draft.json")

    draft =
      %__MODULE__{
        id: id,
        feedback_id: feedback.id,
        fixture_digest: snapshot_digest(snapshot),
        task: task,
        manifest_fragment: manifest_fragment(task, id),
        provenance: feedback.provenance,
        record_path: record_path
      }
      |> with_skipped(skipped)

    case File.write(record_path, JSON.encode!(record(draft, feedback))) do
      :ok -> {:ok, draft}
      {:error, reason} -> {:error, {:write_draft, reason}}
    end
  end

  defp with_skipped(draft, []), do: draft

  defp with_skipped(draft, skipped) do
    # `lmx feedback draft-case` prints the checklist, so the advice names the
    # CLI flag beside the option a host calling `Promote` passes.
    item =
      "left out secret-shaped files (#{Enum.join(skipped, ", ")}): restore one only if the " <>
        "case needs it and it holds nothing real, then promote with --allow-secret-files " <>
        "(allow_secret_files: true from Elixir)"

    %{draft | skipped_files: skipped, review_checklist: [item | draft.review_checklist]}
  end

  defp eligible(%Feedback{} = feedback) do
    case Feedback.verifiability_class(feedback) do
      class when class in [:mechanical, :environmental] -> :ok
      class -> {:error, {:not_case_eligible, class}}
    end
  end

  defp required_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _invalid -> {:error, {:missing_case_option, key}}
    end
  end

  defp verifier(opts) do
    case Keyword.get(opts, :verifier) do
      command when is_list(command) and command != [] ->
        if Enum.all?(command, &is_binary/1),
          do: {:ok, command},
          else: {:error, :invalid_verifier}

      _invalid ->
        {:error, :invalid_verifier}
    end
  end

  defp source_directory(path) do
    if File.dir?(path), do: :ok, else: {:error, {:source_not_directory, path}}
  end

  defp separate_paths(source, output) do
    source = Path.expand(source)
    output = Path.expand(output)

    if output == source or String.starts_with?(output, source <> "/"),
      do: {:error, :draft_inside_source},
      else: :ok
  end

  defp unused(path) do
    if File.exists?(path), do: {:error, {:draft_exists, path}}, else: :ok
  end

  defp task(id, feedback_id, prompt, fixture, verifier, opts) do
    task = %{
      "id" => id,
      "prompt" => prompt,
      "cwd" => ".",
      "timeout_ms" => Keyword.get(opts, :timeout_ms, :timer.minutes(10)),
      "grader" => %{
        "command" => verifier,
        "timeout_ms" => Keyword.get(opts, :grader_timeout_ms, :timer.minutes(5))
      },
      "metadata" => %{
        "status" => "draft",
        "feedback_id" => feedback_id
      }
    }

    Task.from_map(task, fixture)
  end

  defp manifest_fragment(task, id) do
    %{
      "id" => id,
      "prompt" => task.prompt,
      "cwd" => "fixture",
      "timeout_ms" => task.timeout_ms,
      "grader" => %{
        "command" => task.grader.command,
        "timeout_ms" => task.grader.timeout_ms,
        "max_output_bytes" => task.grader.max_output_bytes,
        "env" => task.grader.env
      },
      "metadata" => task.metadata
    }
  end

  defp record(draft, feedback) do
    %{
      "schema_version" => draft.schema_version,
      "id" => draft.id,
      "status" => Atom.to_string(draft.status),
      "feedback_id" => draft.feedback_id,
      "fixture_digest" => draft.fixture_digest,
      "provenance" => draft.provenance,
      "feedback" => Feedback.to_map(feedback),
      "task" => draft.manifest_fragment,
      "review_checklist" => draft.review_checklist,
      "skipped" => Enum.map(draft.skipped_files, &%{"path" => &1, "reason" => "secret"})
    }
  end

  defp snapshot_digest(snapshot) do
    bytes =
      snapshot
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, digest} -> [path, 0, digest] end)

    :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
  end
end
