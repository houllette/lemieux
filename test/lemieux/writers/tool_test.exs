defmodule Lemieux.Writers.ToolTest do
  use ExUnit.Case, async: true
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Writers
  alias Lemieux.Writers.Tool
  alias Lemieux.Writers.Worktree
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "repo")
    File.mkdir_p!(root)
    git(root, ["init", "--quiet"])
    File.write!(Path.join(root, "base.txt"), "base\n")
    git(root, ["add", "."])

    git(root, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "base"
    ])

    runtime = :"writer_tool_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(Path.join(dir, "sessions"))
    policy = start_supervised!({Agent, fn -> :allow end})
    observer = self()

    factory = fn plan, _workspace ->
      send(observer, {:factory, plan})

      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{
            "path" => hd(plan.paths),
            "content" => plan.id <> "\n"
          }),
          Scripted.complete(
            JSON.encode!(%{
              "summary" => plan.id,
              "critical_findings" => ["keep this finding"],
              "uncertainties" => []
            })
          )
        ])

      {:ok,
       [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write], compact_at: nil]}
    end

    options = [
      workspace: Worktree.new(root: root, directory: Path.join(dir, "writers")),
      factory: factory,
      authority: :owner,
      authorize: fn _action, _context, :owner ->
        if Agent.get(policy, & &1) == :allow, do: :ok, else: {:error, :revoked}
      end,
      verify: fn w, p, _r ->
        if File.read!(Path.join(w.cwd, hd(p.paths))) == p.id <> "\n",
          do: {:ok, %{"status" => "passed", "check" => "exact bytes"}},
          else: {:error, :bad_bytes}
      end,
      checks: fn _cwd -> {:ok, %{"status" => "passed", "check" => "fixture integration"}} end
    ]

    assert {:ok, tool} =
             Tool.new(
               paths: ["one.txt", "two.txt"],
               tools: ["write"],
               options: options,
               max_requests: 3,
               max_batches: 1
             )

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: runtime,
        store: store,
        cwd: root,
        provider: Scripted.new([Scripted.complete("parent")]),
        model: "test:model",
        tools: [tool],
        job_limits: [max_requests: 20]
      )

    %{
      root: root,
      parent: parent,
      tool: tool,
      options: options,
      policy: policy,
      runtime: runtime,
      store: store,
      context: %{
        session: parent,
        session_id: Session.info(parent).id,
        tool_output_bytes: 30_000,
        deadline_ms: 60_000
      }
    }
  end

  test "bounded briefs retain interfaces, patches and complete findings before guarded integration",
       ctx do
    result = call(ctx, start_args())
    assert result["status"] in ["running", "ready"]
    assert_receive {:factory, plan}
    assert plan.max_requests == 3
    assert plan.tools == ["write"]
    assert plan.task =~ "Stable API"
    assert plan.task =~ "Check exact bytes"
    assert {:ok, ref} = Writers.current(ctx.parent)
    assert {:ok, ready} = Writers.await(ref)
    digest = hd(ready.writers).artifact.digest
    refute File.exists?(Path.join(ctx.root, "one.txt"))

    assert {:error, ":complete_review_required"} =
             run(ctx, %{"action" => "integrate", "batch_id" => ref.id, "digests" => [digest]})

    for kind <- ["patch", "report"] do
      page =
        call(ctx, %{
          "action" => "review",
          "batch_id" => ref.id,
          "digest" => digest,
          "kind" => kind
        })

      assert page["next_offset"] == nil
      if kind == "report", do: assert(page["text"] =~ "keep this finding")
    end

    integrated =
      call(ctx, %{"action" => "integrate", "batch_id" => ref.id, "digests" => [digest]})

    assert integrated["status"] == "integrated"
    assert integrated["budget"]["requests"] == 2
    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert call(ctx, %{"action" => "close", "batch_id" => ref.id})["status"] == "closed"
    assert {:error, ":batch_limit"} = run(ctx, start_args())

    assert {:ok, %{value: %{"attempts" => [choice]}}} =
             Session.document(ctx.parent, "lemieux.writer_dispatch")

    assert choice["reason"] == "Independent patch"
  end

  test "model cannot broaden scope, tools, concurrency or host policy", ctx do
    for args <- [
          Map.put(start_args(), "authority", :owner),
          Map.put(start_args(), "max_active", 4),
          put_in(start_args(), ["tasks", Access.at(0), "paths"], ["../outside"]),
          put_in(start_args(), ["tasks", Access.at(0), "paths"], ["base.txt"]),
          put_in(start_args(), ["tasks", Access.at(0), "tools"], ["bash"])
        ] do
      assert {:error, _reason} = run(ctx, args)
    end

    refute_receive {:factory, _}, 20
    assert {:error, :not_running} = Writers.current(ctx.parent)
  end

  test "overlapping ownership fails before dispatch", ctx do
    args = Map.put(start_args(), "tasks", [task("one"), task("two", "one.txt")])
    assert {:error, error} = run(ctx, args)
    assert error =~ "overlapping_scopes"
    refute_receive {:factory, _}, 20
  end

  test "current host revocation blocks integration after review", ctx do
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, ready} = Writers.await(ref)
    digest = hd(ready.writers).artifact.digest

    for kind <- ["patch", "report"],
        do:
          call(ctx, %{
            "action" => "review",
            "batch_id" => ref.id,
            "digest" => digest,
            "kind" => kind
          })

    Agent.update(ctx.policy, fn _ -> :deny end)

    assert {:error, ":revoked"} =
             run(ctx, %{"action" => "integrate", "batch_id" => ref.id, "digests" => [digest]})

    refute File.exists?(Path.join(ctx.root, "one.txt"))
    Agent.update(ctx.policy, fn _ -> :allow end)
    assert :ok = Writers.close(ref, :owner)
  end

  test "unknown batch and artifact ids cannot observe or integrate another batch", ctx do
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, _} = Writers.await(ref)
    assert {:error, ":unknown_batch"} = run(ctx, %{"action" => "status", "batch_id" => "other"})

    assert {:error, ":invalid_review"} =
             run(ctx, %{
               "action" => "review",
               "batch_id" => ref.id,
               "digest" => "fake",
               "kind" => "report"
             })

    assert :ok = Writers.close(ref, :owner)
  end

  test "host concurrency is a ceiling and serial does not feed earlier patches to later writers",
       ctx do
    observer = self()

    factory = fn plan, w ->
      if plan.id == "two",
        do: send(observer, {:second_sees_first, File.exists?(Path.join(w.cwd, "one.txt"))})

      ctx.options[:factory].(plan, w)
    end

    {:ok, tool} =
      Tool.new(
        paths: ctx.tool.paths,
        tools: ctx.tool.tools,
        options: Keyword.merge(ctx.options, factory: factory, max_active: 1)
      )

    ctx = %{ctx | tool: tool}

    args =
      Map.merge(start_args(), %{"strategy" => "parallel", "tasks" => [task("one"), task("two")]})

    call(ctx, args)
    {:ok, ref} = Writers.current(ctx.parent)
    assert {:ok, %{status: :ready}} = Writers.await(ref)
    assert_receive {:second_sees_first, false}
    assert :ok = Writers.close(ref, :owner)
  end

  test "parent without inclusive allowance is refused", ctx do
    {:ok, parent} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        cwd: ctx.root,
        provider: Scripted.new([]),
        model: "test:model",
        tools: [ctx.tool]
      )

    context = %{ctx.context | session: parent, session_id: Session.info(parent).id}
    assert {:error, ":shared_allowance_required"} = Tool.run(ctx.tool, start_args(), context)
    refute_receive {:factory, _}, 20
  end

  test "small output budgets cannot mark unseen review bytes complete", ctx do
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, ready} = Writers.await(ref)
    digest = hd(ready.writers).artifact.digest
    context = %{ctx.context | tool_output_bytes: 1024}

    assert {:error, ":invalid_review"} =
             Tool.run(
               ctx.tool,
               %{
                 "action" => "review",
                 "batch_id" => ref.id,
                 "digest" => digest,
                 "kind" => "patch"
               },
               context
             )

    assert {:error, ":complete_review_required"} =
             run(ctx, %{"action" => "integrate", "batch_id" => ref.id, "digests" => [digest]})

    assert :ok = Writers.close(ref, :owner)
  end

  test "ordinary agent loop dispatches, reviews and integrates through host hooks", ctx do
    observer = self()

    turn = fn request ->
      last =
        request.entries
        |> Enum.filter(&(&1.type == :tool_result and &1.payload["name"] == "writers"))
        |> List.last()

      if last do
        assert last.payload["error"] == false
        value = JSON.decode!(last.payload["output"])
        action = last.payload["arguments"]["action"]

        args =
          case action do
            "start" ->
              %{"action" => "await", "batch_id" => value["batch_id"]}

            "await" ->
              %{
                "action" => "review",
                "batch_id" => value["batch_id"],
                "digest" => hd(value["writers"])["artifact"]["digest"],
                "kind" => "patch"
              }

            "review" ->
              id = last.payload["arguments"]["batch_id"]

              if last.payload["arguments"]["kind"] == "patch",
                do: %{
                  "action" => "review",
                  "batch_id" => id,
                  "digest" => value["digest"],
                  "kind" => "report"
                },
                else: %{
                  "action" => "integrate",
                  "batch_id" => id,
                  "digests" => [value["digest"]]
                }

            "integrate" ->
              %{"action" => "close", "batch_id" => value["batch_id"]}

            "close" ->
              nil
          end

        if args,
          do: Scripted.tool_call("next", "writers", args),
          else: Scripted.complete("Reviewed and integrated")
      else
        Scripted.tool_call("start", "writers", start_args())
      end
    end

    provider = Scripted.new(List.duplicate(turn, 8))

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        cwd: ctx.root,
        provider: provider,
        model: "test:model",
        tools: [ctx.tool],
        job_limits: [max_requests: 20],
        hooks: [
          before_tool_call: fn call, _ ->
            send(observer, {:loop_tool, call.name})
            :allow
          end
        ]
      )

    assert {:ok, %{stop_reason: :stop, error: nil, text: "Reviewed and integrated"}} =
             Session.await(parent, "Implement the independent patch")

    assert File.read!(Path.join(ctx.root, "one.txt")) == "one\n"
    assert_receive {:loop_tool, "writers"}
    assert_receive {:loop_tool, "write"}
    assert Lemieux.JobBudget.snapshot(Session.delegation_context(parent).job_budget).requests == 9
    assert length(Scripted.requests(provider)) == 7
  end

  test "outer tool approval denial prevents any allocation and permits direct fallback", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("start", "writers", start_args()),
        Scripted.complete("Work directly instead")
      ])

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        cwd: ctx.root,
        provider: provider,
        model: "test:model",
        tools: [ctx.tool],
        job_limits: [max_requests: 20],
        hooks: [before_tool_call: fn _call, _ -> {:deny, "writers are unavailable"} end]
      )

    assert {:ok, %{stop_reason: :stop, text: "Work directly instead"} = result} =
             Session.await(parent, "Implement")

    assert Enum.any?(
             result.entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )

    assert {:error, :not_running} = Writers.current(parent)
    refute_receive {:factory, _}, 20
  end

  test "inclusive request exhaustion retains failed work and prevents integration", ctx do
    {:ok, parent} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        cwd: ctx.root,
        provider: Scripted.new([]),
        model: "test:model",
        tools: [ctx.tool],
        job_limits: [max_requests: 1]
      )

    ctx = %{
      ctx
      | parent: parent,
        context: %{ctx.context | session: parent, session_id: Session.info(parent).id}
    }

    call(ctx, start_args())
    {:ok, ref} = Writers.current(parent)
    assert {:ok, %{status: :failed} = ready} = Writers.await(ref)
    assert ready.budget.requests == 1
    assert hd(ready.writers).error != nil
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    assert :ok = Writers.close(ref, :owner)
  end

  test "review pages reject skipped bytes and remain bounded through completion", ctx do
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, ready} = Writers.await(ref)
    digest = hd(ready.writers).artifact.digest
    args = %{"action" => "review", "batch_id" => ref.id, "digest" => digest, "kind" => "patch"}
    assert {:error, ":review_pages_must_be_contiguous"} = run(ctx, Map.put(args, "offset", 1))
    small = %{ctx | context: %{ctx.context | tool_output_bytes: 2200}}
    first = call(small, args)
    assert first["next_offset"] > 0
    assert byte_size(JSON.encode!(first)) < 2200
    all = pages(small, args, 0, "")
    assert all == File.read!(hd(ready.writers).artifact.patch_path)
    assert :ok = Writers.close(ref, :owner)
  end

  test "resume retains choices without restoring configured writer authority", ctx do
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, _ready} = Writers.await(ref)
    assert :ok = Writers.close(ref, :owner)
    id = Session.id(ctx.parent)

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(ctx.runtime),
        ctx.parent
      )

    assert {:ok, resumed} =
             Lemieux.resume_session(
               supervisor: ctx.runtime,
               store: ctx.store,
               provider: Scripted.new([]),
               resume: id,
               tools: []
             )

    assert {:ok, %{value: %{"attempts" => [_choice]}}} =
             Session.document(resumed, "lemieux.writer_dispatch")

    assert {:error, :not_running} = Writers.current(resumed)
    Agent.update(ctx.policy, fn _ -> :deny end)

    assert {:error, ":revoked"} =
             Tool.run(ctx.tool, start_args(), %{ctx.context | session: resumed, session_id: id})
  end

  test "an observation timeout leaves work cancellable and cancellation does not integrate",
       ctx do
    observer = self()

    factory = fn _plan, _w ->
      send(observer, :held_writer)
      provider = Scripted.new([Scripted.delayed(:timer.minutes(1), Scripted.complete("{}"))])
      {:ok, [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write]]}
    end

    {:ok, tool} =
      Tool.new(
        paths: ctx.tool.paths,
        tools: ctx.tool.tools,
        options: Keyword.put(ctx.options, :factory, factory)
      )

    ctx = %{ctx | tool: tool}
    started = call(ctx, start_args())
    assert_receive :held_writer
    args = %{"action" => "await", "batch_id" => started["batch_id"]}
    short = %{ctx | context: %{ctx.context | deadline_ms: 1001}}
    assert call(short, args)["await_timed_out"] == true

    assert call(ctx, %{"action" => "cancel", "batch_id" => started["batch_id"]})["status"] ==
             "cancelled"

    assert call(ctx, args)["status"] == "cancelled"
    refute File.exists?(Path.join(ctx.root, "one.txt"))
    call(ctx, %{"action" => "close", "batch_id" => started["batch_id"]})
  end

  defp pages(ctx, args, offset, accumulated) do
    page = call(ctx, Map.put(args, "offset", offset))
    accumulated = accumulated <> page["text"]

    if page["next_offset"],
      do: pages(ctx, args, page["next_offset"], accumulated),
      else: accumulated
  end

  test "paginated review preserves UTF-8 characters at byte boundaries", ctx do
    content = String.duplicate("α😀", 40) <> "\n"

    factory = fn _plan, _w ->
      provider =
        Scripted.new([
          Scripted.tool_call("write", "write", %{"path" => "one.txt", "content" => content}),
          Scripted.complete(
            JSON.encode!(%{
              "summary" => "unicode",
              "critical_findings" => [],
              "uncertainties" => []
            })
          )
        ])

      {:ok, [provider: provider, model: "test:model", tools: [Lemieux.Tools.Write]]}
    end

    verify = fn w, _, _ ->
      assert File.read!(Path.join(w.cwd, "one.txt")) == content
      {:ok, %{"status" => "passed", "check" => "unicode bytes"}}
    end

    {:ok, tool} =
      Tool.new(
        paths: ctx.tool.paths,
        tools: ctx.tool.tools,
        options: Keyword.merge(ctx.options, factory: factory, verify: verify)
      )

    ctx = %{ctx | tool: tool}
    call(ctx, start_args())
    {:ok, ref} = Writers.current(ctx.parent)
    {:ok, ready} = Writers.await(ref)
    digest = hd(ready.writers).artifact.digest
    small = %{ctx | context: %{ctx.context | tool_output_bytes: 2200}}

    reviewed =
      pages(
        small,
        %{"action" => "review", "batch_id" => ref.id, "digest" => digest, "kind" => "patch"},
        0,
        ""
      )

    assert reviewed == File.read!(hd(ready.writers).artifact.patch_path)
    assert reviewed =~ content
    assert :ok = Writers.close(ref, :owner)
  end

  test "multiple batches require a host factory for fresh snapshots", ctx do
    assert {:error, :fresh_workspace_factory_required} =
             Tool.new(
               paths: ctx.tool.paths,
               tools: ctx.tool.tools,
               options: ctx.options,
               max_batches: 2
             )
  end

  test "later batches see integrated changes through fresh host workspaces", ctx do
    observer = self()

    factory = fn plan, w ->
      if plan.id == "two",
        do: send(observer, {:fresh_prior_file, File.read(Path.join(w.cwd, "one.txt"))})

      ctx.options[:factory].(plan, w)
    end

    directory = elem(ctx.options[:workspace], 1).directory

    {:ok, tool} =
      Tool.new(
        paths: ctx.tool.paths,
        tools: ctx.tool.tools,
        options: Keyword.put(ctx.options, :factory, factory),
        max_batches: 2,
        workspace_factory: fn context ->
          {:ok,
           Worktree.new(
             root: context.cwd,
             directory: directory,
             source: :working_tree,
             paths: ctx.tool.paths
           )}
        end
      )

    ctx = %{ctx | tool: tool, context: Map.put(ctx.context, :cwd, ctx.root)}
    index = File.read!(Path.join(ctx.root, ".git/index"))

    for id <- ["one", "two"] do
      call(ctx, Map.put(start_args(), "tasks", [task(id)]))
      {:ok, ref} = Writers.current(ctx.parent)
      {:ok, ready} = Writers.await(ref)
      digest = hd(ready.writers).artifact.digest

      for kind <- ["patch", "report"],
          do:
            call(ctx, %{
              "action" => "review",
              "batch_id" => ref.id,
              "digest" => digest,
              "kind" => kind
            })

      assert call(ctx, %{"action" => "integrate", "batch_id" => ref.id, "digests" => [digest]})[
               "status"
             ] == "integrated"

      call(ctx, %{"action" => "close", "batch_id" => ref.id})
    end

    assert_receive {:fresh_prior_file, {:ok, "one\n"}}
    assert File.read!(Path.join(ctx.root, "two.txt")) == "two\n"
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
  end

  defp task(id, path \\ nil),
    do: %{"id" => id, "task" => "Create " <> id, "paths" => [path || id <> ".txt"]}

  defp start_args,
    do: %{
      "action" => "start",
      "strategy" => "parallel",
      "reason" => "Independent patch",
      "interfaces" => ["Stable API"],
      "checks" => ["Check exact bytes"],
      "tasks" => [task("one")]
    }

  defp run(ctx, args), do: Tool.run(ctx.tool, args, ctx.context)

  defp call(ctx, args) do
    assert {:ok, result} = run(ctx, args)
    assert JSON.decode!(result.model_text) == result.structured_content
    result.structured_content
  end

  defp git(cwd, args) do
    {output, status} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
