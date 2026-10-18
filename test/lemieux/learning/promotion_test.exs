defmodule Lemieux.Learning.PromotionTest do
  use ExUnit.Case, async: true
  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime.Evaluation, as: CLI
  alias Lemieux.Contract
  alias Lemieux.Learning.Promotion
  alias Lemieux.Learning.Promotion.Policy

  test "policies are immutable and name the host actor and authority bounds" do
    assert {:error, _} = Policy.new(%{})

    attrs = %{
      "id" => "host/task/v1",
      "actor" => "host-policy",
      "scope" => %{"id" => "project"},
      "capabilities" => ["retain", "task_local"],
      "trust" => "repository",
      "maximum_bytes" => 4096,
      "ttl_ms" => 60_000,
      "expires_at" => "2026-10-18T00:00:00Z",
      "canary" => %{"percent" => 10, "salt" => "v1", "minimum_observations" => 2}
    }

    assert {:ok, policy} = Policy.new(attrs)
    assert :ok = Policy.verify(policy)
    assert {:error, _} = Policy.verify(Map.put(policy, "actor", "another-actor"))
    assert policy["sha256"] == Contract.digest(Map.delete(policy, "sha256"))
  end

  test "the initial host state changes no effective harness" do
    base = Lemieux.Harness.new(system: "trusted instructions", tools: [])
    assert {:ok, state} = Promotion.new(base, %{"id" => "project"})
    assert state.harness == base
    assert state.grant == nil
  end

  alias Lemieux.Asset.Proposal
  alias Lemieux.Asset.Registry
  alias Lemieux.Asset.Version
  alias Lemieux.Extension.Profile
  alias Lemieux.Harness
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Learning.Promotion.Memory
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Read
  alias LemieuxTest.LessonFixtures, as: F

  @moduletag :tmp_dir
  setup do
    base =
      Harness.new(
        system: "trusted instructions",
        tools: [Override.new!(Read, description: "PERSONAL READ")],
        max_requests: 4,
        params: [temperature: 0.0],
        harness_context: %{"verification" => true, "credential_policy" => "scrub"}
      )

    {:ok, policy} =
      Policy.new(%{
        "id" => "host/v1",
        "actor" => "local-policy",
        "scope" => F.scope(),
        "capabilities" => ["retain", "task_local", "canary"],
        "trust" => "repository",
        "maximum_bytes" => 4096,
        "ttl_ms" => 60_000,
        "expires_at" => "2026-10-18T00:00:00Z",
        "canary" => %{"percent" => 100, "salt" => "fixture-v1", "minimum_observations" => 2}
      })

    baseline =
      Profile.quota(
        %{
          "execution" => "live",
          "model" => "test:model",
          "tools" => ["read"],
          "options" => %{
            "system" => "portable",
            "max_turns" => 4,
            "max_tokens" => 100,
            "temperature" => 0.0,
            "max_cost_usd" => 1.0,
            "reasoning_effort" => "default",
            "tool_descriptions" => %{}
          }
        },
        4
      )

    selected = put_in(baseline, ["options", "system"], "portable GOOD")

    bindings =
      Map.new(
        ~w(source harness environment descriptors policy verification model),
        &{&1 <> "_sha256", Contract.sha256(&1)}
      )

    runtime = Contract.sha256("effective-runtime")

    control =
      for _ <- 1..2, do: %{"score" => 0.25, "regression" => false, "verified_success" => nil}

    composition =
      for _ <- 1..2, do: %{"score" => 1.0, "regression" => false, "verified_success" => nil}

    receipt =
      seal(%{
        "schema_version" => 1,
        "kind" => "task_local_refinement",
        "decision" => "proposed",
        "bindings" => bindings,
        "source_runtime" => %{"sha256" => runtime},
        "selected_profile" => selected,
        "original_profile_sha256" => Contract.digest(baseline),
        "selected_sha256" => Contract.digest(selected),
        "qualification" => "behavioral_unconfirmed",
        "control" => control,
        "composition" => composition
      })

    confirmation =
      seal(%{
        "kind" => "independent_confirmation",
        "verdict" => "pass",
        "scope" => F.scope(),
        "content_sha256" => receipt["selected_sha256"],
        "runtime_sha256" => runtime,
        "evidence_sha256" => Contract.sha256("separate-confirmation-plan-and-traces"),
        "issued_at" => "2026-10-16T00:00:00Z",
        "expires_at" => "2026-10-18T00:00:00Z"
      })

    context = %{
      policy: policy,
      scope: F.scope(),
      base: base,
      now: ~U[2026-10-17 00:00:00Z],
      task_id: "task-a",
      runtime_sha256: runtime,
      bindings: bindings,
      refinements: [receipt["sha256"]],
      confirmations: [confirmation["sha256"]],
      lesson_context: F.context()
    }

    authority_state = start_supervised!({Agent, fn -> context end})
    authority = fn -> {:ok, Agent.get(authority_state, & &1)} end
    server = start_supervised!({Memory, base: base, scope: F.scope()})

    %{
      host: {Memory, server},
      server: server,
      authority: authority,
      authority_state: authority_state,
      context: context,
      base: base,
      request: %{mode: :task_local, baseline: baseline, refinement: receipt},
      confirmation: confirmation
    }
  end

  defp seal(map),
    do: Map.put(Map.delete(map, "sha256"), "sha256", Contract.digest(Map.delete(map, "sha256")))

  defp canary(ctx), do: Map.merge(ctx.request, %{mode: :canary, confirmation: ctx.confirmation})
  defp update_context(ctx, fun), do: Agent.update(ctx.authority_state, fun)

  defp observation(receipt, id, task, regression \\ false) do
    %{
      "id" => id,
      "version_id" => receipt["version_id"],
      "task_id" => task,
      "passed" => not regression,
      "regression" => regression,
      "trace_sha256" => Contract.sha256(id)
    }
  end

  test "automatic retention and task-local guidance reach a real Scripted session", ctx do
    store = LessonFiles.new(Path.join(ctx.tmp_dir, "lessons"), F.scope())
    lesson = F.lesson()
    assert {:ok, retained} = Promotion.retain(store, lesson, ctx.authority)
    assert retained["qualification"] == "behavioral"
    assert {:ok, ^lesson} = Lessons.read(store, lesson.id)

    assert {:ok, harness, receipt} =
             Promotion.promote(ctx.host, "local", ctx.request, ctx.authority)

    assert receipt["actor"]["policy_sha256"] == ctx.context.policy["sha256"]
    assert receipt["grant"]["qualification"] == "behavioral_unconfirmed"
    assert receipt["activation"]["action"] == "activate"
    assert harness.system =~ "GOOD"
    assert harness.max_requests == ctx.base.max_requests
    assert harness.params == ctx.base.params
    assert Tool.description(hd(harness.tools)) == "PERSONAL READ"
    assert harness.harness_context["verification"] == true
    assert harness.harness_context["credential_policy"] == "scrub"

    assert hd(harness.harness_context["resolved_assets"])["policy_sha256"] ==
             ctx.context.policy["sha256"]

    runtime = :"promotion_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    owner = self()

    provider =
      Scripted.new([
        fn request ->
          send(owner, {:actual_system, request.system})
          Scripted.complete("done")
        end
      ])

    task = %{prompt: "work", cwd: ctx.tmp_dir, timeout_ms: 5000}

    assert {:ok, %{"answer" => "done"}} =
             AgentSession.run(task,
               provider: provider,
               model: "test:model",
               supervisor: runtime,
               sessions_dir: Path.join(ctx.tmp_dir, "sessions"),
               session_options: [harness: harness]
             )

    assert_receive {:actual_system, system}
    assert system =~ "GOOD"

    assert {:ok, ^harness, ^receipt} =
             Promotion.promote(ctx.host, "local", ctx.request, ctx.authority)
  end

  test "unconfirmed or stale confirmation cannot authorize cross-task canaries", ctx do
    for request <- [
          Map.put(ctx.request, :mode, :canary),
          Map.put(
            canary(ctx),
            :confirmation,
            seal(Map.put(ctx.confirmation, "expires_at", "2026-10-16T00:00:00Z"))
          )
        ] do
      if request[:confirmation] do
        update_context(ctx, &%{&1 | confirmations: [request.confirmation["sha256"]]})
      end

      assert {:error, _} = Promotion.promote(ctx.host, "refused", request, ctx.authority)
    end

    assert Memory.snapshot(ctx.server).harness == ctx.base
    assert Memory.snapshot(ctx.server).grant == nil
  end

  test "changed profile bytes, stale runtime, scope and revoked policy refuse activation", ctx do
    changed =
      put_in(ctx.request, [:refinement, "selected_profile", "options", "system"], "forged")

    assert {:error, _} = Promotion.promote(ctx.host, "bytes", changed, ctx.authority)

    for change <- [
          %{runtime_sha256: Contract.sha256("different-runtime")},
          %{scope: %{"id" => "foreign"}},
          %{revoked: true},
          %{refinements: []},
          %{now: ~U[2026-10-18 00:00:00Z]}
        ] do
      update_context(ctx, fn _ -> Map.merge(ctx.context, change) end)
      assert {:error, _} = Promotion.promote(ctx.host, "stale", ctx.request, ctx.authority)
    end

    assert Memory.snapshot(ctx.server).grant == nil
  end

  test "repository edits cannot change personal descriptions, model, tools, or verification fields",
       ctx do
    profiles = [
      put_in(ctx.request.refinement["selected_profile"], ["options", "tool_descriptions"], %{
        "read" => "REPOSITORY READ"
      }),
      Map.put(ctx.request.refinement["selected_profile"], "tools", []),
      Map.put(ctx.request.refinement["selected_profile"], "model", "test:other"),
      put_in(ctx.request.refinement["selected_profile"], ["options", "temperature"], 1.0)
    ]

    for profile <- profiles do
      receipt =
        ctx.request.refinement
        |> Map.put("selected_profile", profile)
        |> Map.put("selected_sha256", Contract.digest(profile))
        |> seal()

      update_context(ctx, fn context -> %{context | refinements: [receipt["sha256"]]} end)

      assert {:error, _} =
               Promotion.promote(
                 ctx.host,
                 "repo",
                 %{ctx.request | refinement: receipt},
                 ctx.authority
               )
    end

    assert Memory.snapshot(ctx.server).harness == ctx.base
  end

  test "canary regression rolls back exact pointers and harness and quarantines the bytes", ctx do
    initial = Memory.snapshot(ctx.server)
    assert {:ok, _, receipt} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)

    assert {:ok, original, rollback} =
             Promotion.observe(
               ctx.host,
               observation(receipt, "failure", "task-a", true),
               ctx.authority
             )

    assert original == ctx.base
    assert rollback["action"] == "rolled_back"
    state = Memory.snapshot(ctx.server)
    assert state.registry.active == initial.registry.active
    assert state.harness == initial.harness
    assert Map.has_key?(state.quarantine, ctx.request.refinement["selected_sha256"])

    assert {:error, :candidate_quarantined} =
             Promotion.promote(ctx.host, "retry", canary(ctx), ctx.authority)
  end

  test "explicit undo and expiry restore the exact prior effective harness", ctx do
    assert {:ok, _, _} = Promotion.promote(ctx.host, "local", ctx.request, ctx.authority)
    assert {:ok, base, receipt} = Promotion.undo(ctx.host, ctx.authority)
    assert base == ctx.base
    assert receipt["reason"] == "explicit_undo"
    server = start_supervised!({Memory, base: ctx.base, scope: F.scope()}, id: :expiring)
    host = {Memory, server}
    assert {:ok, _, _} = Promotion.promote(host, "expiry", ctx.request, ctx.authority)
    update_context(ctx, &%{&1 | now: DateTime.add(&1.now, 60, :second)})
    assert {:ok, ^base, expired} = Promotion.current(host, ctx.authority)
    assert expired["action"] == "rolled_back"
  end

  test "resume rebinds policy and confirmation instead of resurrecting recorded grants", ctx do
    assert {:ok, _, _} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)
    update_context(ctx, &Map.put(&1, :revoked, true))
    assert {:ok, base, receipt} = Promotion.current(ctx.host, ctx.authority)
    assert base == ctx.base
    assert receipt["action"] == "rolled_back"
    update_context(ctx, fn _ -> ctx.context end)
    assert {:ok, ^base, %{"action" => "baseline"}} = Promotion.current(ctx.host, ctx.authority)

    assert {:error, :resolved_or_stale_promotion} =
             Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)
  end

  test "a failed assembly or restart preparation preserves registry and runtime atomically",
       ctx do
    for phase <- [:apply, :restart] do
      server =
        start_supervised!(
          {Memory, base: ctx.base, scope: F.scope(), prepare: fn _, _, _ -> {:error, phase} end},
          id: phase
        )

      original = Memory.snapshot(server)

      assert {:error, {:runtime_preparation_failed, receipt}} =
               Promotion.promote({Memory, server}, "failed", ctx.request, ctx.authority)

      state = Memory.snapshot(server)
      assert receipt["action"] == "quarantined"
      assert state.registry == original.registry
      assert state.harness == original.harness
      assert state.grant == nil
      assert map_size(state.quarantine) == 1
    end
  end

  test "authority revoked during preparation cannot be committed", ctx do
    prepare = fn _, _, _ ->
      update_context(ctx, &Map.put(&1, :revoked, true))
      :ok
    end

    server =
      start_supervised!({Memory, base: ctx.base, scope: F.scope(), prepare: prepare},
        id: :revoking
      )

    assert {:error, _} =
             Promotion.promote({Memory, server}, "revoked", ctx.request, ctx.authority)

    assert Memory.snapshot(server).grant == nil
    assert Memory.snapshot(server).harness == ctx.base
  end

  test "only selected canaries are used and distinct successful tasks complete the canary", ctx do
    assert {:ok, _, receipt} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)
    item = observation(receipt, "success-a", "task-a")
    assert {:ok, _, first} = Promotion.observe(ctx.host, item, ctx.authority)
    assert first["stage"] == "canary"
    assert {:ok, _, _} = Promotion.observe(ctx.host, item, ctx.authority)
    assert length(Memory.snapshot(ctx.server).grant["observations"]) == 1

    assert {:error, :canary_observation_changed} =
             Promotion.observe(
               ctx.host,
               Map.put(item, "trace_sha256", Contract.sha256("other")),
               ctx.authority
             )

    update_context(ctx, &%{&1 | task_id: "task-b"})

    assert {:ok, _, final} =
             Promotion.observe(
               ctx.host,
               observation(receipt, "success-b", "task-b"),
               ctx.authority
             )

    assert final["stage"] == "active"
  end

  test "task-local guidance never silently applies to another task", ctx do
    assert {:ok, _, _} = Promotion.promote(ctx.host, "local", ctx.request, ctx.authority)
    update_context(ctx, &%{&1 | task_id: "other-task"})
    assert {:ok, base, %{"selected" => false}} = Promotion.current(ctx.host, ctx.authority)
    assert base == ctx.base
  end

  test "code, privilege and evaluator assets remain unapproved proposals", ctx do
    assert {:ok, version} =
             Version.new(%{
               type: :harness_code,
               layer: :project,
               scope: :project,
               project_id: F.scope()["id"],
               content: "executable proposal"
             })

    assert %Proposal{status: :proposed} = proposal = Promotion.review(version)

    assert {:error, :approval_required} =
             Registry.activate(Memory.snapshot(ctx.server).registry, proposal)
  end

  test "deterministic canary selection leaves unselected tasks on the exact base", ctx do
    attrs =
      ctx.context.policy
      |> Map.drop(~w(schema_version sha256))
      |> put_in(["canary", "percent"], 50)

    {:ok, policy} = Policy.new(attrs)
    update_context(ctx, &%{&1 | policy: policy})
    assert {:ok, _, receipt} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)

    choices =
      for number <- 1..20 do
        task = "task-#{number}"
        update_context(ctx, &%{&1 | task_id: task})
        assert {:ok, harness, selection} = Promotion.current(ctx.host, ctx.authority)
        assert {:ok, ^harness, ^selection} = Promotion.current(ctx.host, ctx.authority)

        if not selection["selected"] do
          assert harness == ctx.base

          assert {:error, :invalid_canary_observation} =
                   Promotion.observe(ctx.host, observation(receipt, task, task), ctx.authority)
        end

        selection["selected"]
      end

    assert true in choices and false in choices
  end

  test "confirmation revocation and changed current runtimes invalidate persistent guidance",
       ctx do
    assert {:ok, _, _} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)
    update_context(ctx, &%{&1 | confirmations: []})
    assert {:ok, base, %{"action" => "rolled_back"}} = Promotion.current(ctx.host, ctx.authority)
    assert base == ctx.base
    server = start_supervised!({Memory, base: ctx.base, scope: F.scope()}, id: :runtime_change)
    update_context(ctx, fn _ -> ctx.context end)

    assert {:ok, _, _} =
             Promotion.promote({Memory, server}, "runtime", ctx.request, ctx.authority)

    update_context(ctx, &%{&1 | runtime_sha256: Contract.sha256("new")})

    assert {:ok, ^base, %{"action" => "rolled_back"}} =
             Promotion.current({Memory, server}, ctx.authority)
  end

  test "a declared personal description change preserves its executor", ctx do
    attrs =
      ctx.context.policy |> Map.drop(~w(schema_version sha256)) |> Map.put("trust", "personal")

    {:ok, policy} = Policy.new(attrs)

    profile =
      put_in(ctx.request.refinement["selected_profile"], ["options", "tool_descriptions"], %{
        "read" => "NEW PERSONAL READ"
      })

    receipt =
      ctx.request.refinement
      |> Map.put("selected_profile", profile)
      |> Map.put("selected_sha256", Contract.digest(profile))
      |> seal()

    update_context(
      ctx,
      &Map.merge(&1, %{
        policy: policy,
        description_tools: ["read"],
        refinements: [receipt["sha256"]]
      })
    )

    assert {:ok, harness, record} =
             Promotion.promote(
               ctx.host,
               "personal",
               %{ctx.request | refinement: receipt},
               ctx.authority
             )

    assert Tool.description(hd(harness.tools)) == "NEW PERSONAL READ"

    assert Tool.descriptor(hd(harness.tools)).identity["implementation_digest"] ==
             Tool.descriptor(hd(ctx.base.tools)).identity["implementation_digest"]

    version =
      Registry.active(Memory.snapshot(ctx.server).registry, {:prompt, :task, F.scope()["id"]})

    assert version.scope == :task
    assert version.layer == :session
    assert version.safety["task_id"] == "task-a"
    assert record["asset_sha256"] == version.digest
  end

  test "a missing current authority never returns the previously granted harness", ctx do
    assert {:ok, _, _} = Promotion.promote(ctx.host, "local", ctx.request, ctx.authority)
    assert {:error, _} = Promotion.current(ctx.host, fn -> {:error, :host_unavailable} end)
    assert {:error, _} = Promotion.current(ctx.host, fn -> raise "private host failure" end)

    assert {:error, _} =
             Promotion.current(ctx.host, fn ->
               {:ok, %{ctx.context | base: Harness.new(system: "stronger host")}}
             end)

    assert {:ok, _, %{"selected" => true}} = Promotion.current(ctx.host, ctx.authority)
  end

  test "unsupported mechanism evidence cannot become eligible by sealing it again", ctx do
    [first, last] = ctx.request.refinement["composition"]

    receipt =
      ctx.request.refinement
      |> Map.put("composition", [first, Map.put(last, "regression", true)])
      |> seal()

    update_context(ctx, &%{&1 | refinements: [receipt["sha256"]]})

    assert {:error, :guidance_not_eligible} =
             Promotion.promote(
               ctx.host,
               "regressed",
               %{ctx.request | refinement: receipt},
               ctx.authority
             )

    assert Memory.snapshot(ctx.server).grant == nil
  end

  test "installed text matches the effective CLI edit that refinement evaluated", ctx do
    {:ok, options} =
      Options.parse([
        "--config",
        "none",
        "--bare",
        "--no-delegate",
        "--permission-mode",
        "off",
        "--model",
        "test:model"
      ])

    host = [cwd: ctx.tmp_dir, provider: Scripted.new([])]
    {:ok, control} = CLI.prepare(options, host, surface: ["system_suffix"])

    {:ok, variant} =
      CLI.prepare(options, host,
        surface: ["system_suffix"],
        changes: %{"system_suffix" => " GOOD"}
      )

    runtime = CLI.identity(control)["sha256"]
    receipt = ctx.request.refinement |> put_in(["source_runtime", "sha256"], runtime) |> seal()

    update_context(
      ctx,
      &%{&1 | base: control.harness, runtime_sha256: runtime, refinements: [receipt["sha256"]]}
    )

    server =
      start_supervised!({Memory, base: control.harness, scope: F.scope()}, id: :effective_cli)

    assert {:ok, actual, _} =
             Promotion.promote(
               {Memory, server},
               "effective",
               %{ctx.request | refinement: receipt},
               ctx.authority
             )

    assert Map.drop(Map.from_struct(actual), [:harness_context]) ==
             Map.drop(Map.from_struct(variant.harness), [:harness_context])
  end

  test "regression feedback still rolls back after observation history is full", ctx do
    assert {:ok, _, receipt} = Promotion.promote(ctx.host, "canary", canary(ctx), ctx.authority)

    for n <- 1..32 do
      task = "task-#{n}"
      update_context(ctx, &%{&1 | task_id: task})

      assert {:ok, _, _} =
               Promotion.observe(
                 ctx.host,
                 observation(receipt, "success-#{n}", task),
                 ctx.authority
               )
    end

    update_context(ctx, &%{&1 | task_id: "regression-task"})

    assert {:ok, base, %{"action" => "rolled_back"}} =
             Promotion.observe(
               ctx.host,
               observation(receipt, "regression", "regression-task", true),
               ctx.authority
             )

    assert base == ctx.base
    assert Memory.snapshot(ctx.server).grant == nil
  end

  test "current use rechecks a revoked tool-description capability", ctx do
    attrs =
      ctx.context.policy |> Map.drop(~w(schema_version sha256)) |> Map.put("trust", "personal")

    {:ok, policy} = Policy.new(attrs)

    profile =
      put_in(ctx.request.refinement["selected_profile"], ["options", "tool_descriptions"], %{
        "read" => "LEARNED READ"
      })

    receipt =
      ctx.request.refinement
      |> Map.put("selected_profile", profile)
      |> Map.put("selected_sha256", Contract.digest(profile))
      |> seal()

    update_context(
      ctx,
      &Map.merge(&1, %{
        policy: policy,
        description_tools: ["read"],
        refinements: [receipt["sha256"]]
      })
    )

    assert {:ok, changed, _} =
             Promotion.promote(
               ctx.host,
               "personal",
               %{ctx.request | refinement: receipt},
               ctx.authority
             )

    assert Tool.description(hd(changed.tools)) == "LEARNED READ"
    update_context(ctx, &Map.put(&1, :description_tools, []))
    assert {:ok, base, %{"action" => "rolled_back"}} = Promotion.current(ctx.host, ctx.authority)
    assert base == ctx.base
  end

  test "commit rechecks a tool-description capability revoked during preparation", ctx do
    attrs =
      ctx.context.policy |> Map.drop(~w(schema_version sha256)) |> Map.put("trust", "personal")

    {:ok, policy} = Policy.new(attrs)

    profile =
      put_in(ctx.request.refinement["selected_profile"], ["options", "tool_descriptions"], %{
        "read" => "LEARNED READ"
      })

    receipt =
      ctx.request.refinement
      |> Map.put("selected_profile", profile)
      |> Map.put("selected_sha256", Contract.digest(profile))
      |> seal()

    update_context(
      ctx,
      &Map.merge(&1, %{
        policy: policy,
        description_tools: ["read"],
        refinements: [receipt["sha256"]]
      })
    )

    server =
      start_supervised!(
        {Memory,
         base: ctx.base,
         scope: F.scope(),
         prepare: fn _, _, _ ->
           update_context(ctx, &Map.put(&1, :description_tools, []))
           :ok
         end},
        id: :revoke_during_prepare
      )

    result =
      Promotion.promote(
        {Memory, server},
        "personal",
        %{ctx.request | refinement: receipt},
        ctx.authority
      )

    refute match?({:ok, _, _}, result), "withdrawn description capability still committed"
    assert Memory.snapshot(server).grant == nil
  end
end
