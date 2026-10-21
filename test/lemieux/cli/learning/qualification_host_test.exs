defmodule Lemieux.CLI.Learning.QualificationHostTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetSearch
  alias Lemieux.CLI.Learning.Fixtures
  alias Lemieux.CLI.Learning.QualificationHost, as: Host
  alias Lemieux.Contract
  alias Lemieux.Environment.Local
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  @moduletag :tmp_dir

  # No arbitrary shell or hosted provider in this integration test. The hidden
  # grader gets deterministic output only when the scripted edit was installed.
  defmodule Confined do
    @behaviour Lemieux.Environment
    @impl true
    def read_file(_, cwd, path), do: Local.read_file(nil, cwd, path)
    @impl true
    def stream_file(_, cwd, path), do: Local.stream_file(nil, cwd, path)
    @impl true
    def write_file(_, cwd, path, bytes), do: Local.write_file(nil, cwd, path, bytes)
    @impl true
    def run(cases, command, opts) do
      fixed = File.read!(Path.join(opts[:cwd], "solution.py")) == "fixed"

      if String.starts_with?(command, "python main.py ") do
        output = if fixed, do: Enum.map(cases, &elem(&1, 1)), else: []
        {:ok, [{:data, JSON.encode!(output)}, {:exit_status, 0}]}
      else
        {:ok,
         [
           {:data, if(fixed, do: "checks passed", else: "AssertionError")},
           {:exit_status, if(fixed, do: 0, else: 1)}
         ]}
      end
    end
  end

  setup %{tmp_dir: dir} do
    [fixture | _] = Fixtures.materialize(Path.join(dir, "source"), 1)
    supervisor = :"qualification_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    root = Path.join(dir, "run")
    File.mkdir_p!(root)

    config = %{
      root: root,
      enabled: true,
      model: "test:model",
      effort: "default",
      supervisor: supervisor,
      scope: %{"id" => "qualification/test"},
      environment: {Confined, fixture.cases},
      isolated: true,
      initial_lessons: [],
      fixtures: %{fixture.id => fixture}
    }

    %{config: config, fixture: fixture}
  end

  defp context(fixture, arm, ids \\ [], cases \\ []) do
    %{
      "arm" => arm,
      "repetition" => 1,
      "task" => %{"id" => fixture.id, "source_sha256" => fixture.source_sha256},
      "allowance" => %{
        "requests" => 160,
        "tokens" => 3_000_000,
        "time_ms" => 2_000_000,
        "cost_usd" => nil
      },
      "prior_lesson_ids" => ids,
      "available_case_ids" => cases
    }
  end

  defp task_provider(fix?) do
    steps = [
      fn request ->
        if String.contains?(request.system, "harness proposer"),
          do:
            Scripted.tool_call(
              "abstain",
              "write",
              %{
                "path" => "proposal/manifest.json",
                "content" =>
                  JSON.encode!(%{
                    "outcome" => "no_supported_improvement",
                    "reason" => "already passes"
                  })
              },
              usage: usage()
            ),
          else:
            Scripted.tool_call("check", "bash", %{"command" => "python checks.py"},
              usage: usage()
            )
      end
    ]

    steps =
      if fix?,
        do:
          steps ++
            [
              fn request ->
                if String.contains?(request.system, "harness proposer"),
                  do: Scripted.complete("abstained", usage: usage()),
                  else:
                    Scripted.tool_call("read", "read", %{"path" => "solution.py"}, usage: usage())
              end,
              Scripted.tool_call("fix", "write", %{"path" => "solution.py", "content" => "fixed"},
                usage: usage()
              ),
              Scripted.tool_call("verify", "bash", %{"command" => "python checks.py"},
                usage: usage()
              )
            ],
        else: steps

    Scripted.new(steps ++ [Scripted.complete("done", usage: usage())])
  end

  defp usage, do: %{"input_tokens" => 2, "output_tokens" => 2}

  test "large source-backed context receives a larger admission estimate before dispatch" do
    request = %Request{
      model: "test:model",
      system: String.duplicate("x", 160_000),
      params: [max_tokens: 8192]
    }

    assert Host.token_bound(request) > 131_072
    assert Host.token_bound(request) >= Request.input_bytes(request) + 8192
  end

  test "zero learning allowance and missing isolation keep ordinary execution but dispatch no improver",
       ctx do
    owner = self()

    provider = fn role ->
      send(owner, {:resolved, role})
      task_provider(true)
    end

    for {arm, setting} <- [{"frozen", %{learning_requests: 0}}, {"updating", %{isolated: false}}] do
      config = ctx.config |> Map.merge(setting) |> Map.put(:provider, provider)
      assert {:ok, row} = Host.episode(config, context(ctx.fixture, arm))
      assert row["passed"]
      assert row["allocated_requests"] == 5
      refute_receive {:resolved, :probe}, 30
    end
  end

  test "unavailable persistence refuses before resolving a provider", ctx do
    path = Path.join(ctx.config.root, "not-a-directory")
    File.write!(path, "occupied")
    config = %{ctx.config | root: path} |> Map.put(:provider, fn _ -> flunk("no storage") end)

    assert {:error, {:episode_inputs_unavailable, {:error, :enotdir}}} =
             Host.episode(config, context(ctx.fixture, "frozen"))
  end

  test "study workspaces hide arm and attempt names from model-visible paths", ctx do
    config =
      ctx.config
      |> Map.put(:opaque_paths, true)
      |> Map.put(:capture_workspace, true)
      |> Map.put(:provider, fn _ -> task_provider(true) end)

    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "disabled"))
    assert row["passed"]
    assert row["workspace_evidence_complete"]
    old = "1-#{ctx.fixture.id}-disabled"
    assert File.exists?(Path.join([config.root, Contract.sha256(old), "evidence.json"]))
    refute File.exists?(Path.join(config.root, old))
    assert [artifact] = Path.wildcard(Path.join([config.root, "workspaces", "*.json"]))
    workspace = artifact |> File.read!() |> JSON.decode!()
    assert workspace["changed_paths"] == ["solution.py"]
    assert hd(workspace["entries"])["base64"] == Base.encode64("fixed")
  end

  @tag capture_log: true
  test "unknown probe usage keeps the completed original and records required recovery", ctx do
    config =
      Map.put(ctx.config, :provider, fn
        :task -> task_provider(true)
        :probe -> Scripted.new([Scripted.http_error(503, reason: "temporary upstream failure")])
      end)

    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "frozen"))
    assert row["passed"]
    assert row["qualification_complete"] == false
    assert row["tokens"] == nil

    evidence =
      Path.join(config.root, "1-#{ctx.fixture.id}-frozen/evidence.json")
      |> File.read!()
      |> JSON.decode!()

    assert evidence["selected"]["session_id"] == evidence["original"]["session_id"]
    assert evidence["learning_failure"]["reason"] =~ "requires_recovery"
    assert evidence["refinement"] == nil
    assert evidence["promotion"] == nil
    assert Lemieux.sessions(config.supervisor) == []
    assert Path.wildcard(Path.join(config.root, "*/leases/*")) == []
  end

  @tag capture_log: true
  test "shutdown of an integrated episode cancels its request and releases every owned lease",
       ctx do
    test = self()

    config =
      Map.put(ctx.config, :provider, fn _ ->
        Scripted.new([
          fn _request ->
            send(test, {:request_running, self()})
            Process.sleep(60_000)
            Scripted.complete("late", usage: usage())
          end
        ])
      end)

    worker = spawn(fn -> Host.episode(config, context(ctx.fixture, "updating")) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    assert_receive {:request_running, request}
    request_monitor = Process.monitor(request)
    {:monitored_by, guardians} = Process.info(worker, :monitored_by)
    refute guardians == []
    monitors = Enum.map(guardians, &{&1, Process.monitor(&1)})
    leases = Path.wildcard(Path.join(config.root, "*/leases/original"))
    refute leases == []
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^request_monitor, :process, ^request, _}

    for {guardian, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^guardian, _}
    end

    assert Lemieux.sessions(config.supervisor) == []
    assert Enum.all?(leases, &(not File.exists?(&1)))
  end

  test "the same ordinary capture path works through interactive TUI assembly", ctx do
    config =
      ctx.config
      |> Map.put(:interactive, true)
      |> Map.put(:provider, fn _ -> task_provider(true) end)

    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "retrieval"))
    assert row["passed"]
    refute row["created_lesson_ids"] == []

    evidence =
      JSON.decode!(
        File.read!(Path.join(config.root, "1-#{ctx.fixture.id}-retrieval/evidence.json"))
      )

    assert Enum.any?(
             evidence["original"]["runtime_qualification"]["control"]["applied_extensions"],
             &(&1["module"] == "Lemieux.CLI.SessionSummary" and &1["active"])
           )
  end

  test "a later task improves only when the real proposer can read the earlier captured lesson",
       ctx do
    first_config = Map.put(ctx.config, :provider, fn _ -> task_provider(true) end)
    assert {:ok, first} = Host.episode(first_config, context(ctx.fixture, "updating"))
    refute first["created_lesson_ids"] == []
    later = %{ctx.fixture | id: "later", task: %{ctx.fixture.task | id: "later"}}
    config = put_in(ctx.config, [:fixtures, "later"], later)
    config = Map.put(config, :provider, causal_provider(later.id))

    assert {:ok, learned} =
             Host.episode(
               config,
               context(later, "updating", first["created_lesson_ids"], [ctx.fixture.id])
             )

    assert learned["passed"]
    assert learned["exposed_case_ids"] == [ctx.fixture.id]

    excerpts =
      Path.wildcard(
        Path.join(config.root, "1-later-updating/proposals/*/evidence/transcripts/*.json")
      )

    assert [excerpt_path] = excerpts
    excerpt = excerpt_path |> File.read!() |> JSON.decode!()
    assert excerpt["case_id"] == "later"
    assert excerpt["entry_count"] > 0

    [operator_path] =
      Path.wildcard(Path.join(config.root, "1-later-updating/proposals/*/evidence/operator.json"))

    operator = operator_path |> File.read!() |> JSON.decode!()
    assert operator["evidence"]["task_request"] == later.task.prompt
    assert {:ok, frozen} = Host.episode(config, context(later, "frozen"))
    refute frozen["passed"]
    assert frozen["exposed_case_ids"] == []
  end

  test "whole-record reflection feeds a later executed proposal and removing it removes the gain",
       ctx do
    owner = self()

    hypothesis = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" =>
        "Inspect the active source, make the focused correction, then verify the executed output before completing.",
      "applicability" => ["coding verification failure recovery repository workflow"],
      "source_pointers" => ["/original/transcript/0"]
    }

    provider = fn
      :reflection ->
        Scripted.new([
          fn request ->
            send(owner, {:reflector_model, request.model})
            Scripted.complete(JSON.encode!(%{"lessons" => [hypothesis]}), usage: usage())
          end
        ])

      _ ->
        Scripted.new([
          Scripted.tool_call("read", "read", %{"path" => "solution.py"}, usage: usage()),
          Scripted.tool_call("fix", "write", %{"path" => "solution.py", "content" => "fixed"},
            usage: usage()
          ),
          Scripted.complete("done", usage: usage())
        ])
    end

    first_config =
      Map.merge(ctx.config, %{
        reflection: true,
        editor_model: "test:editor",
        editor_effort: "default",
        provider: provider
      })

    assert {:ok, first} = Host.episode(first_config, context(ctx.fixture, "updating"))
    assert first["passed"]
    assert first["qualification_complete"]
    assert [id] = first["created_lesson_ids"]
    assert_receive {:reflector_model, "test:editor"}
    store = LessonFiles.new(Path.join(ctx.config.root, "library-updating-1"), ctx.config.scope)
    assert {:ok, lesson} = Lessons.read(store, id)
    assert lesson.provenance["actor"] == "qualification-reflector"
    assert lesson.mechanism == hypothesis["mechanism"]

    input =
      Path.join(ctx.config.root, "1-#{ctx.fixture.id}-updating/reflection-input.json")
      |> File.read!()
      |> JSON.decode!()

    refute Map.has_key?(input, "confirmation_grade")
    assert input["original"]["transcript"] != []

    later = %{
      ctx.fixture
      | id: "reflected-later",
        task: %{ctx.fixture.task | id: "reflected-later"}
    }

    config =
      put_in(ctx.config, [:fixtures, later.id], later)
      |> Map.put(:provider, causal_provider(later.id))

    assert {:ok, learned} =
             Host.episode(config, context(later, "updating", [id], [ctx.fixture.id]))

    assert learned["passed"]
    assert learned["promotion_count"] == 1
    assert learned["exposed_case_ids"] == [ctx.fixture.id]
    assert {:ok, ablated} = Host.episode(config, context(later, "frozen"))
    refute ablated["passed"]
    assert ablated["promotion_count"] == 0
    assert ablated["exposed_case_ids"] == []
  end

  test "experimental review executes a successful-task candidate on a verified tie, while withholding experience stays causal",
       ctx do
    proposer = supported_provider(ctx.fixture.id, false)

    provider = fn
      :proposer -> proposer.(:proposer)
      _role -> task_provider(true)
    end

    policy = %{
      "id" => "experimental_mean/v2",
      "minimum_gain" => 0.1,
      "minimum_repetitions" => 2,
      "verified_ties" => true
    }

    config =
      Map.merge(ctx.config, %{
        provider: provider,
        support_policy: policy,
        probe_when: :all_observations,
        proposal_scopes: ["general", "domain"]
      })

    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "updating"))
    assert row["passed"]
    assert row["promotion_count"] == 1
    assert row["candidate_count"] == 2

    evidence =
      Path.join(config.root, "1-#{ctx.fixture.id}-updating/evidence.json")
      |> File.read!()
      |> JSON.decode!()

    assert evidence["refinement"]["qualification"] == "experimental_task_local"
    assert Enum.all?(evidence["refinement"]["control"], &(&1["score"] == 1))

    assert evidence["selected"]["session_id"] ==
             evidence["promotion"]["final_observation"]["session_id"]

    refute evidence["selected"]["session_id"] == evidence["original"]["session_id"]
    assert {:ok, without} = Host.episode(config, context(ctx.fixture, "no_experience"))
    assert without["passed"]
    assert without["promotion_count"] == 1
    assert without["exposed_case_ids"] == []
  end

  test "a reviewed typed setting reaches real isolated requests and its evidence rejects tampered transcripts",
       ctx do
    attrs = %{
      "kind" => "configuration",
      "payload" => %{"extension" => "search", "glob_after_requests" => 0},
      "requires_tools" => ["glob"],
      "files" => %{},
      "triggers" => []
    }

    provider = fn
      :asset_proposer ->
        Scripted.new([Scripted.complete(JSON.encode!(%{"assets" => [attrs]}), usage: usage())])

      :asset_critic ->
        Scripted.new([
          fn request ->
            user = request.entries |> Enum.filter(&(&1.type == :user)) |> List.last()
            input = JSON.decode!(user.payload["text"])

            Scripted.complete(
              JSON.encode!(%{
                "asset_sha256" => input["asset_sha256"],
                "decision" => "approve",
                "reason" => "Only the shipped disclosure parameter changes."
              }),
              usage: usage()
            )
          end
        ])

      _ ->
        task_provider(true)
    end

    config =
      Map.merge(ctx.config, %{
        asset_search: true,
        asset_tokens: 1_000_000,
        profile_search: false,
        provider: provider,
        support_policy: %{
          "id" => "experimental_mean/v2",
          "verified_ties" => true,
          "minimum_gain" => 0.1,
          "minimum_repetitions" => 2
        }
      })

    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "updating"))
    assert row["passed"]
    assert row["qualification_complete"]
    assert row["asset_candidate_count"] == 1
    assert row["asset_application_count"] == 1
    assert row["asset_restoration_count"] == 1
    path = Path.join(config.root, "1-#{ctx.fixture.id}-updating/evidence.json")
    evidence = path |> File.read!() |> JSON.decode!()
    observation = evidence["asset_application"]["final_observation"]
    sha = hd(evidence["asset_search"]["selected_asset_sha256"])
    attempt = %{observation: observation, grade: evidence["selected_grade"]}
    assert {:ok, _} = AssetSearch.evidence(attempt, [sha], "test:model")

    assert {:error, _} =
             AssetSearch.evidence(attempt, [Contract.sha256("different asset")], "test:model")

    corrupted =
      update_in(observation["transcript"], fn entries ->
        Enum.map(entries, fn entry ->
          if entry["type"] == "tool_result",
            do: put_in(entry["payload"]["output"], "forged result"),
            else: entry
        end)
      end)

    assert {:error, _} =
             AssetSearch.evidence(%{attempt | observation: corrupted}, [sha], "test:model")

    assert Lemieux.sessions(config.supervisor) == []
  end

  defp causal_provider(task_id) do
    profile =
      Host.baseline("test:model", "default") |> update_in(["options", "system"], &(&1 <> " GOOD"))

    manifest = %{
      "rationale" => "Prior captured recovery motivates explicit verification.",
      "hypothesis" => "A prior verification mechanism improves later execution.",
      "targeted_cluster" => nil,
      "mechanism" => "missing_verification",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => [task_id],
      "predicted_at_risk" => []
    }

    fn _ ->
      Scripted.new([
        fn request ->
          cond do
            proposer?(request) ->
              Scripted.tool_call("experience", "read", %{"path" => "evidence/lessons/index.json"},
                usage: usage()
              )

            String.contains?(request.system, "GOOD") ->
              Scripted.tool_call("read", "read", %{"path" => "solution.py"}, usage: usage())

            true ->
              Scripted.complete("baseline", usage: usage())
          end
        end,
        fn request ->
          cond do
            proposer?(request) and saw_lesson?(request) ->
              Scripted.tool_call(
                "profile",
                "write",
                %{"path" => "proposal/profile.json", "content" => Contract.encode!(profile)},
                usage: usage()
              )

            proposer?(request) ->
              Scripted.tool_call(
                "abstain",
                "write",
                %{
                  "path" => "proposal/manifest.json",
                  "content" =>
                    JSON.encode!(%{
                      "outcome" => "no_supported_improvement",
                      "reason" => "no prior source"
                    })
                },
                usage: usage()
              )

            true ->
              Scripted.tool_call("fix", "write", %{"path" => "solution.py", "content" => "fixed"},
                usage: usage()
              )
          end
        end,
        &causal_manifest(&1, manifest),
        Scripted.complete("done", usage: usage())
      ])
    end
  end

  defp causal_manifest(request, manifest) do
    if proposer?(request) and saw_lesson?(request),
      do:
        Scripted.tool_call(
          "manifest",
          "write",
          %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
          usage: usage()
        ),
      else: Scripted.complete("done", usage: usage())
  end

  defp proposer?(request), do: String.contains?(request.system, "harness proposer")

  defp saw_lesson?(request),
    do:
      Enum.any?(request.entries, fn entry ->
        entry.type == :tool_result and String.contains?(entry.payload["output"] || "", "lesson_")
      end)

  test "the grader refuses symlinked public checks even when their target has identical bytes",
       ctx do
    path = Path.join(ctx.fixture.task.cwd, "checks.py")
    outside = Path.join(ctx.config.root, "external-checks.py")
    File.write!(outside, File.read!(path))
    File.rm!(path)
    File.ln_s!(outside, path)
    grade = Fixtures.grade(ctx.fixture, ctx.fixture.task.cwd, ctx.config.environment)
    assert "modified_checks.py" in grade["safety_failures"]
    refute grade["passed"]
  end

  test "ordinary CLI capture retains source-backed lessons; next task retrieves only committed prior sources",
       ctx do
    config = Map.put(ctx.config, :provider, fn _ -> task_provider(true) end)
    assert {:ok, first} = Host.episode(config, context(ctx.fixture, "updating"))
    assert first["passed"]
    refute first["created_lesson_ids"] == []

    evidence =
      JSON.decode!(
        File.read!(Path.join(config.root, "1-#{ctx.fixture.id}-updating/evidence.json"))
      )

    assert evidence["original"]["runtime_qualification"]["lane"] == "effective_lmx"
    assert evidence["controller"]["accounting"]["tokens"] > 0
    # A separate task id shares only its authorized predecessor's lessons.
    second = %{ctx.fixture | id: "later", task: %{ctx.fixture.task | id: "later"}}
    config = put_in(config.fixtures["later"], second)

    assert {:ok, later} =
             Host.episode(
               config,
               context(second, "updating", first["created_lesson_ids"], [ctx.fixture.id])
             )

    assert later["exposed_case_ids"] == [ctx.fixture.id]
    assert {:ok, _} = Host.episode(config, context(second, "retrieval"))
  end

  test "opt-out survives restart and resolves no learning provider", ctx do
    owner = self()

    config =
      Map.put(ctx.config, :provider, fn role ->
        send(owner, {:provider, role})
        task_provider(true)
      end)

    assert :ok = Host.opt_out(config)
    assert Host.inspect(Map.put(config, :enabled, true))["enabled"] == false
    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "updating"))
    assert row["created_lesson_ids"] == []
    assert row["exposed_case_ids"] == []
    refute_receive {:provider, :probe}, 30
    assert_receive {:provider, :task}
  end

  test "the first-party proposer is admitted, executed, promoted and exactly undone", ctx do
    provider = supported_provider(ctx.fixture.id, false)

    assert {:ok, row} =
             Host.episode(
               Map.put(ctx.config, :provider, provider),
               context(ctx.fixture, "frozen")
             )

    assert row["passed"]

    evidence =
      JSON.decode!(
        File.read!(Path.join(ctx.config.root, "1-#{ctx.fixture.id}-frozen/evidence.json"))
      )

    assert evidence["refinement"]["decision"] == "proposed"
    assert evidence["promotion"]["undo"]["action"] == "rolled_back"
    assert length(evidence["refinement"]["composition"]) == 2
    assert row["candidate_count"] == 1
    assert row["promotion_count"] == 1
    assert row["rollback_count"] == 1

    store = LessonFiles.new(Path.join(ctx.config.root, "library-frozen-1"), ctx.config.scope)
    assert {:ok, ids} = Lessons.inventory(store)

    lessons =
      Enum.map(ids, fn id ->
        {:ok, lesson} = Lessons.read(store, id)
        lesson
      end)

    retained = Enum.find(lessons, &(&1.kind == "proposer_lesson"))
    assert retained.outcome == "supported"
    assert retained.qualification == "behavioral"
    assert retained.source_case_ids == [ctx.fixture.id]

    assert Enum.any?(retained.artifacts, fn {_sha, bytes} ->
             bytes |> Base.decode64!() |> String.contains?("GOOD")
           end)
  end

  @tag capture_log: true
  test "a failed promoted request cannot replace partial original work on an equal score", ctx do
    config = Map.put(ctx.config, :provider, supported_provider(ctx.fixture.id, true))
    assert {:ok, row} = Host.episode(config, context(ctx.fixture, "frozen"))
    refute row["passed"]
    assert row["tokens"] == nil

    evidence =
      Path.join(config.root, "1-#{ctx.fixture.id}-frozen/evidence.json")
      |> File.read!()
      |> JSON.decode!()

    assert evidence["refinement"]["decision"] == "proposed"
    assert Enum.all?(evidence["refinement"]["composition"], & &1["verified_success"])
    refute evidence["promotion"]["final_grade"]["passed"]
    assert evidence["promotion"]["undo"]["action"] == "rolled_back"
    assert evidence["original_grade"]["score"] == evidence["selected_grade"]["score"]
    assert evidence["original"]["answer"] == "baseline"
    assert evidence["selected"]["session_id"] == evidence["original"]["session_id"]
    assert evidence["selected"]["answer"] == "baseline"
    assert Lemieux.sessions(config.supervisor) == []
    assert Path.wildcard(Path.join(config.root, "*/leases/*")) == []
  end

  defp supported_provider(task_id, fail_promoted?) do
    profile =
      Host.baseline("test:model", "default") |> update_in(["options", "system"], &(&1 <> " GOOD"))

    manifest = %{
      "rationale" => "Repeated failures omit an explicit local verification step.",
      "hypothesis" => "Verification guidance improves execution.",
      "targeted_cluster" => nil,
      "mechanism" => "missing_verification",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => [task_id],
      "predicted_at_risk" => []
    }

    # Refinement supplies the same metered provider to every role. Dispatch by
    # the actual request system, exactly as a provider sees it, not test fixtures
    # that bypass the first-party proposer contract.
    fn _ ->
      Scripted.new([
        fn request ->
          cond do
            fail_promoted? and promoted_request?(request) ->
              Scripted.http_error(503, reason: "promoted execution unavailable")

            String.contains?(request.system, "harness proposer") ->
              Scripted.tool_call(
                "profile",
                "write",
                %{"path" => "proposal/profile.json", "content" => Contract.encode!(profile)},
                usage: usage()
              )

            String.contains?(request.system, "GOOD") ->
              Scripted.tool_call("read", "read", %{"path" => "solution.py"}, usage: usage())

            true ->
              Scripted.complete("baseline", usage: usage())
          end
        end,
        fn request ->
          cond do
            String.contains?(request.system, "harness proposer") ->
              Scripted.tool_call(
                "manifest",
                "write",
                %{"path" => "proposal/manifest.json", "content" => JSON.encode!(manifest)},
                usage: usage()
              )

            String.contains?(request.system, "GOOD") ->
              Scripted.tool_call("fix", "write", %{"path" => "solution.py", "content" => "fixed"},
                usage: usage()
              )

            true ->
              Scripted.complete("done", usage: usage())
          end
        end,
        Scripted.complete("done", usage: usage())
      ])
    end
  end

  defp promoted_request?(request) do
    Enum.any?(request.entries, fn entry ->
      entry.type == :session and String.ends_with?(entry.payload["cwd"] || "", "/promoted")
    end)
  end
end
