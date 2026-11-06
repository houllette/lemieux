defmodule Lemieux.Benchmark.Corpus.Review do
  @moduledoc """
  **Experimental.** Not part of the stable public API.
  Matched public-verifier controls for a development case.

  A failing check alone admits broken environments and always-failing graders.
  `review/3` runs the same grader on separate scratch copies of an untouched
  fixture and a repaired reference. Only explicitly named implementation paths
  may differ. Every other captured file, including public checks, must match.
  The declared failure status (exit 1 by default), a passing reference and
  unchanged grader inputs are required. Unexpected exit codes, timeouts and
  verifier writes cannot qualify a case. Owners of other verifier protocols
  explicitly choose `:failure_exit_status`; an exit code alone does not prove
  why a command failed. Pytest collection errors (exit 2) fail the default gate.

  The owner must review the allowed paths and the check's relationship to the
  reported requirement. This records development discrimination, not independent
  efficacy, reviewer authentication or permission to activate an improvement.
  Like command graders, it executes trusted owner-supplied code with the host's
  authority. A container-backed grader can supply its own isolation.
  Snapshots exclude Git metadata, editor state, build output and dependencies;
  installed tooling and environment identity still need separate qualification.
  """

  alias Lemieux.Benchmark.Grader.Command, as: CommandGrader
  alias Lemieux.Benchmark.SecretFiles
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.Contract

  @doc "Runs matched controls, returning a sealed report even when they do not discriminate."
  @spec review(task :: Task.t(), reference :: Path.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def review(%Task{} = task, reference, opts \\ []) do
    allowed = Keyword.get(opts, :allowed_changed_paths, [])

    with {:ok, failure_status} <- failure_exit_status(opts),
         :ok <- allowed_paths(allowed),
         :ok <- secrets(task.cwd, opts),
         :ok <- secrets(reference, opts),
         {:ok, original} <- snapshot(task.cwd),
         {:ok, repaired} <- snapshot(reference),
         changed = WorkspaceSnapshot.changed(original, repaired),
         :ok <- approved_changes(changed, allowed),
         {:ok, untouched} <- control(task, task.cwd, "untouched", original),
         {:ok, positive} <- control(task, reference, "reference", repaired),
         :ok <- unchanged_input(task.cwd, original),
         :ok <- unchanged_input(reference, repaired) do
      report = %{
        "schema_version" => 1,
        "kind" => "public_verification_review/v1",
        "status" => status(untouched, positive, failure_status),
        "expected_failure_exit_status" => failure_status,
        "case_id" => task.id,
        "exposure" => "developer_exposed",
        "independent_confirmation" => false,
        "snapshot_scope" => "benchmark_workspace_excludes_git_editor_build_dependencies",
        "fixture_digest" => WorkspaceSnapshot.digest(original),
        "reference_digest" => WorkspaceSnapshot.digest(repaired),
        "task_sha256" => task_digest(task),
        "allowed_changed_paths" => Enum.sort(allowed),
        "changed_paths" => changed,
        "controls" => %{"untouched" => untouched, "reference" => positive},
        "interpretation" => "public_development_discrimination_not_efficacy_or_authority"
      }

      {:ok, Map.put(report, "sha256", Contract.digest(report))}
    end
  end

  defp failure_exit_status(opts) do
    case Keyword.get(opts, :failure_exit_status, 1) do
      status when is_integer(status) and status in 1..255 -> {:ok, status}
      _invalid -> {:error, :invalid_failure_exit_status}
    end
  end

  defp snapshot(path) do
    with {:ok, %{type: :directory}} <- File.lstat(path),
         {:ok, snapshot} <- WorkspaceSnapshot.capture(path) do
      regular_snapshot(path, snapshot)
    else
      {:ok, _other} -> {:error, :review_requires_directory}
      {:error, reason} -> {:error, reason}
    end
  end

  defp regular_snapshot(path, snapshot) do
    case Enum.reject(Map.keys(snapshot), &regular_file?(path, &1)) do
      [] -> {:ok, snapshot}
      paths -> {:error, {:review_requires_regular_files, Enum.sort(paths)}}
    end
  end

  defp regular_file?(path, name),
    do: match?({:ok, %{type: :regular}}, File.lstat(Path.join(path, name)))

  defp unchanged_input(path, expected) do
    with {:ok, current} <- WorkspaceSnapshot.capture(path) do
      if current == expected, do: :ok, else: {:error, :review_inputs_changed}
    end
  end

  defp task_digest(task) do
    task
    |> Map.from_struct()
    |> Map.delete(:cwd)
    |> Contract.json()
    |> Contract.digest()
  end

  defp allowed_paths(paths) when is_list(paths) and paths != [] do
    if Enum.all?(paths, &relative_path?/1) and length(paths) == length(Enum.uniq(paths)),
      do: :ok,
      else: {:error, :review_requires_exact_source_paths}
  end

  defp allowed_paths(_paths), do: {:error, :review_requires_exact_source_paths}

  defp relative_path?(path) when is_binary(path) and byte_size(path) in 1..512,
    do:
      Path.type(path) == :relative and
        not String.contains?(path, ["\\", "*", "?", <<0>>]) and
        Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))

  defp relative_path?(_path), do: false

  defp approved_changes([], _allowed), do: {:error, :reference_unchanged}

  defp approved_changes(changed, allowed) do
    case changed -- allowed do
      [] -> :ok
      unapproved -> {:error, {:reference_changed_unapproved_paths, unapproved}}
    end
  end

  defp secrets(path, opts) do
    case {Keyword.get(opts, :allow_secret_files, false), SecretFiles.find(path)} do
      {true, _paths} -> :ok
      {false, []} -> :ok
      {false, paths} -> {:error, {:secret_files, paths}}
    end
  end

  defp control(task, source, role, snapshot) do
    scratch = Path.join(System.tmp_dir!(), "lemieux-case-review-" <> Lemieux.ID.generate())

    try do
      with {:ok, _paths} <- File.cp_r(source, scratch),
           {:ok, copied} <- WorkspaceSnapshot.capture(scratch),
           true <- copied == snapshot,
           {:ok, result} <- CommandGrader.grade(task.grader, %{task | cwd: scratch}, ""),
           {:ok, after_run} <- WorkspaceSnapshot.capture(scratch) do
        {:ok,
         result
         |> Map.take(~w(exit_status timed_out duration_ms))
         |> Map.put("output_sha256", Contract.sha256(result["output"]))
         |> Map.put("output_bytes", byte_size(result["output"]))
         |> Map.put("changed_paths", WorkspaceSnapshot.changed(snapshot, after_run))}
      else
        false -> {:error, {:review_input_changed, role}}
        {:error, reason} -> {:error, {:review_control_unavailable, role, reason}}
      end
    after
      File.rm_rf!(scratch)
    end
  end

  defp status(
         %{"exit_status" => actual, "timed_out" => false, "changed_paths" => []},
         %{"exit_status" => 0, "timed_out" => false, "changed_paths" => []},
         expected
       )
       when actual == expected,
       do: "passed"

  defp status(_untouched, _reference, _expected), do: "not_demonstrated"
end
