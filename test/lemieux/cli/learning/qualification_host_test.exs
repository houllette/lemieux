defmodule Lemieux.CLI.Learning.QualificationHostTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Fixtures
  alias Lemieux.CLI.Learning.QualificationHost, as: Host
  alias Lemieux.Contract
  alias Lemieux.Environment.Local
  alias Lemieux.Providers.Scripted
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
    assert {:ok, frozen} = Host.episode(config, context(later, "frozen"))
    refute frozen["passed"]
    assert frozen["exposed_case_ids"] == []
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
