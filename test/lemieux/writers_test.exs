defmodule Lemieux.WritersTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias Lemieux.Checkpoint.Git
  alias Lemieux.CLI.Tasks
  alias Lemieux.Clock.Manual
  alias Lemieux.Jobs.Journal
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Writers
  alias Lemieux.Writers.Plan
  alias Lemieux.Writers.Worktree

  @moduletag :tmp_dir

  defmodule BackgroundRead do
    @behaviour Lemieux.Tool.Configured
    alias Lemieux.Background
    alias Lemieux.Tool.Result
    defstruct [:observer]
    @impl true
    def name(_), do: "analyze"
    @impl true
    def description(_), do: "Read-only gated analysis"
    @impl true
    def schema(_), do: %{"type" => "object", "properties" => %{}}
    @impl true
    def read_only?(_), do: true
    @impl true
    def run(tool, _, context) do
      {:ok, id} =
        Background.start(
          supervisor: context.supervisor,
          session_id: context.session_id,
          root_session_id: context.root_session_id,
          owner: context.session,
          command: "analyze fixture",
          cwd: context.cwd,
          environment: context.environment,
          runner: fn _, _ ->
            send(tool.observer, {:background_read, self()})

            receive do
              :finish -> {:ok, "ANALYSIS_READY", 0}
            after
              60_000 -> {:error, :fixture_held_too_long}
            end
          end
        )

      {:ok,
       Result.new("Started",
         structured_content: %{"task_id" => id, "status" => "running"}
       )}
    end
  end

  test "writers keep their lease open until background analysis and the final patch finish",
       ctx do
    observer = self()

    provider =
      Scripted.new([
        Scripted.tool_call("analyze", "analyze", %{}),
        Scripted.complete(report("Waiting for analysis")),
        Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
        Scripted.complete(report("Analysis completed; created one.txt"))
      ])

    plan =
      Plan.new(
        id: "one",
        task: "Analyze then write",
        paths: ["one.txt"],
        tools: ["analyze", "write"]
      )

    factory = fn _, _ ->
      {:ok,
       [
         provider: provider,
         model: "test:model",
         tools: [%BackgroundRead{observer: observer}, Lemieux.Tools.Write]
       ]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert_receive {:background_read, worker}
    # Read the live coordinator and its native command before releasing the gate.
    assert {:ok, %{writers: [%{status: :running}]}} = Writers.snapshot(group)
    assert {:ok, %{rows: [row]}} = Tasks.snapshot(ctx.parent)
    assert row.managed? and row.running?
    send(worker, :finish)

    assert {:ok, %{status: :ready, writers: [%{status: :completed} = writer]}} =
             Writers.await(group)

    assert File.read!(writer.artifact.report_path) =~ "Analysis completed"
    assert length(Scripted.requests(provider)) == 4
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  defmodule ObservingJournal do
    @behaviour Journal
    @impl true
    def read(state, key), do: Journal.read(state.journal, key)
    @impl true
    def write(state, key, revision, value) do
      result = Journal.write(state.journal, key, revision, value)
      if match?({:ok, _}, result), do: send(state.owner, {:transaction, key, value["status"]})
      result
    end

    @impl true
    def scan(state, prefix, cursor, limit), do: Journal.scan(state.journal, prefix, cursor, limit)
    @impl true
    def lock(state, key), do: Journal.lock(state.journal, key)
    @impl true
    def unlock(state, key, lock), do: Journal.unlock(state.journal, key, lock)
  end

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    git(root, ["init", "--quiet"])
    File.write!(Path.join(root, "original.txt"), "original\n")
    git(root, ["add", "original.txt"])

    git(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture"
    ])

    runtime = :"writers_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(Path.join(dir, "sessions"))

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        store: store,
        provider: Scripted.new([Scripted.complete("parent")]),
        model: "test:model",
        tools: [],
        cwd: root,
        job_limits: [max_requests: 20]
      )

    workspace = Worktree.new(root: root, directory: Path.join(dir, "writers"))
    %{root: root, parent: parent, workspace: workspace, runtime: runtime, store: store}
  end

  test "independent writers return isolated patches and integrate only after review", ctx do
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep my work\n")

    plans =
      for id <- ["alpha", "beta"],
          do: Plan.new(id: id, task: "Create #{id}.txt", paths: ["#{id}.txt"], tools: ["write"])

    observer = self()

    factory = fn plan, _workspace ->
      send(observer, {:prepared, plan.id})

      provider =
        Scripted.new([
          Scripted.tool_call("write-#{plan.id}", "write", %{
            "path" => "#{plan.id}.txt",
            "content" => "#{plan.id}\n"
          }),
          Scripted.complete(report(plan.id))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write], compact_at: nil]}
    end

    {:ok, group} = Writers.start(ctx.parent, plans, options(factory, ctx))
    assert_receive {:prepared, "alpha"}
    assert_receive {:prepared, "beta"}
    assert {:ok, result} = Writers.await(group)
    assert result.status == :ready
    assert Enum.map(result.writers, & &1.id) == ["alpha", "beta"]
    assert Enum.all?(result.writers, &(&1.status == :completed))
    refute File.exists?(Path.join(ctx.root, "alpha.txt"))
    artifacts = Enum.map(result.writers, & &1.artifact.digest)
    assert {:error, :unauthorized} = Writers.integrate(group, artifacts, :stranger)
    assert {:ok, integrated} = Writers.integrate(group, artifacts, :owner)
    assert integrated.status == :integrated
    assert File.read!(Path.join(ctx.root, "alpha.txt")) == "alpha\n"
    assert File.read!(Path.join(ctx.root, "beta.txt")) == "beta\n"
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert %{requests: 4} = result.budget
    assert Enum.all?(result.writers, &(&1.transcript_id != Session.info(ctx.parent).id))
    assert :ok = Writers.close(group, :owner)
  end

  test "overlapping scopes are refused before allocation", ctx do
    plans = [
      Plan.new(id: "one", task: "one", paths: ["src/"], tools: ["write"]),
      Plan.new(id: "two", task: "two", paths: ["src/file.ex"], tools: ["write"])
    ]

    assert {:error, {:overlapping_scopes, "one", "two"}} =
             Writers.start(
               ctx.parent,
               plans,
               options(fn _, _ -> flunk("factory must not run") end, ctx)
             )

    refute File.exists?(Path.join(elem(ctx.workspace, 1).directory, "worktrees"))
  end

  test "a missing read does not discard subsequently verified file effects", ctx do
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep my work\n")

    plan =
      Plan.new(id: "one", task: "Create one.txt", paths: ["one.txt"], tools: ["read", "write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("probe", "read", %{"path" => "one.txt"}),
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.complete(report("one"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Read, Lemieux.Tools.Write]]}
    end

    assert {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :ready} = result} = Writers.await(group)
    assert hd(result.writers).artifact.verification["status"] == "passed"
    assert {:ok, _} = Writers.integrate(group, digests(result), :owner)
    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "a failed mutating tool remains an effect failure after a later write", ctx do
    plan =
      Plan.new(id: "one", task: "Create one.txt", paths: ["one.txt"], tools: ["edit", "write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("edit", "edit", %{
            "path" => "one.txt",
            "old" => "missing",
            "new" => "one"
          }),
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.complete(report("one"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Edit, Lemieux.Tools.Write]]}
    end

    assert {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed, writers: [writer]}} = Writers.await(group)
    assert writer.error == :failed_effect
    assert {:error, :not_ready} = Writers.integrate(group, [writer.artifact.digest], :owner)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  test "a rejected no-op edit does not discard independently verified effects", ctx do
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep my work\n")

    plan =
      Plan.new(id: "one", task: "Create one.txt", paths: ["one.txt"], tools: ["edit", "write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.tool_call("noop", "edit", %{
            "path" => "one.txt",
            "old" => "one\n",
            "new" => "one\n"
          }),
          Scripted.complete(report("one"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Edit, Lemieux.Tools.Write]]}
    end

    assert {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :ready} = result} = Writers.await(group)
    assert {:ok, _} = Writers.integrate(group, digests(result), :owner)
    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "a denied no-op edit remains a hard failure", ctx do
    plan =
      Plan.new(id: "one", task: "Create one.txt", paths: ["one.txt"], tools: ["edit", "write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.tool_call("noop", "edit", %{
            "path" => "one.txt",
            "old" => "one\n",
            "new" => "one\n"
          }),
          Scripted.complete(report("one"))
        ])

      {:ok,
       [
         provider: provider,
         model: "test:model",
         tools: [Lemieux.Tools.Edit, Lemieux.Tools.Write],
         hooks: [
           before_tool_call: fn call, _ ->
             if call.name == "edit", do: {:deny, "host denied edit"}, else: :allow
           end
         ]
       ]}
    end

    assert {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed, writers: [writer]}} = Writers.await(group)
    assert writer.error == :failed_effect
    assert {:error, :not_ready} = Writers.integrate(group, [writer.artifact.digest], :owner)
    assert :ok = Writers.close(group, :owner)
  end

  test "a refused unread overwrite can be corrected before independent verification", ctx do
    plan =
      Plan.new(
        id: "one",
        task: "Update original",
        paths: ["original.txt"],
        tools: ["read", "write"]
      )

    factory = fn _, workspace ->
      provider =
        Scripted.new([
          Scripted.tool_call("unread", "write", %{
            "path" => "original.txt",
            "content" => "changed\n"
          }),
          fn _request ->
            assert File.read!(Path.join(workspace.cwd, "original.txt")) == "original\n"
            Scripted.tool_call("read", "read", %{"path" => "original.txt"})
          end,
          Scripted.tool_call("write", "write", %{
            "path" => "original.txt",
            "content" => "changed\n"
          }),
          Scripted.complete(report("updated"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Read, Lemieux.Tools.Write]]}
    end

    verify = fn workspace, _plan, _result ->
      assert File.read!(Path.join(workspace.cwd, "original.txt")) == "changed\n"
      {:ok, %{"status" => "passed", "check" => "updated original"}}
    end

    checks = fn cwd ->
      assert File.read!(Path.join(cwd, "original.txt")) == "changed\n"
      {:ok, %{"status" => "passed", "check" => "updated original"}}
    end

    opts = options(factory, ctx) |> Keyword.merge(verify: verify, checks: checks)
    assert {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert {:ok, %{status: :ready} = result} = Writers.await(group)
    assert {:ok, _} = Writers.integrate(group, digests(result), :owner)
    assert File.read!(Path.join(ctx.root, "original.txt")) == "changed\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "a refused stale overwrite can be corrected by reading the new file state", ctx do
    plan =
      Plan.new(
        id: "one",
        task: "Update original",
        paths: ["original.txt"],
        tools: ["read", "write"]
      )

    factory = fn _, workspace ->
      provider =
        Scripted.new([
          Scripted.tool_call("read-old", "read", %{"path" => "original.txt"}),
          fn _request ->
            File.write!(Path.join(workspace.cwd, "original.txt"), "formatted\n")

            Scripted.tool_call("stale", "write", %{
              "path" => "original.txt",
              "content" => "changed\n"
            })
          end,
          fn _request ->
            assert File.read!(Path.join(workspace.cwd, "original.txt")) == "formatted\n"
            Scripted.tool_call("read-new", "read", %{"path" => "original.txt"})
          end,
          Scripted.tool_call("write", "write", %{
            "path" => "original.txt",
            "content" => "changed\n"
          }),
          Scripted.complete(report("updated"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Read, Lemieux.Tools.Write]]}
    end

    evidence = %{"status" => "passed", "check" => "updated original"}

    opts =
      options(factory, ctx)
      |> Keyword.merge(
        verify: fn workspace, _, _ ->
          assert File.read!(Path.join(workspace.cwd, "original.txt")) == "changed\n"
          {:ok, evidence}
        end,
        checks: fn cwd ->
          assert File.read!(Path.join(cwd, "original.txt")) == "changed\n"
          {:ok, evidence}
        end
      )

    assert {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert {:ok, %{status: :ready} = result} = Writers.await(group)
    assert {:ok, _} = Writers.integrate(group, digests(result), :owner)
    assert :ok = Writers.close(group, :owner)
  end

  test "a host-denied write cannot be redeemed by a later successful write", ctx do
    plan = Plan.new(id: "one", task: "Create one", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("denied", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.tool_call("allowed", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.complete(report("one"))
        ])

      {:ok,
       [
         provider: provider,
         model: "test:model",
         tools: [Lemieux.Tools.Write],
         hooks: [
           before_tool_call: fn call, _ ->
             if call.id == "denied", do: {:deny, "host denied"}, else: :allow
           end
         ]
       ]}
    end

    assert {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed, writers: [writer]}} = Writers.await(group)
    assert writer.error == :failed_effect
    assert :ok = Writers.close(group, :owner)
  end

  test "an actual filesystem write failure remains fatal after a later successful write", ctx do
    plan =
      Plan.new(
        id: "one",
        task: "Update original",
        paths: ["original.txt"],
        tools: ["read", "write"]
      )

    factory = fn _, workspace ->
      path = Path.join(workspace.cwd, "original.txt")

      provider =
        Scripted.new([
          Scripted.tool_call("read", "read", %{"path" => "original.txt"}),
          fn _request ->
            File.chmod!(path, 0o400)

            Scripted.tool_call("unwritable", "write", %{
              "path" => "original.txt",
              "content" => "changed\n"
            })
          end,
          fn _request ->
            assert File.read!(path) == "original\n"
            File.chmod!(path, 0o600)

            Scripted.tool_call("write", "write", %{
              "path" => "original.txt",
              "content" => "changed\n"
            })
          end,
          Scripted.complete(report("updated"))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Read, Lemieux.Tools.Write]]}
    end

    opts =
      options(factory, ctx)
      |> Keyword.put(:verify, fn workspace, _, _ ->
        assert File.read!(Path.join(workspace.cwd, "original.txt")) == "changed\n"
        {:ok, %{"status" => "passed", "check" => "updated original"}}
      end)

    assert {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert {:ok, %{status: :failed, writers: [writer]}} = Writers.await(group)
    assert writer.error == :failed_effect
    assert :ok = Writers.close(group, :owner)
  end

  test "repository aliases resolve consistently and cannot disguise an inside lease directory",
       ctx do
    root_alias = Path.join(ctx.tmp_dir, "root-alias")
    outside_alias = Path.join(ctx.tmp_dir, "outside-alias")
    File.ln_s!(ctx.root, root_alias)
    File.ln_s!(ctx.tmp_dir, outside_alias)

    assert {Worktree, state} =
             Worktree.new(
               root: root_alias,
               directory: Path.join(outside_alias, "leases")
             )

    assert state.root == ctx.root
    assert state.directory == Path.join(ctx.tmp_dir, "leases")

    assert_raise ArgumentError, fn ->
      Worktree.new(root: ctx.root, directory: Path.join(root_alias, "leases"))
    end
  end

  test "a writer attempting an out-of-scope write fails the group", ctx do
    plan = Plan.new(id: "one", task: "write", paths: ["allowed.txt"], tools: ["write"])

    factory = fn _, _ ->
      {:ok,
       [
         provider:
           Scripted.new([
             Scripted.tool_call("bad", "write", %{
               "path" => "unauthorized.txt",
               "content" => "bad"
             }),
             Scripted.complete(report("done"))
           ]),
         model: "test:model",
         tools: [Lemieux.Tools.Write]
       ]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed}} = Writers.await(group)
    refute File.exists?(Path.join(ctx.root, "unauthorized.txt"))
    assert {:error, :not_ready} = Writers.integrate(group, [], :owner)
    assert :ok = Writers.close(group, :owner)
  end

  test "the parent and replacement writer providers consume one allowance", ctx do
    assert {:ok, _} = Session.await(ctx.parent, "parent work")
    {group, result} = ready(ctx)
    assert result.budget.requests == 3
    assert Session.budget(ctx.parent).job.requests == 3
    assert :ok = Writers.close(group, :owner)
  end

  test "stale HEAD refuses integration without changing the user's checkout", ctx do
    {group, result} = ready(ctx)

    git(ctx.root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "--allow-empty",
      "-m",
      "new revision"
    ])

    assert {:error, :stale_base} = Writers.integrate(group, digests(result), :owner)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  test "dirty touched files and forged artifact digests are refused", ctx do
    {group, result} = ready(ctx)
    assert {:error, :unreviewed_artifact} = Writers.integrate(group, ["guessed"], :owner)
    File.write!(Path.join(ctx.root, "one.txt"), "my unsaved edit")

    assert {:error, {:dirty_paths, ["one.txt"]}} =
             Writers.integrate(group, digests(result), :owner)

    assert File.read!(Path.join(ctx.root, "one.txt")) == "my unsaved edit"
    assert :ok = Writers.close(group, :owner)
  end

  test "staged accepted paths are dirty even when the working copy matches HEAD", ctx do
    {group, result} = ready(ctx)
    path = Path.join(ctx.root, "one.txt")
    File.write!(path, "user staged work\n")
    git(ctx.root, ["add", "one.txt"])
    File.rm!(path)
    index = File.read!(Path.join(ctx.root, ".git/index"))

    assert {:error, {:dirty_paths, ["one.txt"]}} =
             Writers.integrate(group, digests(result), :owner)

    refute File.exists?(path)
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
    assert :ok = Writers.close(group, :owner)
  end

  test "staging an accepted path during candidate checks is refused before application", ctx do
    checks = fn _cwd ->
      path = Path.join(ctx.root, "one.txt")
      File.write!(path, "late staged work\n")
      git(ctx.root, ["add", "one.txt"])
      File.rm!(path)
      {:ok, %{"status" => "passed", "check" => "candidate"}}
    end

    {group, result} = ready(ctx, checks: checks)

    assert {:error, {:dirty_paths, ["one.txt"]}} =
             Writers.integrate(group, digests(result), :owner)

    refute File.exists?(Path.join(ctx.root, "one.txt"))

    assert {_output, 0} =
             System.cmd("git", ["diff", "--cached", "--exit-code", "--", "original.txt"],
               cd: ctx.root
             )

    assert :ok = Writers.close(group, :owner)
  end

  test "altered patch files invalidate the reviewed artifact", ctx do
    {group, result} = ready(ctx)
    File.write!(hd(result.writers).artifact.patch_path, "replaced patch")
    assert {:error, :artifact_changed} = Writers.integrate(group, digests(result), :owner)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  test "candidate checks cannot replace the reviewed patch", ctx do
    checks = fn cwd ->
      File.write!(Path.join(cwd, "one.txt"), "unreviewed replacement\n")
      {:ok, %{"status" => "passed", "check" => "mutating candidate"}}
    end

    {group, result} = ready(ctx, checks: checks)
    assert {:error, :candidate_changed} = Writers.integrate(group, digests(result), :owner)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  test "a retained patch reconstructs a pruned artifact tree without changing the user's index",
       ctx do
    File.write!(Path.join(ctx.root, "original.txt"), "staged edit\n")
    git(ctx.root, ["add", "original.txt"])
    File.write!(Path.join(ctx.root, "original.txt"), "unstaged edit\n")
    index_path = Path.join(ctx.root, ".git/index")
    index = File.read!(index_path)
    {group, result} = ready(ctx)
    artifact = hd(result.writers).artifact
    <<prefix::binary-size(2), rest::binary>> = artifact.tree
    object_path = Path.join([ctx.root, ".git", "objects", prefix, rest])
    assert :ok = File.rm(object_path)
    refute Git.object?(ctx.root, artifact.tree)

    assert {:ok, %{status: :integrated}} = Writers.integrate(group, digests(result), :owner)
    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert File.read!(Path.join(ctx.root, "original.txt")) == "unstaged edit\n"
    assert File.read!(index_path) == index
    assert Git.object?(ctx.root, artifact.tree)
    assert :ok = Writers.close(group, :owner)
  end

  test "a scoped writer cannot follow a symlink into the primary checkout", ctx do
    plan = Plan.new(id: "one", task: "write", paths: ["alias/"], tools: ["write"])

    factory = fn _, workspace ->
      File.ln_s!(ctx.root, Path.join(workspace.cwd, "alias"))

      {:ok,
       [
         provider:
           Scripted.new([
             Scripted.tool_call("write", "write", %{
               "path" => "alias/original.txt",
               "content" => "escaped write"
             }),
             Scripted.complete(report("one"))
           ]),
         model: "test:model",
         tools: [Lemieux.Tools.Write]
       ]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed}} = Writers.await(group)
    assert File.read!(Path.join(ctx.root, "original.txt")) == "original\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "ignored host files and generated check output do not prevent reviewed integration", ctx do
    File.write!(Path.join(ctx.root, ".gitignore"), "_build/\n.env\n")
    git(ctx.root, ["add", ".gitignore"])

    git(ctx.root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "ignore build and credentials"
    ])

    {module, state} = ctx.workspace
    ctx = %{ctx | workspace: Worktree.new(root: ctx.root, directory: state.directory)}
    assert module == Worktree
    File.write!(Path.join(ctx.root, ".env"), "host private configuration\n")
    File.mkdir_p!(Path.join(ctx.root, "_build"))
    File.write!(Path.join(ctx.root, "_build/cache"), "host cache")

    generate = fn cwd ->
      if cwd != ctx.root do
        File.mkdir_p!(Path.join(cwd, "_build"))
        File.write!(Path.join(cwd, "_build/cache"), "generated by check")
      end

      {:ok, %{"status" => "passed", "check" => "generated build output"}}
    end

    {group, result} =
      ready(ctx,
        verify: fn workspace, _, _ -> generate.(workspace.cwd) end,
        checks: generate
      )

    assert {:ok, %{status: :integrated}} = Writers.integrate(group, digests(result), :owner)
    assert File.read!(Path.join(ctx.root, ".env")) == "host private configuration\n"
    assert File.read!(Path.join(ctx.root, "_build/cache")) == "host cache"
    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "failed post-application checks roll back accepted paths and preserve unrelated edits",
       ctx do
    checks = fn cwd ->
      assert File.read!(Path.join(cwd, "one.txt")) == "one\n"

      if cwd == ctx.root,
        do: {:error, :project_check_failed},
        else: {:ok, %{"status" => "passed", "check" => "candidate"}}
    end

    {group, result} = ready(ctx, checks: checks)
    assert {:error, :project_check_failed} = Writers.integrate(group, digests(result), :owner)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "an ignored deliverable is a capture failure and remains available for inspection", ctx do
    plan = Plan.new(id: "one", task: "write", paths: ["one.txt"], tools: ["write"])
    {module, state} = ctx.workspace

    task =
      Task.async(fn ->
        {:ok, workspace} = module.prepare(state, "ignored-fixture", plan)
        File.write!(Path.join(workspace.cwd, ".gitignore"), "one.txt\n")
        File.write!(Path.join(workspace.cwd, "one.txt"), "ignored effect\n")
        result = %{session_id: "fixture", entries: [], report: JSON.decode!(report("one"))}
        evidence = %{"status" => "passed", "check" => "fixture"}
        {workspace, module.export(state, workspace, plan, result, evidence)}
      end)

    monitor = Process.monitor(task.pid)

    assert {workspace, {:error, {:uncaptured_files, [%{path: "one.txt", why: :ignored}]}}} =
             Task.await(task, :infinity)

    assert_receive {:DOWN, ^monitor, :process, _, :normal}

    assert {:ok, [%{"result" => "{:error, :uncaptured_work}"}]} = Worktree.reap(ctx.workspace)
    assert File.read!(Path.join(workspace.cwd, "one.txt")) == "ignored effect\n"
    assert :ok = module.release(state, workspace)
  end

  test "a crashed integration check releases the parent's busy registration", ctx do
    checks = fn _cwd -> exit(:intentional_check_failure) end
    {group, result} = ready(ctx, checks: checks)

    capture_log(fn ->
      assert {:error, {:integration_interrupted, :intentional_check_failure}} =
               Writers.integrate(group, digests(result), :owner)

      assert Session.info(ctx.parent).status == :idle
      assert {:ok, %{status: :failed}} = Writers.snapshot(group)
      refute File.exists?(Path.join(ctx.root, "one.txt"))
      assert :ok = Writers.close(group, :owner)
    end)
  end

  test "a post-application check exit rolls back and identifies the transaction", ctx do
    checks = fn cwd ->
      if cwd == ctx.root,
        do: exit(:intentional_check_failure),
        else: {:ok, %{"status" => "passed", "check" => "candidate"}}
    end

    {group, result} = ready(ctx, checks: checks)

    assert {:error, {:integration_interrupted, key, {:exit, :intentional_check_failure}}} =
             Writers.integrate(group, digests(result), :owner)

    {_module, state} = ctx.workspace
    assert {:ok, %{value: %{"status" => "rolled_back"}}} = Journal.read(state.journal, key)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert Session.info(ctx.parent).status == :idle
    assert {:ok, %{integration: %{"transaction_id" => ^key}}} = Writers.snapshot(group)
    assert :ok = Writers.close(group, :owner)
  end

  test "raised and thrown post-application checks roll back", ctx do
    for {kind, reason, crash} <- [
          {:error, %RuntimeError{message: "check crashed"}, fn -> raise "check crashed" end},
          {:throw, :check_thrown, fn -> throw(:check_thrown) end}
        ] do
      checks = fn cwd ->
        if cwd == ctx.root,
          do: crash.(),
          else: {:ok, %{"status" => "passed", "check" => "candidate"}}
      end

      {group, result} = ready(ctx, checks: checks)

      assert {:error, {:integration_interrupted, key, {^kind, ^reason}}} =
               Writers.integrate(group, digests(result), :owner)

      {_module, state} = ctx.workspace
      assert {:ok, %{value: %{"status" => "rolled_back"}}} = Journal.read(state.journal, key)
      refute File.exists?(Path.join(ctx.root, "one.txt"))
      assert :ok = Writers.close(group, :owner)
    end
  end

  test "a post-application exception preserves foreign edits and exposes blocked recovery", ctx do
    checks = fn cwd ->
      if cwd == ctx.root do
        File.write!(Path.join(cwd, "one.txt"), "foreign edit\n")
        raise "check crashed"
      end

      {:ok, %{"status" => "passed", "check" => "candidate"}}
    end

    {group, result} = ready(ctx, checks: checks)

    assert {:error,
            {:integration_unresolved, key,
             {:error, {:integration_interrupted, key, {:error, %RuntimeError{}}}},
             {:error, :foreign_changes}}} = Writers.integrate(group, digests(result), :owner)

    assert {:ok, %{integration: %{"transaction_id" => ^key}}} = Writers.snapshot(group)
    assert File.read!(Path.join(ctx.root, "one.txt")) == "foreign edit\n"
    assert {:error, :foreign_changes} = Worktree.recover(ctx.workspace, key)

    assert {:error, {:unresolved_integration, ^key}} =
             Writers.integrate(group, digests(result), :owner)

    assert :ok = Writers.close(group, :owner)
  end

  @tag timeout: :timer.minutes(3)
  test "cold runtime loss recovers prepared and applied transactions but retains committed work",
       ctx do
    for phase <- ["prepared", "applied", "rollback", "integrated"] do
      root = Path.join(Path.dirname(ctx.root), "cold-#{phase}")
      git(ctx.root, ["clone", "--quiet", ctx.root, root])
      File.chmod!(Path.join(root, "original.txt"), 0o600)
      index = File.read!(Path.join(root, ".git/index"))
      directory = Path.join(Path.dirname(ctx.root), "leases-#{phase}")
      adapter = Worktree.new(root: root, directory: directory)
      key = kill_runtime(root, directory, phase)

      assert :ok = Worktree.recover(adapter, key)
      {_module, state} = adapter
      assert {:ok, %{value: value}} = Journal.read(state.journal, key)

      if phase == "integrated" do
        assert value["status"] == "integrated"
        assert File.read!(Path.join(root, "original.txt")) == "updated\n"
        assert File.read!(Path.join(root, "one.txt")) == "one\n"
      else
        assert value["status"] == "rolled_back"
        assert File.read!(Path.join(root, "original.txt")) == "original\n"
        assert Bitwise.band(File.stat!(Path.join(root, "original.txt")).mode, 0o777) == 0o600
        refute File.exists?(Path.join(root, "one.txt"))
      end

      assert File.read!(Path.join(root, ".git/index")) == index
    end
  end

  test "cold recovery refuses foreign edits without changing either accepted path", ctx do
    {_module, state} = ctx.workspace
    key = kill_runtime(ctx.root, state.directory, "applied")
    File.write!(Path.join(ctx.root, "one.txt"), "foreign edit\n")
    assert {:error, :foreign_changes} = Worktree.recover(ctx.workspace, key)
    assert File.read!(Path.join(ctx.root, "one.txt")) == "foreign edit\n"
    assert File.read!(Path.join(ctx.root, "original.txt")) == "updated\n"
    assert {:ok, %{value: %{"status" => "blocked"}}} = Journal.read(state.journal, key)
  end

  test "cold recovery restores a mix of before and after images after partial application", ctx do
    {_module, state} = ctx.workspace
    key = kill_runtime(ctx.root, state.directory, "prepared")
    File.write!(Path.join(ctx.root, "one.txt"), "one\n")
    assert File.read!(Path.join(ctx.root, "original.txt")) == "original\n"
    assert :ok = Worktree.recover(ctx.workspace, key)
    assert File.read!(Path.join(ctx.root, "original.txt")) == "original\n"
    refute File.exists?(Path.join(ctx.root, "one.txt"))
  end

  test "rollback restores exact original bytes when Git normalizes line endings", ctx do
    File.write!(Path.join(ctx.root, ".gitattributes"), "original.txt text eol=crlf\n")
    git(ctx.root, ["add", ".gitattributes"])

    git(ctx.root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "fixture line endings"
    ])

    original = "original\r\n"
    File.write!(Path.join(ctx.root, "original.txt"), original)
    File.chmod!(Path.join(ctx.root, "original.txt"), 0o600)
    {_module, old_state} = ctx.workspace
    {module, state} = Worktree.new(root: ctx.root, directory: old_state.directory)
    plan = Plan.new(id: "one", task: "update", paths: ["original.txt"], tools: ["write"])
    assert {:ok, isolated} = module.prepare(state, "crlf-fixture", plan)
    File.write!(Path.join(isolated.cwd, "original.txt"), "updated\r\n")
    result = %{session_id: "fixture", entries: [], report: JSON.decode!(report("one"))}
    evidence = %{"status" => "passed", "check" => "fixture"}
    assert {:ok, artifact} = module.export(state, isolated, plan, result, evidence)
    assert :ok = module.release(state, isolated)

    checks = fn cwd ->
      if cwd == ctx.root do
        assert File.read!(Path.join(cwd, "original.txt")) == "updated\r\n"
        {:error, :project_check_failed}
      else
        File.write!(Path.join(cwd, "original.txt"), "updated\r\n")
        {:ok, evidence}
      end
    end

    assert {:error, :project_check_failed} =
             module.integrate(state, [artifact], checks, fn -> :ok end)

    assert File.read!(Path.join(ctx.root, "original.txt")) == original
    assert Bitwise.band(File.stat!(Path.join(ctx.root, "original.txt")).mode, 0o777) == 0o600
  end

  test "parent cancellation interrupts integration and its guardian restores accepted paths",
       ctx do
    observer = self()
    {module, state} = ctx.workspace

    workspace =
      {module, %{state | journal: {ObservingJournal, %{journal: state.journal, owner: observer}}}}

    ctx = %{ctx | workspace: workspace}

    checks = fn cwd ->
      if cwd == ctx.root do
        send(observer, {:checking_primary, self()})

        receive do
          :finish -> :ok
        end
      end

      {:ok, %{"status" => "passed", "check" => "held check"}}
    end

    {group, result} = ready(ctx, checks: checks)
    waiter = Task.async(fn -> Writers.integrate(group, digests(result), :owner) end)
    assert_receive {:checking_primary, _worker}
    assert_receive {:transaction, key, "prepared"}
    assert :ok = Session.cancel(ctx.parent)
    assert {:error, :cancelled} = Task.await(waiter)
    assert_receive {:transaction, ^key, "rolled_back"}
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "killing the integration task leaves the guardian able to restore primary files", ctx do
    observer = self()
    {module, state} = ctx.workspace
    journal = {ObservingJournal, %{journal: state.journal, owner: observer}}
    ctx = %{ctx | workspace: {module, %{state | journal: journal}}}

    checks = fn cwd ->
      if cwd == ctx.root do
        send(observer, {:checking_primary, self()})
        receive do: (:finish -> :ok)
      end

      {:ok, %{"status" => "passed", "check" => "held check"}}
    end

    {group, result} = ready(ctx, checks: checks)
    waiter = Task.async(fn -> Writers.integrate(group, digests(result), :owner) end)
    assert_receive {:checking_primary, worker}
    assert_receive {:transaction, key, "prepared"}
    Process.exit(worker, :kill)
    assert {:error, {:integration_interrupted, :killed}} = Task.await(waiter, :infinity)
    assert_receive {:transaction, ^key, "rolled_back"}
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep my work\n"
    assert Session.info(ctx.parent).status == :idle
    assert :ok = Writers.close(group, :owner)
  end

  test "a foreign edit during failed checks stays blocked rather than being overwritten", ctx do
    checks = fn cwd ->
      if cwd == ctx.root do
        File.write!(Path.join(cwd, "one.txt"), "concurrent user edit")
        {:error, :failed}
      else
        {:ok, %{"status" => "passed", "check" => "candidate"}}
      end
    end

    {group, result} = ready(ctx, checks: checks)

    assert {:error, {:integration_unresolved, key, {:error, :failed}, {:error, :foreign_changes}}} =
             Writers.integrate(group, digests(result), :owner)

    assert File.read!(Path.join(ctx.root, "one.txt")) == "concurrent user edit"

    assert {:error, {:unresolved_integration, ^key}} =
             Writers.integrate(group, digests(result), :owner)

    assert {:error, :foreign_changes} = Worktree.recover(ctx.workspace, key)
    assert :ok = Writers.close(group, :owner)
  end

  test "cancellation during preparation kills the factory and releases only its owned worktree",
       ctx do
    observer = self()
    plan = Plan.new(id: "one", task: "work", paths: ["one.txt"], tools: ["write"])

    factory = fn _plan, workspace ->
      send(observer, {:factory_waiting, self(), workspace.cwd})

      receive do
        :finish -> {:error, :should_not_finish}
      end
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert_receive {:factory_waiting, worker, cwd}
    monitor = Process.monitor(worker)
    assert File.exists?(cwd)
    assert {:error, :unauthorized} = Writers.cancel(group, :stranger)
    assert :ok = Writers.cancel(group, :owner)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:ok, %{status: :cancelled, budget: %{requests: 0}}} = Writers.await(group)
    refute File.exists?(cwd)
    assert File.read!(Path.join(ctx.root, "original.txt")) == "original\n"
    assert :ok = Writers.close(group, :owner)
  end

  test "coordinator loss cleans a held writer and removes the parent's busy registration", ctx do
    observer = self()
    plan = Plan.new(id: "one", task: "work", paths: ["one.txt"], tools: ["write"])

    factory = fn _plan, workspace ->
      provider =
        Scripted.new([
          fn _request ->
            send(observer, {:provider_waiting, self(), workspace.cwd})

            receive do
              :finish -> Scripted.complete(report("one"))
            end
          end
        ])

      {:ok, [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write]]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert_receive {:provider_waiting, provider_worker, cwd}
    monitor = Process.monitor(provider_worker)
    custody = :sys.get_state(group.pid).custody
    custody_monitor = Process.monitor(custody)
    assert Session.info(ctx.parent).status == :busy
    Process.exit(group.pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^provider_worker, _}
    assert_receive {:DOWN, ^custody_monitor, :process, ^custody, _}
    LemieuxTest.Sync.state(ctx.parent, &(&1.subagent_groups == %{}))
    assert Session.info(ctx.parent).status == :idle
    refute File.exists?(cwd)
  end

  test "the composed deadline cancels held preparation without spending", ctx do
    clock = start_supervised!(Manual)
    observer = self()
    plan = Plan.new(id: "one", task: "work", paths: ["one.txt"], tools: ["write"])

    factory = fn _plan, workspace ->
      send(observer, {:factory_waiting, self(), workspace.cwd})

      receive do
        :finish -> {:error, :should_not_finish}
      end
    end

    opts = options(factory, ctx) |> Keyword.merge(clock: clock, timeout_ms: 60_000)
    {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert_receive {:factory_waiting, _worker, cwd}
    Manual.advance(clock, 60_000, settle: group.pid)
    assert {:ok, %{status: :timed_out, budget: %{requests: 0}}} = Writers.await(group)
    refute File.exists?(cwd)
    assert :ok = Writers.close(group, :owner)
  end

  test "complete critical findings survive cleanup and remain tied to the transcript", ctx do
    findings = [
      %{"path" => "original.txt", "finding" => "critical detail " <> String.duplicate("x", 4000)}
    ]

    {group, result} =
      ready(ctx,
        report:
          JSON.encode!(%{
            "summary" => "one",
            "critical_findings" => findings,
            "uncertainties" => ["needs review"]
          })
      )

    artifact = hd(result.writers).artifact
    assert {:ok, saved} = JSON.decode(File.read!(artifact.report_path))
    assert saved["report"]["critical_findings"] == findings
    assert saved["report"]["uncertainties"] == ["needs review"]
    assert saved["transcript_id"] == hd(result.writers).transcript_id
    assert saved["entry_ids"] != []
    assert :ok = Writers.close(group, :owner)
    assert File.exists?(artifact.patch_path)
  end

  test "ungranted shell tools are refused before any writer inference", ctx do
    plan = Plan.new(id: "one", task: "work", paths: ["one.txt"], tools: ["bash"])

    factory = fn _, _ ->
      {:ok, [provider: Scripted.new([]), model: "test:model", tools: [Lemieux.Tools.Bash]]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))

    assert {:ok,
            %{
              status: :failed,
              writers: [%{error: :tool_permissions_not_granted}],
              budget: %{requests: 0}
            }} = Writers.await(group)

    assert :ok = Writers.close(group, :owner)
  end

  test "scope validation includes filesystem ancestor and case collisions", ctx do
    assert_raise ArgumentError, fn ->
      Plan.new(id: "x", task: "x", paths: ["../escape"], tools: ["write"])
    end

    assert_raise ArgumentError, fn ->
      Plan.new(id: "x", task: "x", paths: [".Git/config"], tools: ["write"])
    end

    assert {:error, :invalid_briefs} = Writers.start(ctx.parent, [:bad], [])
    left = Plan.new(id: "one", task: "one", paths: ["A"], tools: ["write"])
    right = Plan.new(id: "two", task: "two", paths: ["a/child"], tools: ["write"])

    assert {:error, {:overlapping_scopes, "one", "two"}} =
             Writers.start(ctx.parent, [left, right], [])
  end

  test "orphan leases are durably reaped while live owners and artifacts are retained", ctx do
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])
    {module, state} = ctx.workspace
    assert {:ok, live} = module.prepare(state, "live", plan)
    assert {:ok, receipts} = Worktree.reap(ctx.workspace)
    assert Enum.any?(receipts, &(&1["id"] == live.id and &1["result"] != ":ok"))
    assert File.exists?(live.cwd)
    assert :ok = module.release(state, live)
    owner = Task.async(fn -> module.prepare(state, "orphan", plan) end)
    monitor = Process.monitor(owner.pid)
    assert {:ok, orphan} = Task.await(owner)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert File.exists?(orphan.cwd)
    assert {:ok, receipts} = Worktree.reap(ctx.workspace)
    assert %{"id" => orphan.id, "result" => ":ok"} in receipts
    refute File.exists?(orphan.cwd)
    assert File.read!(Path.join(ctx.root, "original.txt")) == "original\n"
  end

  test "factory options cannot replace the parent's inclusive ledger", ctx do
    {:ok, parent} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        cwd: ctx.root,
        provider: Scripted.new([]),
        model: "test:model",
        tools: [],
        job_limits: [max_requests: 1]
      )

    other_budget = start_supervised!({Lemieux.JobBudget, max_requests: 100})
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      {:ok,
       [
         provider:
           Scripted.new([
             Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
             Scripted.complete(report("one"))
           ]),
         model: "test:model",
         tools: [Lemieux.Tools.Write],
         job_budget: other_budget,
         job_limits: [max_requests: 100]
       ]}
    end

    {:ok, group} = Writers.start(parent, [plan], options(factory, ctx))
    assert {:ok, %{status: :failed, budget: %{requests: 1}}} = Writers.await(group)
    assert %{requests: 0} = Lemieux.JobBudget.snapshot(other_budget)
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(group, :owner)
  end

  test "revoked dispatch authority stops before a writer model request", ctx do
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])
    provider = Scripted.new([Scripted.complete(report("one"))])

    factory = fn _, _ ->
      {:ok, [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write]]}
    end

    authorize = fn
      :dispatch, _, _ -> {:error, :revoked}
      _, _, :owner -> :ok
    end

    opts = options(factory, ctx) |> Keyword.put(:authorize, authorize)
    {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert {:ok, %{status: :failed, budget: %{requests: 0}}} = Writers.await(group)
    assert Scripted.requests(provider) == []
    assert :ok = Writers.close(group, :owner)
  end

  test "timed-out observers withdraw without cancelling held work", ctx do
    observer = self()
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      send(observer, :held_factory)

      receive do
        :finish -> {:error, :unused}
      end
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert_receive :held_factory
    assert {:error, :timeout} = Writers.await(group, 0)
    assert {:ok, %{status: :running}} = Writers.snapshot(group)
    assert :sys.get_state(group.pid).waiters == %{}
    assert :ok = Writers.cancel(group, :owner)
    assert :ok = Writers.close(group, :owner)
  end

  test "generic work registrations refuse replacement and clear dead owners", ctx do
    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(owner)
    assert :ok = Session.register_work_owner(ctx.parent, "work", owner)
    assert {:error, :already_registered} = Session.register_work_owner(ctx.parent, "work", self())
    assert Session.info(ctx.parent).status == :busy
    send(owner, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    LemieuxTest.Sync.state(ctx.parent, &(&1.subagent_groups == %{}))
    assert Session.info(ctx.parent).status == :idle
    assert :ok = Session.unregister_work_owner(ctx.parent, "work")
  end

  test "failed verification retains the full patch and critical findings without allowing integration",
       ctx do
    verify = fn _, _, _ -> {:error, :project_tests_failed} end
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep my work\n")
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      {:ok,
       [
         provider:
           Scripted.new([
             Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
             Scripted.complete(
               JSON.encode!(%{
                 "summary" => "one",
                 "critical_findings" => ["important finding"],
                 "uncertainties" => []
               })
             )
           ]),
         model: "test:model",
         tools: [Lemieux.Tools.Write]
       ]}
    end

    opts = options(factory, ctx) |> Keyword.put(:verify, verify)
    {:ok, group} = Writers.start(ctx.parent, [plan], opts)
    assert {:ok, %{status: :failed, writers: [writer]}} = Writers.await(group)
    assert writer.error == {:verification_failed, :project_tests_failed}
    assert writer.artifact.verification["status"] == "failed"
    saved = writer.artifact.report_path |> File.read!() |> JSON.decode!()
    assert saved["report"]["critical_findings"] == ["important finding"]
    assert File.read!(writer.artifact.patch_path) =~ "+one"
    assert {:error, :not_ready} = Writers.integrate(group, [writer.artifact.digest], :owner)
    assert :ok = Writers.close(group, :owner)
  end

  test "cold cleanup retains changed leases without a saved patch", ctx do
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])
    {module, state} = ctx.workspace

    owner =
      Task.async(fn ->
        {:ok, workspace} = module.prepare(state, "orphan", plan)
        File.write!(Path.join(workspace.cwd, "one.txt"), "unfinished change")
        workspace
      end)

    monitor = Process.monitor(owner.pid)
    workspace = Task.await(owner)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert {:ok, receipts} = Worktree.reap(ctx.workspace)
    assert %{"id" => workspace.id, "result" => "{:error, :uncaptured_work}"} in receipts
    assert File.read!(Path.join(workspace.cwd, "one.txt")) == "unfinished change"
    # Explicit fixture cleanup after inspecting the retained work.
    assert :ok = module.release(state, workspace)
  end

  test "cancellation after a file effect preserves an unverified patch before cleanup", ctx do
    observer = self()
    plan = Plan.new(id: "one", task: "one", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          fn _ ->
            send(observer, :after_effect)

            receive do
              :finish -> Scripted.complete(report("one"))
            end
          end
        ])

      {:ok, [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write]]}
    end

    {:ok, group} = Writers.start(ctx.parent, [plan], options(factory, ctx))
    assert_receive :after_effect
    assert :ok = Writers.cancel(group, :owner)
    assert {:ok, %{status: :cancelled, writers: [writer]}} = Writers.await(group)
    assert writer.artifact.verification["status"] == "unverified"
    assert File.read!(writer.artifact.patch_path) =~ "+one"
    saved = writer.artifact.report_path |> File.read!() |> JSON.decode!()
    assert saved["report"]["critical_findings_unavailable"]
    assert :ok = Writers.close(group, :owner)
  end

  test "a cancelled owner's late release cannot erase a newer registration", ctx do
    old =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    new =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Session.register_work_owner(ctx.parent, "reused", old)
    assert :ok = Session.cancel(ctx.parent)
    assert :ok = Session.register_work_owner(ctx.parent, "reused", new)
    assert {:error, :owner_changed} = Session.unregister_work_owner(ctx.parent, "reused", old)
    assert Session.info(ctx.parent).status == :busy
    assert :ok = Session.unregister_work_owner(ctx.parent, "reused", new)
    send(old, :stop)
    send(new, :stop)
    assert Session.info(ctx.parent).status == :idle
  end

  defp ready(ctx, extra \\ []) do
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep my work\n")
    plan = Plan.new(id: "one", task: "Create one.txt", paths: ["one.txt"], tools: ["write"])

    factory = fn _, _ ->
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => "one\n"}),
          Scripted.complete(Keyword.get(extra, :report, report("one")))
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write], compact_at: nil]}
    end

    {:ok, group} =
      Writers.start(
        ctx.parent,
        [plan],
        Keyword.merge(options(factory, ctx), Keyword.delete(extra, :report))
      )

    assert {:ok, result} = Writers.await(group)
    assert result.status == :ready
    {group, result}
  end

  defp kill_runtime(root, directory, phase) do
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    arguments =
      ["--erl", "+S 2:2"] ++
        paths ++ ["test/fixtures/writer_runtime_loss.ex", root, directory, phase]

    port =
      Port.open({:spawn_executable, System.find_executable("elixir")}, [
        :binary,
        :exit_status,
        args: arguments
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    assert_receive {^port, {:data, bytes}}
    %{"transaction_id" => key, "os_pid" => os_pid} = JSON.decode!(String.trim(bytes))
    assert {_output, 0} = System.cmd("kill", ["-KILL", os_pid], stderr_to_stdout: true)
    assert_receive {^port, {:exit_status, status}}
    assert status != 0
    key
  end

  defp digests(result), do: Enum.map(result.writers, & &1.artifact.digest)

  defp options(factory, ctx) do
    [
      workspace: ctx.workspace,
      factory: factory,
      authorize: fn _action, _context, principal ->
        if principal == :owner, do: :ok, else: {:error, :unauthorized}
      end,
      authority: :owner,
      verify: fn workspace, plan, _result ->
        assert File.read!(Path.join(workspace.cwd, "#{plan.id}.txt")) == "#{plan.id}\n"
        {:ok, %{"status" => "passed", "check" => "fixture contents"}}
      end,
      checks: fn cwd ->
        assert File.read!(Path.join(cwd, "unrelated.txt")) == "keep my work\n"
        {:ok, %{"status" => "passed", "check" => "integration fixture"}}
      end
    ]
  end

  defp report(summary),
    do: JSON.encode!(%{"summary" => summary, "critical_findings" => [], "uncertainties" => []})

  defp git(cwd, args) do
    assert {_output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
  end
end
