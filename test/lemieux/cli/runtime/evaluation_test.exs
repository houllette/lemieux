defmodule Lemieux.CLI.Runtime.EvaluationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Grader.Command
  alias Lemieux.Benchmark.Runtime, as: BenchmarkRuntime
  alias Lemieux.Benchmark.Task
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Runtime.Evaluation
  alias Lemieux.Contract
  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Transcript

  @moduletag :tmp_dir

  defp setup_host(dir) do
    File.mkdir_p!(Path.join(dir, ".git"))

    {:ok, options} =
      Options.parse(["--config", "none", "--no-delegate", "--permission-mode", "off"])

    {options,
     [
       cwd: dir,
       provider: Scripted.new([]),
       store: JSONL.new(Path.join(dir, "sessions")),
       provider_identity: %{"id" => "scripted-fixture", "sha256" => Contract.sha256("fixture-v1")}
     ]}
  end

  test "control reuses ordinary CLI discovery and assembly", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Always explain the test result.")
    {options, host} = setup_host(dir)
    {:ok, discovered} = Runtime.with_workspace(options, host)
    {:ok, ordinary} = Runtime.prepare(options, discovered)
    assert {:ok, evaluated} = Evaluation.prepare(options, discovered)
    assert evaluated.harness == ordinary.harness
    assert evaluated.qualification["lane"] == "effective_lmx"
    assert evaluated.qualification["control"]["system"] =~ "Always explain the test result."
    assert :ok == Evaluation.verify(evaluated.qualification)
    assert Evaluation.compatible?(evaluated.qualification, evaluated.qualification)
  end

  test "only frozen text and generation paths may change and authority is retained", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    hooks = [before_tool_call: fn _, _ -> {:deny, "host policy"} end]
    host = Keyword.merge(host, hooks: hooks, max_requests: 1, params: [max_tokens: 32])

    changes = %{
      "system_suffix" => "Check your answer.",
      "tool_descriptions" => %{"write" => "Write carefully."}
    }

    surface = ["system_suffix", "tool_descriptions.write"]

    assert {:ok, candidate} =
             Evaluation.prepare(options, host, surface: surface, changes: changes)

    assert candidate.harness.system =~ "Check your answer."
    assert candidate.harness.hooks == hooks
    assert candidate.harness.max_requests == 1
    assert candidate.harness.params == [max_tokens: 32]
    write = Enum.find(candidate.harness.tools, &(Tool.name(&1) == "write"))
    assert Tool.description(write) == "Write carefully."
    assert {:error, {:outside_surface, _}} = Evaluation.prepare(options, host, changes: changes)

    assert {:error, :unsupported_change} =
             Evaluation.prepare(options, host, surface: ["hooks"], changes: %{"hooks" => []})

    assert {:error, {:host_constraint, :params}} =
             Evaluation.prepare(options, host,
               surface: ["generation.max_tokens"],
               changes: %{"generation" => %{"max_tokens" => 100}}
             )
  end

  test "effective configuration and frozen surface invalidate comparison reuse", %{tmp_dir: dir} do
    {options, host} = setup_host(dir)
    {:ok, first} = Evaluation.prepare(options, host)
    {:ok, same} = Evaluation.prepare(options, host)
    assert Evaluation.compatible?(first.qualification, same.qualification)
    {:ok, retry} = Evaluation.prepare(options, Keyword.put(host, :provider_retry, false))
    refute Evaluation.compatible?(first.qualification, retry.qualification)
    {:ok, other} = Evaluation.prepare(options, host, surface: ["system_suffix"])
    refute Evaluation.compatible?(first.qualification, other.qualification)
    tampered = put_in(first.qualification, ["control", "system"], "forged")
    assert {:error, _} = Evaluation.verify(tampered)
    refute Evaluation.compatible?(first.qualification, tampered)
  end

  test "qualification contains data and hashes, never executable host state", %{tmp_dir: dir} do
    {options, host} = setup_host(dir)
    host = Keyword.put(host, :approval_context, fn _ -> "private-credential-value" end)
    {:ok, evaluated} = Evaluation.prepare(options, host)
    encoded = Contract.encode!(evaluated.qualification)
    refute encoded =~ "private-credential-value"
    refute encoded =~ "#Function"
    assert Enum.map(evaluated.qualification["control"]["catalog"], & &1["name"]) != []
    assert Harness.explain(evaluated.harness)["scope"] == "prepared_local_catalog"
  end

  defmodule RemoteEnvironment do
    alias Lemieux.Environment.Local
    @behaviour Lemieux.Environment
    @impl true
    def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)
    @impl true
    def write_file(owner, cwd, path, contents) do
      send(owner, {:remote_write, path})
      Local.write_file(nil, cwd, path, contents)
    end

    @impl true
    def run(owner, command, _opts) do
      send(owner, {:remote_check, command})
      {:ok, [{:stdout, "verified"}, {:exit_status, 0}]}
    end
  end

  defmodule Declined do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    @impl true
    def apply(harness, _state), do: harness
    @impl true
    def describe(_state), do: %{"active" => false, "inactive_reason" => "fixture_declined"}
  end

  defp task(dir) do
    %Task{
      id: "fixture",
      prompt: "finish the task",
      cwd: dir,
      grader: %Command{command: ["true"]}
    }
  end

  defp supervisor do
    name = :"cli_evaluation_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: name})
    name
  end

  test "personal and repository overlays retain scope, qualification and dropped descriptions", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    personal = Path.join(dir, "personal")
    File.mkdir_p!(personal)
    alias Lemieux.Learning.Overlay

    :ok =
      Overlay.export(
        %Overlay{
          system_suffix: "Personal rule",
          tool_descriptions: %{"write" => "Personal write rule"},
          qualification: "confirmed"
        },
        Path.join(personal, "harness.json")
      )

    :ok =
      Overlay.export(
        %Overlay{
          system_suffix: "Repository rule",
          tool_descriptions: %{"write" => "Untrusted replacement"},
          qualification: "unconfirmed"
        },
        Path.join([dir, ".lmx", "harness.json"]),
        unconfirmed: true
      )

    {:ok, workspace} =
      Discovery.discover(dir,
        personal_dir: personal,
        claude_personal_dir: Path.join(personal, "c"),
        codex_personal_dir: Path.join(personal, "x"),
        agents_personal_dir: Path.join(personal, "a")
      )

    host = Keyword.put(host, :workspace, workspace)
    {:ok, ordinary} = Runtime.prepare(options, host)
    {:ok, control} = Evaluation.prepare(options, host)
    assert control.harness == ordinary.harness
    assert control.harness.system =~ "Personal rule"
    assert control.harness.system =~ "Repository rule"
    write = Enum.find(control.harness.tools, &(Tool.name(&1) == "write"))
    assert Tool.description(write) == "Personal write rule"
    freeze = control.qualification["control"]
    assert inspect(freeze["workspace_notices"]) =~ "were not applied"
    assert inspect(freeze["resolved_assets"]) =~ "unconfirmed"

    {:ok, candidate} =
      Evaluation.prepare(options, host,
        surface: ["system_suffix"],
        changes: %{"system_suffix" => "Candidate rule"}
      )

    assert candidate.qualification["control"] == control.qualification["control"]
    refute candidate.qualification["effective"] == control.qualification["effective"]

    assert Enum.map(candidate.harness.tools, &Tool.descriptor/1) ==
             Enum.map(control.harness.tools, &Tool.descriptor/1)
  end

  test "disabled and declined extensions remain explicit in the actual control", %{tmp_dir: dir} do
    {options, host} = setup_host(dir)

    options = %{
      options
      | config: %Lemieux.CLI.Config{settings: %{"disabled_extensions" => ["search"]}}
    }

    host = Keyword.put(host, :extensions, [Declined])
    {:ok, prepared} = Evaluation.prepare(options, host)
    freeze = prepared.qualification["control"]
    assert freeze["disabled_extensions"] == ["search"]
    refute Enum.any?(freeze["catalog"], &(&1["name"] == "grep"))

    assert Enum.any?(
             freeze["applied_extensions"],
             &(&1["module"] == inspect(Declined) and &1["inactive_reason"] == "fixture_declined")
           )

    assert Enum.any?(
             freeze["applied_extensions"],
             &(&1["module"] == "Lemieux.Extensions.ApplyPatch" and &1["active"] == false)
           )
  end

  @tag capture_log: true
  test "actual requests and terminal evidence bind the intentional edit and retry policy", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    provider = Scripted.new([Scripted.http_error(503), Scripted.complete("done")])

    host =
      Keyword.merge(host,
        provider: provider,
        supervisor: supervisor(),
        provider_retry: [max_attempts: 2, base_delay_ms: 1, max_delay_ms: 1]
      )

    runtime =
      Evaluation.runtime("candidate", options, host,
        surface: ["system_suffix"],
        changes: %{"system_suffix" => "Candidate rule"}
      )

    assert {:ok, observation} = BenchmarkRuntime.run(runtime, task(dir))
    assert observation["answer"] == "done"
    assert observation["provider_retries"]["count"] == 1
    assert length(Scripted.requests(provider)) == 2
    [request | _] = Scripted.requests(provider)
    assert request.system =~ "Candidate rule"
    entries = observation["transcript"]
    snapshot = Enum.find(entries, &(&1["type"] == "harness_snapshot"))["payload"]
    reference = get_in(snapshot, ["workflow", "evaluation"])
    assert reference["sha256"] == observation["runtime_qualification"]["sha256"]
    assert reference["intentional_changes"] == %{"system_suffix" => "Candidate rule"}
    assert snapshot["workflow"]["provider_retry"]["max_attempts"] == 2
    evidence = Enum.find(entries, &(&1["type"] == "run_evidence"))["payload"]

    last_snapshot =
      entries
      |> Enum.reverse()
      |> Enum.find(&(&1["type"] == "harness_snapshot"))
      |> Map.fetch!("payload")

    assert evidence["harness_snapshot"]["semantic_sha256"] == last_snapshot["semantic_sha256"]
    assert last_snapshot["workflow"]["evaluation"] == reference
  end

  test "explicit verification executes through the same custom environment in both arms", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    options = put_in(options.host.state_dir, Path.join(dir, "state"))

    options = %{
      options
      | config: %Lemieux.CLI.Config{
          settings: %{
            "capture" => false,
            "verify" => %{"command" => "host-check", "max_continuations" => 1},
            "disabled_extensions" => ["checkpoints"]
          }
        }
    }

    host = Keyword.merge(host, supervisor: supervisor(), environment: {RemoteEnvironment, self()})

    for {changes, index} <- Enum.with_index([%{}, %{"system_suffix" => "Candidate rule"}]) do
      arm = Path.join(dir, "arm-#{index}")
      File.mkdir_p!(Path.join(arm, ".git"))

      provider =
        Scripted.new([
          Scripted.tool_call("w", "write", %{"path" => "result.txt", "content" => "ok"}),
          Scripted.complete("done")
        ])

      runtime =
        Evaluation.runtime("arm", options, Keyword.put(host, :provider, provider),
          surface: ["system_suffix"],
          changes: changes
        )

      assert {:ok, observation} = BenchmarkRuntime.run(runtime, task(arm))
      assert observation["answer"] == "done"
      assert_receive {:remote_write, "result.txt"}
      assert_receive {:remote_check, "host-check"}
      freeze = observation["runtime_qualification"]["effective"]
      assert freeze["environment"]["module"] == inspect(RemoteEnvironment)
      assert freeze["verification"]["command"] == "host-check"

      refute Evaluation.compatible?(
               observation["runtime_qualification"],
               observation["runtime_qualification"]
             )
    end
  end

  test "fresh permission modes and remembered policy invalidate reuse", %{tmp_dir: dir} do
    {options, host} = setup_host(dir)
    options = put_in(options.host.permission_mode, "read_only")
    {:ok, handle} = Permissions.new(mode: :read_only)
    host = Keyword.put(host, :permissions, handle)
    {:ok, control} = Evaluation.prepare(options, host)
    {:ok, same} = Evaluation.prepare(options, host)
    assert Harness.diff(control.qualification["control"], same.qualification["control"]) == %{}
    assert Evaluation.compatible?(control.qualification, same.qualification)
    :ok = Permissions.set_mode(handle, :full_auto)
    {:ok, changed} = Evaluation.prepare(options, host)
    refute Evaluation.compatible?(control.qualification, changed.qualification)
  end

  test "resume and fork use current assembly and verified history, without restoring host authority",
       %{tmp_dir: dir} do
    {options, host} = setup_host(dir)
    host = Keyword.put(host, :supervisor, supervisor())
    provider = Scripted.new([Scripted.complete("original")])

    {:ok, original} =
      BenchmarkRuntime.run(
        Evaluation.runtime("first", options, Keyword.put(host, :provider, provider)),
        task(dir)
      )

    store = host[:store]
    {:ok, fork} = Transcript.fork(store, original["session_id"])

    for id <- [original["session_id"], fork] do
      current = %{options | resume: id}
      provider = Scripted.new([Scripted.complete("continued")])

      fresh =
        Keyword.merge(host, provider: provider, max_requests: 2, tools: [Lemieux.Tools.Read])

      {:ok, workspace} = Runtime.with_workspace(current, fresh)
      {:ok, normal} = Runtime.prepare(current, workspace)
      {:ok, evaluation} = Evaluation.prepare(current, workspace)
      assert evaluation.harness == normal.harness
      assert evaluation.qualification["control"]["history"]["session_id"] == id

      assert {:ok, observation} =
               BenchmarkRuntime.run(
                 Evaluation.runtime("resume", current, fresh),
                 task(dir)
               )

      assert observation["session_id"] == id
      assert observation["answer"] == "continued"
      [request] = Scripted.requests(provider)

      assert Enum.any?(
               request.entries,
               &(&1.type == :assistant and inspect(&1.payload) =~ "original")
             )

      assert Enum.map(request.tools, &Tool.name/1) |> Enum.sort() == ["read", "skill"]
    end
  end

  test "malformed edits, disabled tools and stale controls fail before provider dispatch", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    {:ok, baseline} = Evaluation.prepare(options, host)

    assert {:error, :evaluation_control_drift} =
             Evaluation.prepare(options, Keyword.put(host, :max_turns, 2),
               expected_control_sha256: baseline.qualification["control"]["sha256"]
             )

    assert {:error, :invalid_surface} =
             Evaluation.prepare(options, host, surface: [nil], changes: %{"system_suffix" => "x"})

    assert {:error, :invalid_tool_description} =
             Evaluation.prepare(options, Keyword.put(host, :disabled_tools, ["write"]),
               surface: ["tool_descriptions"],
               changes: %{"tool_descriptions" => %{"write" => "x"}}
             )

    assert {:error, :invalid_tool_description} =
             Evaluation.prepare(options, host,
               surface: ["tool_descriptions"],
               changes: %{"tool_descriptions" => %{"missing" => "x"}}
             )

    assert {:error, :invalid_generation} =
             Evaluation.prepare(options, host,
               surface: ["generation"],
               changes: %{"generation" => %{"api_key" => "never"}}
             )

    assert Scripted.requests(host[:provider]) == []
  end

  test "provider revisions and private environment inputs invalidate or disable cache reuse", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)
    {:ok, control} = Evaluation.prepare(options, host)

    changed =
      put_in(host[:provider_identity], %{"id" => "other-route", "sha256" => Contract.sha256("v2")})

    {:ok, changed} = Evaluation.prepare(options, changed)
    refute Evaluation.compatible?(control.qualification, changed.qualification)
    {:ok, unbound} = Evaluation.prepare(options, Keyword.delete(host, :provider_identity))
    refute Evaluation.compatible?(unbound.qualification, unbound.qualification)

    assert {:error, :invalid_provider_identity} =
             Evaluation.prepare(
               options,
               Keyword.put(host, :provider_identity, %{"id" => "x", "sha256" => "bad"})
             )

    {:ok, custom} =
      Evaluation.prepare(
        options,
        Keyword.put(host, :environment, {RemoteEnvironment, "private-state-a"})
      )

    {:ok, other} =
      Evaluation.prepare(
        options,
        Keyword.put(host, :environment, {RemoteEnvironment, "private-state-b"})
      )

    refute Evaluation.compatible?(custom.qualification, other.qualification)
    refute Contract.encode!(custom.qualification) =~ "private-state-a"
  end

  test "profile adaptation rejects rewrites and authority edits before building a runtime", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)

    parent = %{
      "model" => options.model,
      "tools" => ["read"],
      "options" => %{"system" => "Portable seed", "tool_descriptions" => %{"read" => "Original"}}
    }

    factory =
      Evaluation.factory(options, host, parent_profile: parent, surface: ["system_suffix"])

    extra = [sessions_dir: Path.join(dir, "sessions")]
    rewritten = put_in(parent, ["options", "system"], "Replacement")

    assert {:error, :profile_prompt_must_append} =
             factory.("bad", rewritten, host[:provider], extra)

    assert {:error, :unsupported_profile_delta} =
             factory.("bad", Map.put(parent, "tools", ["bash"]), host[:provider], extra)

    assert {:error, :unsupported_profile_delta} =
             factory.(
               "bad",
               put_in(parent, ["options", "tool_descriptions"], %{}),
               host[:provider],
               extra
             )

    assert {:error, :evaluation_model_differs_from_host} =
             Evaluation.factory(%{options | model: "other:model"}, host, parent_profile: parent).(
               "bad",
               parent,
               host[:provider],
               extra
             )

    changed = put_in(parent, ["options", "system"], "Portable seed Appended rule")
    assert {:ok, runtime} = factory.("good", changed, host[:provider], extra)
    assert runtime.module == Evaluation
    assert runtime.options[:evaluation][:changes] == %{"system_suffix" => " Appended rule"}
  end

  test "describing a tool cannot bypass a real host denial", %{tmp_dir: dir} do
    {options, host} = setup_host(dir)

    provider =
      Scripted.new([
        Scripted.tool_call("w", "write", %{"path" => "forbidden.txt", "content" => "no"}),
        Scripted.complete("denied")
      ])

    hooks = [before_tool_call: fn _, _ -> {:deny, "host policy"} end]

    host =
      Keyword.merge(host,
        provider: provider,
        supervisor: supervisor(),
        hooks: hooks,
        max_requests: 2
      )

    runtime =
      Evaluation.runtime("candidate", options, host,
        surface: ["tool_descriptions.write"],
        changes: %{"tool_descriptions" => %{"write" => "Write without restrictions."}}
      )

    assert {:ok, observation} = BenchmarkRuntime.run(runtime, task(dir))
    refute File.exists?(Path.join(dir, "forbidden.txt"))
    assert observation["tool_metrics"]["denied"] == 1

    assert Enum.any?(
             observation["transcript"],
             &(&1["type"] == "tool_result" and &1["payload"]["output"] =~ "host policy")
           )
  end

  test "an exhausted resumed session cannot report a historical answer as current work", %{
    tmp_dir: dir
  } do
    {options, host} = setup_host(dir)

    host =
      Keyword.merge(host,
        supervisor: supervisor(),
        max_requests: 1,
        provider: Scripted.new([Scripted.complete("historical")])
      )

    {:ok, original} = BenchmarkRuntime.run(Evaluation.runtime("first", options, host), task(dir))
    provider = Scripted.new([Scripted.complete("must not run")])
    resumed = %{options | resume: original["session_id"]}

    assert {:ok, observation} =
             BenchmarkRuntime.run(
               Evaluation.runtime("resume", resumed, Keyword.put(host, :provider, provider)),
               task(dir)
             )

    assert observation["answer"] == ""
    assert observation["tool_metrics"]["requests"] == 0
    assert Scripted.requests(provider) == []

    assert Enum.any?(
             observation["transcript"],
             &(&1["type"] == "assistant" and inspect(&1["payload"]) =~ "historical")
           )
  end

  defmodule LeaseDenied do
    @behaviour Lemieux.Environment
    alias Lemieux.Environment.Local
    @impl true
    def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)
    @impl true
    def write_file(_state, _cwd, _path, _content), do: {:error, :lease_denied}
    @impl true
    def run(_state, _command, _opts), do: {:error, :lease_denied}
  end

  test "isolation lease environment is not silently replaced by the ordinary host", %{
    tmp_dir: dir
  } do
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

    profile =
      Profile.quota(
        %{
          "execution" => "live",
          "model" => "test:model",
          "tools" => ["read", "write", "edit", "bash"],
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

    host = [
      cwd: dir,
      supervisor: supervisor(),
      store: JSONL.new(Path.join(dir, "sessions")),
      environment: Lemieux.Environment.Local
    ]

    factory = Evaluation.factory(options, host, parent_profile: profile, surface: [])

    provider =
      Scripted.new([
        Scripted.tool_call("write", "write", %{
          "path" => "escaped-lease.txt",
          "content" => "unexpected write"
        }),
        Scripted.complete("done")
      ])

    runtime_result =
      factory.("probe", profile, provider,
        sessions_dir: Path.join(dir, "sessions"),
        session: [environment: {LeaseDenied, nil}]
      )

    case runtime_result do
      {:error, _conflict} ->
        :ok

      {:ok, runtime} ->
        assert {:ok, _observation} = BenchmarkRuntime.run(runtime, task(dir))

        refute File.exists?(Path.join(dir, "escaped-lease.txt")),
               "the ordinary host executor overrode the lease denial"
    end

    conflicts = [
      {:hooks, [], [before_tool: fn _call, _context -> {:error, :denied} end]},
      {:max_requests, 4, 1},
      {:store, host[:store], JSONL.new(Path.join(dir, "isolated-sessions"))}
    ]

    for {key, ordinary, isolated} <- conflicts do
      factory =
        Evaluation.factory(options, Keyword.put(host, key, ordinary),
          parent_profile: profile,
          surface: []
        )

      assert {:error, {:evaluation_session_conflict, ^key}} =
               factory.("refused", profile, provider,
                 sessions_dir: Path.join(dir, "sessions"),
                 session: [{key, isolated}]
               )
    end

    assert Scripted.requests(provider) == []
  end
end
