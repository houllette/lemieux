defmodule Lemieux.Writers.Worktree do
  @moduledoc """
  Host-selected detached Git worktrees with file tools and reviewed integration.

  `new/1` freezes HEAD. Writers start from that revision, never from a user's
  dirty index. Their tools may read files and write their declared paths; this
  adapter grants no shell. A worktree shares Git objects and is not a sandbox.
  Checkout and patch capture use the checkpoint implementation's private Git
  configuration, so repository filters and hooks do not execute on the host.

  Integration serializes on a repository-wide, non-expiring owner lock. It
  refuses stale HEAD, dirty touched files, altered artifacts and overlapping
  patches. Checks run on the combined candidate and again after applying it.
  Only accepted paths are written; the user's index is never changed.

  A durable intent precedes primary writes. A guardian rolls back an interrupted
  writer only when every touched file still matches its before or after image.
  Foreign edits make the transaction blocked rather than overwritten. A full
  runtime loss leaves the intent for `recover/2`; no next integration runs over
  unresolved work. These checks serialize coordinators, not an unrelated editor:
  hosts must exclude concurrent edits to the accepted paths during integration.
  """
  @behaviour Lemieux.Writers.Workspace
  alias Lemieux.Checkpoint.Git
  alias Lemieux.Checkpoint.Git.Repository
  alias Lemieux.Environment
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Jobs.Journal
  alias Lemieux.Jobs.Journal.Files
  alias Lemieux.Writers.Artifact
  alias Lemieux.Writers.Plan
  alias Lemieux.Writers.Workspace

  @type state :: %{
          root: Path.t(),
          directory: Path.t(),
          base_revision: String.t(),
          base_tree: String.t(),
          journal: Journal.t()
        }
  @max_patch_bytes 8_000_000

  @doc """
  Chooses the source repository and a private lease/artifact directory outside it.

  `:source` defaults to `:head`. `:working_tree` captures current bytes without
  committing or changing the real index, including accepted earlier patches.
  Supply `:paths` with all relevant granted scopes to distinguish unrelated
  ignored build outputs from uncaptured deliverables. Each batch still needs
  a fresh adapter; every member of that batch uses the same captured tree.
  """
  @spec new(opts :: keyword()) :: Workspace.adapter()
  def new(opts) do
    # Git reports physical roots (notably /private/tmp on macOS). Resolve both
    # sides so an alias is accepted, but cannot conceal leases inside the root.
    root = Sandbox.real(Keyword.fetch!(opts, :root))
    directory = Sandbox.real(Keyword.fetch!(opts, :directory))

    with {:ok, %{root: ^root} = repository} <- Repository.locate(root),
         false <- directory == root or String.starts_with?(directory, root <> "/"),
         {:ok, revision} <- Git.revision(root),
         {:ok, tree} <- base_tree(root, directory, revision, opts) do
      {__MODULE__,
       %{
         root: root,
         directory: directory,
         base_revision: revision,
         base_tree: tree,
         journal: Files.new(Path.join(repository.common_dir, "lemieux-writers"))
       }}
    else
      _invalid ->
        raise ArgumentError,
              "writers need a committed repository root and an outside lease directory"
    end
  end

  defp base_tree(root, directory, revision, opts) do
    case Keyword.get(opts, :source, :head) do
      :head ->
        with {:ok, tree} <- object(root, ["rev-parse", revision <> "^{tree}"]),
             do: {:ok, String.trim(tree)}

      :working_tree ->
        working_tree(root, directory, Keyword.get(opts, :paths, :strict))

      _invalid ->
        {:error, :invalid_source}
    end
  end

  defp working_tree(root, directory, paths) do
    with :ok <- private_directory(directory),
         {:ok, snapshot} <-
           complete_snapshot(root, paths, scratch: Path.join(directory, "snapshots")),
         do: {:ok, snapshot.tree}
  end

  @impl true
  def prepare(state, group_id, plan) do
    id = group_id <> "-" <> plan.id <> "-" <> Lemieux.ID.generate()
    path = Path.join([state.directory, "worktrees", id])
    key = "lease-" <> id

    with :ok <- private_directory(Path.dirname(path)),
         {:ok, lock} <- Journal.lock(state.journal, key) do
      workspace = %Workspace{
        id: id,
        cwd: path,
        base_revision: state.base_revision,
        environment: Environment.Local.new(credentials: true),
        lease: %{path: path, key: key, lock: lock, owner: self()}
      }

      value = %{
        "status" => "preparing",
        "id" => id,
        "path" => path,
        "directory" => state.directory,
        "paths" => plan.paths,
        "base_tree" => state.base_tree,
        "base_revision" => state.base_revision
      }

      outcome =
        with {:ok, _} <- Journal.write(state.journal, key, 0, value),
             {:ok, _} <-
               Repository.real(
                 state.root,
                 ["worktree", "add", "--detach", "--no-checkout", path, state.base_revision]
               ),
             :ok <- checkout(path, state.base_tree),
             {:ok, _} <- Journal.update(state.journal, key, &Map.put(&1, "status", "allocated")),
             do: {:ok, workspace}

      case outcome do
        {:ok, _} ->
          outcome

        error ->
          release(state, workspace)
          error
      end
    end
  end

  defp checkout(path, revision) do
    with {:ok, repository} <- Repository.locate(path) do
      Repository.with_private(repository, [], &checkout_index(&1, repository, revision))
    end
  end

  defp checkout_index(private, repository, revision) do
    with {:ok, _} <- Repository.run(private, ["read-tree", revision]),
         {:ok, _} <- Repository.run(private, ["checkout-index", "--all", "--force"]),
         do: File.cp(Path.join(private.dir, "index"), Path.join(repository.git_dir, "index"))
  end

  @impl true
  def release(state, workspace) do
    path = Path.join([state.directory, "worktrees", workspace.id])

    if workspace.cwd == path and match?(%{path: ^path}, workspace.lease) do
      release_lease(state, workspace)
    else
      {:error, :foreign_lease}
    end
  end

  defp release_lease(state, workspace) do
    with {:ok, lock} <- lease_lock(state, workspace) do
      try do
        with :ok <- remove_worktree(state, workspace.cwd),
             {:ok, _} <-
               Journal.update(
                 state.journal,
                 workspace.lease.key,
                 &Map.put(&1, "status", "released")
               ),
             do: :ok
      after
        Journal.unlock(state.journal, workspace.lease.key, lock)
      end
    end
  end

  defp lease_lock(_state, %{lease: %{owner: owner, lock: lock}}) when owner == self(),
    do: {:ok, lock}

  defp lease_lock(state, workspace), do: Journal.lock(state.journal, workspace.lease.key)

  defp remove_worktree(state, path) do
    case File.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with {:ok, _} <- Repository.real(state.root, ["worktree", "remove", "--force", path]),
             do: :ok

      _unsafe ->
        {:error, :unsafe_lease_path}
    end
  end

  @doc """
  Cleans orphaned leases after the host establishes the old runtime has stopped.
  Live or unprovable lock owners are retained. Complete artifacts are never removed.
  """
  @spec reap(adapter :: Workspace.adapter()) :: {:ok, [map()]} | {:error, term()}
  def reap({__MODULE__, state}), do: reap_page(state, nil, [])

  defp reap_page(state, cursor, results) do
    with {:ok, records} <- Journal.scan(state.journal, "lease-", cursor, 100) do
      outcomes = Enum.flat_map(records, &reap_record(state, &1))
      next_reap_page(state, records, results ++ outcomes)
    end
  end

  defp next_reap_page(state, records, results) do
    if length(records) == 100,
      do: reap_page(state, List.last(records).key, results),
      else: {:ok, results}
  end

  defp reap_record(state, record) do
    value = record.value

    if value["directory"] == state.directory and value["status"] != "released",
      do: [reap_lease(state, record)],
      else: []
  end

  defp reap_lease(state, record) do
    value = record.value
    path = Path.join([state.directory, "worktrees", value["id"]])

    with true <- record.key == "lease-" <> value["id"] and path == value["path"],
         {:ok, lock} <- Journal.lock(state.journal, record.key) do
      workspace = %Workspace{
        id: value["id"],
        cwd: path,
        base_revision: value["base_revision"],
        environment: Environment.local(),
        lease: %{path: path, key: record.key, lock: lock, owner: self()}
      }

      outcome = with :ok <- reaping_safe?(state, workspace, value), do: release(state, workspace)
      Journal.unlock(state.journal, record.key, lock)
      %{"id" => value["id"], "result" => inspect(outcome)}
    else
      false -> %{"id" => value["id"], "result" => "invalid lease"}
      {:error, reason} -> %{"id" => value["id"], "result" => inspect(reason)}
    end
  end

  defp reaping_safe?(state, workspace, value) do
    snapshot =
      if File.exists?(workspace.cwd),
        do: complete_snapshot(workspace.cwd, Map.get(value, "paths", :strict)),
        else: :absent

    case snapshot do
      :absent ->
        :ok

      {:ok, snapshot} ->
        cond do
          snapshot.tree == value["base_tree"] -> :ok
          snapshot.tree == value["captured_tree"] -> saved_manifest?(state, value["artifact"])
          true -> {:error, :uncaptured_work}
        end

      _unavailable ->
        {:error, :uncaptured_work}
    end
  end

  defp saved_manifest?(state, %{"digest" => digest, "manifest_path" => path}) do
    expected = Path.join([state.directory, "artifacts", digest <> ".manifest.json"])

    with true <- path == expected,
         {:ok, bytes} <- File.read(path),
         {:ok, manifest} when is_map(manifest) <- JSON.decode(bytes) do
      fields =
        Map.keys(
          Map.from_struct(%Artifact{
            writer_id: "",
            base_revision: "",
            base_tree: "",
            tree: "",
            paths: [],
            transcript_id: "",
            patch_path: "",
            patch_sha256: "",
            report_path: "",
            report_sha256: "",
            verification: %{}
          })
        )

      artifact = struct!(Artifact, Map.new(fields, &{&1, manifest[Atom.to_string(&1)]}))
      Artifact.verify(artifact)
    else
      _invalid -> {:error, :artifact_changed}
    end
  end

  defp saved_manifest?(_state, _reference), do: {:error, :uncaptured_work}

  @impl true
  def export(state, workspace, plan, result, evidence) do
    with :ok <- valid_report(result.report),
         {:ok, snapshot} <- complete_snapshot(workspace.cwd, plan.paths),
         {:ok, changes} <- Git.changed(state.root, state.base_tree, snapshot.tree),
         paths = Enum.map(changes, &elem(&1, 1)) |> Enum.sort(),
         :ok <- owned_changes(plan, paths),
         :ok <- regular_entries(state.root, [state.base_tree, snapshot.tree], paths),
         {:ok, patch} <-
           object(state.root, [
             "diff",
             "--binary",
             "--no-renames",
             "--no-ext-diff",
             "--no-textconv",
             state.base_tree,
             snapshot.tree,
             "--"
           ]),
         true <- byte_size(patch) <= @max_patch_bytes,
         :ok <- private_directory(Path.join(state.directory, "artifacts")) do
      report =
        JSON.encode!(%{
          "report" => result.report,
          "verification" => evidence,
          "transcript_id" => result.session_id,
          "entry_ids" => Enum.map(result.entries, & &1.id)
        })

      patch_hash = Artifact.hash(patch)
      report_hash = Artifact.hash(report)
      patch_path = Path.join([state.directory, "artifacts", patch_hash <> ".patch"])
      report_path = Path.join([state.directory, "artifacts", report_hash <> ".json"])

      with :ok <- save(patch_path, patch), :ok <- save(report_path, report) do
        artifact =
          Artifact.seal(%Artifact{
            writer_id: plan.id,
            base_revision: state.base_revision,
            base_tree: state.base_tree,
            tree: snapshot.tree,
            paths: paths,
            transcript_id: result.session_id,
            patch_path: patch_path,
            patch_sha256: patch_hash,
            report_path: report_path,
            report_sha256: report_hash,
            verification: evidence
          })

        publish_artifact(state, workspace, artifact, snapshot.tree, result.session_id)
      end
    else
      false -> {:error, :patch_too_large}
      error -> error
    end
  end

  defp publish_artifact(state, workspace, artifact, tree, transcript_id) do
    with {:ok, artifact} <- save_manifest(artifact),
         {:ok, _} <-
           Journal.update(
             state.journal,
             workspace.lease.key,
             &Map.merge(&1, %{
               "artifact" => Artifact.reference(artifact),
               "captured_tree" => tree,
               "transcript_id" => transcript_id
             })
           ),
         do: {:ok, artifact}
  end

  defp save_manifest(artifact) do
    with :ok <- save(Artifact.manifest_path(artifact), JSON.encode!(Artifact.manifest(artifact))),
         do: {:ok, artifact}
  end

  defp valid_report(
         %{
           "summary" => summary,
           "critical_findings" => findings,
           "uncertainties" => uncertainties
         } = report
       )
       when is_binary(summary) and is_list(findings) and is_list(uncertainties) do
    if byte_size(JSON.encode!(report)) <= 65_536, do: :ok, else: {:error, :report_too_large}
  end

  defp valid_report(_report), do: {:error, :invalid_writer_report}

  defp owned_changes(_plan, []), do: {:error, :missing_patch}

  defp owned_changes(plan, paths) do
    if Enum.all?(paths, &Plan.owns?(plan, &1)),
      do: :ok,
      else: {:error, {:unauthorized_changes, Enum.reject(paths, &Plan.owns?(plan, &1))}}
  end

  @impl true
  def integrate(state, artifacts, checks, authorize) do
    with {:ok, lock} <- Journal.lock(state.journal, "integration") do
      try do
        with :ok <- no_pending(state, nil),
             :ok <- validate_artifacts(state, artifacts),
             paths = artifacts |> Enum.flat_map(& &1.paths) |> Enum.sort(),
             :ok <- clean_index(state, paths),
             {:ok, original} <- complete_snapshot(state.root, paths),
             :ok <- unchanged(state.root, state.base_tree, paths),
             {:ok, candidate} <- integration_candidate(state, original, artifacts) do
          guardian = lease_guard(self(), state, candidate)

          try do
            with {:ok, staged_checks} <- checked(checks, candidate.cwd),
                 {:ok, staged} <- complete_snapshot(candidate.cwd, paths),
                 :ok <- reviewed_candidate(state, staged.tree, artifacts),
                 :ok <- unchanged(state.root, original.tree, paths),
                 {:ok, revision} <- Git.revision(state.root),
                 true <- revision == state.base_revision,
                 :ok <- authorize.(),
                 :ok <- clean_index(state, paths) do
              transaction(state, original.tree, staged, paths, checks, staged_checks)
            else
              false -> {:error, :stale_base}
              error -> error
            end
          after
            release(state, candidate)
            stop_guard(guardian)
          end
        end
      after
        Journal.unlock(state.journal, "integration", lock)
      end
    end
  end

  # Checks may compile or generate files, but cannot silently substitute new
  # content for a patch the host accepted by digest.
  defp reviewed_candidate(state, tree, artifacts) do
    reduce_ok(artifacts, &reviewed_paths(state.root, tree, &1))
  end

  defp reviewed_paths(root, tree, artifact) do
    with {:ok, reviewed} <- Git.entries(root, artifact.tree, artifact.paths),
         {:ok, candidate} <- Git.entries(root, tree, artifact.paths) do
      if reviewed == candidate, do: :ok, else: {:error, :candidate_changed}
    end
  end

  defp validate_artifacts(_state, []), do: {:error, :no_artifacts}

  defp validate_artifacts(state, artifacts) do
    paths = Enum.flat_map(artifacts, & &1.paths)

    cond do
      Enum.any?(artifacts, &(&1.verification["status"] != "passed")) ->
        {:error, :unverified_artifact}

      length(paths) != length(Enum.uniq(paths)) ->
        {:error, :overlapping_patches}

      Enum.any?(
        artifacts,
        &(&1.base_revision != state.base_revision or &1.base_tree != state.base_tree)
      ) ->
        {:error, :stale_base}

      Git.revision(state.root) != {:ok, state.base_revision} ->
        {:error, :stale_base}

      true ->
        reduce_ok(artifacts, &verified_tree(state, &1))
    end
  end

  defp verified_tree(state, artifact) do
    with :ok <- Artifact.verify(artifact) do
      if Git.object?(state.root, artifact.tree), do: :ok, else: rehydrate(state, artifact)
    end
  end

  defp rehydrate(state, artifact) do
    with {:ok, repository} <- Repository.locate(state.root) do
      Repository.with_private(repository, [], &apply_saved_patch(&1, artifact))
    end
  end

  defp apply_saved_patch(private, artifact) do
    with {:ok, _} <- Repository.run(private, ["read-tree", artifact.base_tree]),
         {:ok, _} <-
           Repository.run(private, [
             "apply",
             "--cached",
             "--binary",
             "--whitespace=nowarn",
             artifact.patch_path
           ]),
         {:ok, tree} <- Repository.run(private, ["write-tree"]) do
      if String.trim(tree) == artifact.tree, do: :ok, else: {:error, :artifact_changed}
    end
  end

  defp integration_candidate(state, original, artifacts) do
    plan =
      Plan.new(
        id: "integration",
        task: "Verify accepted patches",
        paths: ["candidate/"],
        tools: ["read"]
      )

    with {:ok, workspace} <- prepare(state, "review", plan) do
      outcome =
        with {:ok, changes} <- Git.changed(state.root, state.base_tree, original.tree),
             :ok <- restore_tree(workspace.cwd, original.tree, Enum.map(changes, &elem(&1, 1))),
             :ok <- reduce_ok(artifacts, &restore_tree(workspace.cwd, &1.tree, &1.paths)) do
          {:ok, workspace}
        end

      case outcome do
        {:ok, _} ->
          outcome

        error ->
          release(state, workspace)
          error
      end
    end
  end

  defp transaction(state, before, staged, paths, checks, staged_checks) do
    key = "transaction-" <> Lemieux.ID.generate()
    later = staged.tree

    value = %{
      "status" => "prepared",
      "root" => state.root,
      "before" => before,
      "after" => later,
      "paths" => paths
    }

    # Git trees can normalize line endings. Recovery must restore the actual
    # pre-application bytes, and application must use the checked candidate's
    # bytes, rather than reconstructing either from a normalized blob.
    with {:ok, before_images} <- current_images(state.root, paths),
         {:ok, after_images} <- current_images(staged.root, paths),
         :ok <- image_limit(before_images, after_images),
         value =
           Map.merge(value, %{"before_images" => before_images, "after_images" => after_images}),
         {:ok, _} <- Journal.write(state.journal, key, 0, value) do
      guardian = guardian(self(), state, key)

      # Host checks are a transaction boundary: an exception or exit after
      # application must roll back just like an error return. The old `after`
      # disarmed the guardian while unwinding, leaving a prepared transaction
      # applied. Preserve its identity even when guarded rollback is blocked.
      outcome =
        try do
          outcome =
            with :ok <- restore_images(state.root, after_images),
                 {:ok, evidence} <- checked(checks, state.root),
                 :ok <- unchanged(state.root, later, paths),
                 {:ok, _} <-
                   Journal.update(
                     state.journal,
                     key,
                     &Map.merge(&1, %{"status" => "integrated", "checks" => evidence})
                   ) do
              {:ok,
               %{
                 status: :integrated,
                 transaction_id: key,
                 paths: paths,
                 staged_checks: staged_checks,
                 checks: evidence
               }}
            end

          finish_transaction(state, key, outcome)
        catch
          kind, reason ->
            finish_transaction(
              state,
              key,
              {:error, {:integration_interrupted, key, {kind, reason}}}
            )
        end

      stop_guard(guardian)
      outcome
    end
  end

  defp finish_transaction(_state, _key, {:ok, _} = outcome), do: outcome

  defp finish_transaction(state, key, error) do
    case rollback(state, key) do
      :ok -> error
      failure -> {:error, {:integration_unresolved, key, error, failure}}
    end
  end

  defp guardian(owner, state, key) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:finished, ^owner} ->
          Process.demonitor(ref, [:flush])
          send(owner, {:guardian_stopped, self()})

        {:DOWN, ^ref, :process, ^owner, _reason} ->
          recover({__MODULE__, state}, key)
      end
    end)
  end

  defp lease_guard(owner, state, workspace) do
    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:finished, ^owner} ->
          Process.demonitor(ref, [:flush])
          send(owner, {:guardian_stopped, self()})

        {:DOWN, ^ref, :process, ^owner, _reason} ->
          release(state, workspace)
      end
    end)
  end

  defp stop_guard(guardian) do
    send(guardian, {:finished, self()})

    receive do
      {:guardian_stopped, ^guardian} -> :ok
    end
  end

  @doc """
  Explicitly resolves an interrupted integration by guarded rollback.
  Unknown or foreign file contents stay blocked. The original checks are never replayed.
  """
  @spec recover(adapter :: Workspace.adapter(), transaction_id :: String.t()) ::
          :ok | {:error, term()}
  def recover({__MODULE__, state}, key) do
    with {:ok, lock} <- Journal.lock(state.journal, "integration") do
      try do
        rollback(state, key)
      after
        Journal.unlock(state.journal, "integration", lock)
      end
    end
  end

  defp rollback(state, key) do
    with {:ok, %{value: value}} <- Journal.read(state.journal, key) do
      if value["status"] in ["integrated", "rolled_back"] do
        :ok
      else
        persist_rollback(state, key, rollback_files(state, value))
      end
    end
  end

  defp persist_rollback(state, key, outcome) do
    status = if outcome == :ok, do: "rolled_back", else: "blocked"

    with {:ok, _} <- Journal.update(state.journal, key, &Map.put(&1, "status", status)),
         do: outcome
  end

  defp rollback_files(state, value) do
    before = value["before_images"]
    later = value["after_images"]

    with true <- value["root"] == state.root and is_map(before) and is_map(later),
         {:ok, current} <- current_images(state.root, value["paths"]),
         true <- Enum.all?(value["paths"], &(current[&1] in [before[&1], later[&1]])),
         :ok <- restore_images(state.root, before) do
      :ok
    else
      _uncertain -> {:error, :foreign_changes}
    end
  end

  defp current_images(root, paths) do
    with {:ok, entries} <- Git.worktree_entries(root, paths) do
      collect_images(paths, fn path -> current_image(root, path, entries[path]) end)
    end
  end

  defp current_image(_root, _path, nil), do: {:ok, nil}

  defp current_image(root, path, %{mode: mode}) when mode in ["100644", "100755"] do
    with {:ok, bytes} <- Environment.read_file(Environment.local(), root, path),
         {:ok, stat} <- File.stat(Path.join(root, path)),
         do: {:ok, encode_image(mode, bytes, Bitwise.band(stat.mode, 0o777))}
  end

  defp current_image(_root, _path, _entry), do: {:error, :unsupported_file_type}

  defp encode_image(mode, bytes, permissions),
    do: %{
      "mode" => mode,
      "permissions" => permissions,
      "content" => Base.encode64(bytes),
      "sha256" => Artifact.hash(bytes)
    }

  defp collect_images(paths, read) do
    Enum.reduce_while(paths, {:ok, %{}}, fn path, {:ok, found} ->
      case read.(path) do
        {:ok, image} -> {:cont, {:ok, Map.put(found, path, image)}}
        error -> {:halt, error}
      end
    end)
  end

  defp image_limit(before, later) do
    bytes = byte_size(JSON.encode!(%{"before" => before, "after" => later}))
    if bytes <= 6_000_000, do: :ok, else: {:error, :integration_too_large}
  end

  defp restore_images(root, images),
    do: reduce_ok(images, fn {path, image} -> write_image(root, path, image) end)

  defp write_image(root, path, nil), do: Environment.delete_file(Environment.local(), root, path)

  defp write_image(root, path, %{
         "mode" => mode,
         "content" => content,
         "sha256" => digest,
         "permissions" => permissions
       })
       when is_integer(permissions) and permissions in 0..0o777 do
    with {:ok, bytes} <- Base.decode64(content),
         true <- Artifact.hash(bytes) == digest,
         do: write_bytes(root, path, mode, bytes, permissions)
  end

  defp write_image(_root, _path, _image), do: {:error, :invalid_image}

  defp no_pending(state, cursor) do
    with {:ok, records} <- Journal.scan(state.journal, "transaction-", cursor, 100) do
      case Enum.find(records, &(&1.value["status"] not in ["integrated", "rolled_back"])) do
        nil ->
          next_page(state, records)

        record ->
          {:error, {:unresolved_integration, record.key}}
      end
    end
  end

  defp next_page(state, records) do
    if length(records) == 100, do: no_pending(state, List.last(records).key), else: :ok
  end

  defp unchanged(root, tree, paths) do
    with {:ok, expected} <- Git.entries(root, tree, paths),
         {:ok, actual} <- Git.worktree_entries(root, paths) do
      if expected == actual,
        do: :ok,
        else: {:error, {:dirty_paths, Enum.filter(paths, &(actual[&1] != expected[&1]))}}
    end
  end

  # Disk can equal HEAD while the index contains staged work and the working
  # copy contains its inverse. Applying a patch then loses that unstaged edit.
  # Read a private copy of the index; unrelated staged paths stay untouched.
  defp clean_index(state, paths) do
    with {:ok, repository} <- Repository.locate(state.root) do
      Repository.with_private(
        repository,
        [index: :copy],
        &index_changes(&1, state.base_revision, paths)
      )
    end
  end

  defp index_changes(private, revision, paths) do
    with {:ok, changed} <-
           Repository.run(private, [
             "diff",
             "--cached",
             "--name-only",
             "-z",
             "--no-renames",
             "--no-ext-diff",
             "--no-textconv",
             revision,
             "--" | paths
           ]) do
      case String.split(changed, <<0>>, trim: true) do
        [] -> :ok
        dirty -> {:error, {:dirty_paths, dirty}}
      end
    end
  end

  defp regular_entries(root, trees, paths) do
    reduce_ok(trees, &regular_tree(root, &1, paths))
  end

  defp regular_tree(root, tree, paths) do
    with {:ok, entries} <- Git.entries(root, tree, paths) do
      if Enum.all?(entries, &regular_entry?/1), do: :ok, else: {:error, :unsupported_file_type}
    end
  end

  defp regular_entry?({_path, nil}), do: true
  defp regular_entry?({_path, entry}), do: entry.mode in ["100644", "100755"]

  defp restore_tree(root, tree, paths) do
    with :ok <- regular_entries(root, [tree], paths),
         {:ok, entries} <- Git.entries(root, tree, paths) do
      reduce_ok(paths, fn path -> write_entry(root, path, entries[path]) end)
    end
  end

  defp write_entry(root, path, nil), do: Environment.delete_file(Environment.local(), root, path)

  defp write_entry(root, path, entry) do
    with {:ok, bytes} <- object(root, ["cat-file", "blob", entry.blob]),
         do: write_bytes(root, path, entry.mode, bytes)
  end

  defp write_bytes(root, path, mode, bytes, permissions \\ nil) do
    with {:ok, absolute} <- Environment.Local.confined(root, path),
         :ok <- File.mkdir_p(Path.dirname(absolute)) do
      temporary = absolute <> ".lmx-" <> Lemieux.ID.generate()

      try do
        with :ok <- File.write(temporary, bytes, [:exclusive]),
             :ok <-
               File.chmod(temporary, permissions || if(mode == "100755", do: 0o755, else: 0o644)),
             do: File.rename(temporary, absolute)
      after
        File.rm(temporary)
      end
    end
  end

  defp complete_snapshot(root, paths, opts \\ []) do
    with {:ok, snapshot} <- Git.snapshot(root, opts) do
      uncaptured = Enum.filter(snapshot.unsaved, &uncaptured?(&1, paths))

      if uncaptured == [] and snapshot.unsaved_more == 0,
        do: {:ok, snapshot},
        else: {:error, {:uncaptured_files, uncaptured}}
    end
  end

  defp uncaptured?(_entry, :strict), do: true

  # Build outputs outside the accepted scope and private host files are not
  # deliverables. An ignored file inside (or containing) that scope must still
  # fail capture; treating it as absent would silently lose a writer's effect.
  defp uncaptured?(%{why: :ignored, path: path}, paths) do
    path = String.trim_trailing(path, "/")
    Enum.any?(paths, &related_path?(path, String.trim_trailing(&1, "/")))
  end

  defp uncaptured?(_entry, _paths), do: true

  defp related_path?(left, right),
    do:
      left == right or String.starts_with?(left, right <> "/") or
        String.starts_with?(right, left <> "/")

  @doc false
  @spec checked(checks :: Workspace.check(), cwd :: Path.t()) :: {:ok, map()} | {:error, term()}
  def checked(checks, cwd) do
    case checks.(cwd) do
      {:ok, %{"status" => "passed"} = evidence} when map_size(evidence) > 1 ->
        if byte_size(JSON.encode!(evidence)) <= 8192,
          do: {:ok, evidence |> JSON.encode!() |> JSON.decode!()},
          else: {:error, :evidence_too_large}

      {:error, _} = error ->
        error

      _invalid ->
        {:error, :missing_verification}
    end
  end

  defp object(root, args) do
    with {:ok, repository} <- Repository.locate(root),
         do: Repository.with_private(repository, [refs: true], &Repository.run(&1, args))
  end

  defp private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %{type: :directory}} <- File.lstat(path),
         do: File.chmod(path, 0o700)
  end

  defp save(path, content) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        if File.read(path) == {:ok, content}, do: :ok, else: {:error, :artifact_changed}

      {:error, :enoent} ->
        save_new(path, content)

      _unsafe ->
        {:error, :unsafe_artifact_path}
    end
  end

  defp save_new(path, content) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(file, content),
             do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp reduce_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
