defmodule Lemieux.Benchmark.Corpus.Promote do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  Moves a reviewed case draft into a benchmark manifest.

  The corpus is the binding constraint on self-improvement: a search can
  only learn from cases that discriminate between candidates, and cases only
  arrive through the feedback path. `Lemieux.Feedback.CaseDraft` freezes a
  fixture and a verifier beside a feedback record and stops, because the
  design says a person reviews a draft before an optimizer sees it. This is
  the step after that review. It copies the frozen fixture next to the
  manifest, appends the task with the cluster, tags and allowlist the
  reviewer chose, and refuses two things on its own authority. One is a
  mutation case whose grader already passes on the untouched fixture. Such a
  case can never tell a candidate from the seed, and adding it would let a
  search claim progress on cases nobody could fail.

  The other is a fixture holding a secret-shaped file
  (`Lemieux.Benchmark.SecretFiles`): the copy lands beside a manifest that is
  meant to be committed, inside a tree whose ignore rules deliberately let a
  fixture's dotfiles through. `Lemieux.Feedback.CaseDraft` never copies such
  a file, so one here was put back by hand; a canary case that needs a
  credential-shaped file, such as a `.env` holding a fake token, passes
  `allow_secret_files: true` (`--allow-secret-files` to `lmx corpus
  promote`) to say the reviewer meant it.
  """

  alias Lemieux.Benchmark.Corpus.Review
  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.Benchmark.SecretFiles
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.WorkspaceSnapshot

  @typedoc """
  Options: `:cluster_id` (required), `:tags`, `:allowed_changed_paths`,
  `:expect` (`:fail` default, or `:pass` for read-only and refusal cases),
  `:repos_dir`, `:reference_dir` for matched public-verifier review, and
  `:allow_secret_files` (default false) to accept a fixture that holds
  secret-shaped files. Reference review requires exact `:allowed_changed_paths`
  and an unchanged frozen draft. Without a reference, verification remains
  explicitly unassessed rather than implying a passing repaired control.
  """
  @type opts :: keyword()

  @doc """
  Promotes the draft under `draft_dir` into the manifest at `manifest_path`.

  Returns `{:error, {:secret_files, paths}}`, before any grader runs or any
  file is copied, when the fixture holds secret-shaped files and
  `allow_secret_files: true` was not passed.
  """
  @spec promote(draft_dir :: Path.t(), manifest_path :: Path.t(), opts :: opts()) ::
          {:ok, String.t()} | {:error, term()}
  def promote(draft_dir, manifest_path, opts)
      when is_binary(draft_dir) and is_binary(manifest_path) and is_list(opts) do
    with {:ok, cluster} <- required(opts, :cluster_id),
         {:ok, draft} <- read_draft(draft_dir),
         {:ok, manifest_map} <- read_manifest(manifest_path),
         :ok <- unique(manifest_map, draft["id"]),
         fixture = Path.join(draft_dir, "fixture"),
         :ok <- directory(fixture),
         :ok <- no_secret_files(fixture, Keyword.get(opts, :allow_secret_files, false)),
         task_map = task_map(draft, cluster, opts),
         # `"fixture"` against `draft_dir`, not the already-joined path against
         # the same base: `Lemieux.Benchmark.Task.from_map/2` expands the cwd
         # relative to the base, so passing both doubled the draft directory
         # into the path and promote worked only when given an absolute one —
         # which the documented invocation is not.
         {:ok, task} <- Task.from_map(Map.put(task_map, "cwd", "fixture"), draft_dir),
         {:ok, review} <- verification_review(task, draft, opts),
         repos_dir =
           Keyword.get(
             opts,
             :repos_dir,
             Path.join(Path.dirname(Path.expand(manifest_path)), "repos")
           ),
         destination = Path.join(repos_dir, draft["id"]),
         :ok <- unused(destination),
         :ok <- File.mkdir_p(repos_dir),
         {:ok, _} <- File.cp_r(fixture, destination),
         :ok <- reviewed_copy(destination, review),
         :ok <-
           write_manifest(
             manifest_path,
             manifest_map,
             task_map
             |> Map.put("cwd", relative(destination, manifest_path))
             |> put_in(["metadata", "verification_review"], review)
           ) do
      {:ok, draft["id"]}
    end
  end

  @doc "Reviews a frozen draft without changing it or the approved corpus."
  @spec review(draft_dir :: Path.t(), reference :: Path.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def review(draft_dir, reference, opts \\ []) do
    with {:ok, draft} <- read_draft(draft_dir),
         {:ok, task} <-
           Task.from_map(Map.put(draft["manifest_fragment"], "cwd", "fixture"), draft_dir),
         :ok <- frozen_fixture(task, draft) do
      Review.review(task, reference, opts)
    end
  end

  defp verification_review(task, draft, opts) do
    case Keyword.fetch(opts, :reference_dir) do
      :error ->
        with :ok <- discriminates(task, Keyword.get(opts, :expect, :fail)),
             do: {:ok, %{"status" => "unassessed", "reason" => "no_reference_control"}}

      {:ok, reference} ->
        with :ok <- frozen_fixture(task, draft),
             {:ok, report} <- Review.review(task, reference, opts) do
          reviewed_report(report)
        end
    end
  end

  defp reviewed_report(%{"status" => "passed"} = report), do: {:ok, report}
  defp reviewed_report(report), do: {:error, {:verification_not_demonstrated, report}}

  defp reviewed_copy(destination, %{"status" => "passed", "fixture_digest" => expected}) do
    with {:ok, snapshot} <- WorkspaceSnapshot.capture(destination) do
      if WorkspaceSnapshot.digest(snapshot) == expected do
        :ok
      else
        File.rm_rf!(destination)
        {:error, :reviewed_copy_changed}
      end
    end
  end

  defp reviewed_copy(_destination, _unassessed), do: :ok

  defp frozen_fixture(task, draft) do
    with {:ok, snapshot} <- WorkspaceSnapshot.capture(task.cwd) do
      if WorkspaceSnapshot.digest(snapshot) == draft["fixture_digest"],
        do: :ok,
        else: {:error, :draft_fixture_changed}
    end
  end

  defp task_map(draft, cluster, opts) do
    fragment = draft["manifest_fragment"]

    metadata =
      Map.merge(Map.get(fragment, "metadata", %{}), %{
        "cluster_id" => cluster,
        "tags" => Enum.uniq(["promoted" | Keyword.get(opts, :tags, [])]),
        "safety" => %{"allowed_changed_paths" => Keyword.get(opts, :allowed_changed_paths, [])},
        "feedback_id" => draft["feedback_id"],
        "fixture_digest" => draft["fixture_digest"],
        "status" => "promoted"
      })

    fragment
    |> Map.take(~w(id prompt timeout_ms grader))
    |> Map.put("metadata", metadata)
  end

  # Run the grader on a scratch copy of the untouched fixture: a case that is
  # expected to fail and passes is not a case.
  defp discriminates(%Task{} = task, expect) when expect in [:fail, :pass] do
    scratch = Path.join(System.tmp_dir!(), "lemieux-promote-" <> Lemieux.ID.generate())

    try do
      with {:ok, _} <- File.cp_r(task.cwd, scratch),
           {:ok, result} <- CommandGrader.grade(task.grader, %{task | cwd: scratch}, "") do
        case {expect, result["passed"]} do
          {:fail, false} -> :ok
          {:pass, true} -> :ok
          {:fail, true} -> {:error, :grader_passes_untouched_fixture}
          {:pass, false} -> {:error, {:grader_fails_untouched_fixture, result["exit_status"]}}
        end
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp read_draft(dir) do
    with {:ok, bytes} <- File.read(Path.join(dir, "draft.json")),
         {:ok, %{"id" => id, "task" => %{} = fragment} = draft} when is_binary(id) <-
           JSON.decode(bytes) do
      {:ok, Map.put(draft, "manifest_fragment", fragment)}
    else
      {:ok, _other} -> {:error, :invalid_draft}
      {:error, :enoent} -> {:error, {:draft_missing, dir}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_manifest(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{"version" => 1, "tasks" => tasks} = map} when is_list(tasks) <-
           JSON.decode(bytes),
         {:ok, _manifest} <- Manifest.decode(bytes, Path.dirname(Path.expand(path))) do
      {:ok, map}
    else
      {:ok, _other} -> {:error, :invalid_manifest}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_manifest(path, map, task) do
    updated = Map.update!(map, "tasks", &(&1 ++ [task]))
    bytes = JSON.encode!(updated)

    with {:ok, _manifest} <- Manifest.decode(bytes, Path.dirname(Path.expand(path))) do
      staging = path <> ".staging"

      with :ok <- File.write(staging, bytes) do
        File.rename(staging, path)
      end
    end
  end

  defp unique(map, id) do
    if Enum.any?(map["tasks"], &(&1["id"] == id)), do: {:error, {:case_exists, id}}, else: :ok
  end

  defp unused(path),
    do: if(File.exists?(path), do: {:error, {:destination_exists, path}}, else: :ok)

  defp directory(path), do: if(File.dir?(path), do: :ok, else: {:error, {:fixture_missing, path}})

  defp no_secret_files(_fixture, true), do: :ok

  defp no_secret_files(fixture, false) do
    case SecretFiles.find(fixture) do
      [] -> :ok
      paths -> {:error, {:secret_files, paths}}
    end
  end

  defp relative(destination, manifest_path),
    do: Path.relative_to(Path.expand(destination), Path.dirname(Path.expand(manifest_path)))

  defp required(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {key, :required}}
    end
  end
end
