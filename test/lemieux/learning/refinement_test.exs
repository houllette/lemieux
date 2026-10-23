defmodule Lemieux.Learning.RefinementTest do
  use ExUnit.Case, async: true
  alias Lemieux.Learning.Refinement

  test "missing isolation refuses work without resolving a provider" do
    assert {:error, :isolation_required} = Refinement.preflight(nil, %{})
  end

  test "refinement receipts reject modified decisions" do
    assert {:error, _} = Refinement.verify(%{"schema_version" => 1, "decision" => "selected"})
  end

  alias Lemieux.Agent.Checkpoint
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime.Evaluation, as: CLI
  alias Lemieux.Contract
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Candidate
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Learning.Proposer
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir
  defmodule Confined do
    @behaviour Lemieux.Environment
    alias Lemieux.Environment.Local
    @impl true
    def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)
    @impl true
    def write_file(_state, cwd, path, content), do: Local.write_file(nil, cwd, path, content)
    @impl true
    def run(_state, _command, _opts), do: {:error, :processes_and_egress_denied}
  end

  defmodule Isolated do
    @behaviour Lemieux.Learning.Refinement.Isolation
    @impl true
    def inspect(state), do: {:ok, Agent.get(state, & &1.status)}
    @impl true
    def acquire(state, id, bindings) do
      if Agent.get(state, &Map.get(&1, :hold_acquisition, false)), do: Process.sleep(60_000)

      %{source: source, root: root, owner: owner, options: options, host: host} =
        Agent.get(state, & &1)

      dir = Path.join(root, id)
      {:ok, _} = File.cp_r(source, dir)
      send(owner, {:leased, dir})

      {:ok, prepared} =
        CLI.prepare(options, Keyword.put(host, :cwd, dir),
          surface: ["system_suffix", "tool_descriptions"]
        )

      {:ok,
       %{
         id: id,
         bindings: bindings,
         runtime_identity: CLI.identity(prepared),
         task: %Lemieux.Benchmark.Task{
           id: id,
           cwd: dir,
           prompt: "fix result.txt",
           timeout_ms: 5000,
           grader: %Lemieux.Benchmark.Grader.Command{command: ["true"]}
         },
         session: [environment: {Confined, nil}]
       }}
    end

    @impl true
    def validate(state, lease, bindings) do
      {:ok, status} = __MODULE__.inspect(state)

      if lease.bindings == bindings and status["bindings"] == bindings and
           File.read!(Path.join(lease.task.cwd, "input.txt")) == "original",
         do: :ok,
         else: {:error, :changed_lease}
    end

    @impl true
    def release(state, lease) do
      File.rm_rf!(lease.task.cwd)
      send(Agent.get(state, & &1.owner), {:released, lease.task.cwd})
      :ok
    end
  end

  defp profile do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => "test:model",
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => "Portable base",
          "max_turns" => 4,
          "max_tokens" => 100,
          "temperature" => 0.0,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "tool_descriptions" => %{}
        }
      },
      5
    )
  end

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "input.txt"), "original")
    runtime = :"refinement_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(Path.join(dir, "sessions"))

    {:ok, journal} =
      Lemieux.start_session(
        supervisor: runtime,
        store: store,
        provider: Scripted.new([]),
        model: "test:journal",
        tools: []
      )

    {:ok, handle} =
      Checkpoint.open(journal, "refinement", %{
        "workflow_digest" => "refinement/v1",
        "configuration_digest" => "test",
        "policy_digest" => "confined"
      })

    budget = start_supervised!({JobBudget, max_requests: 100})

    controller =
      start_supervised!(
        {Controller,
         job_id: "test",
         job_budget: budget,
         max_tokens: 100_000,
         max_time_ms: 120_000,
         cost_mode: :quota,
         learning: [
           max_requests: 100,
           max_tokens: 100_000,
           max_time_ms: 120_000,
           max_cost_usd: nil
         ]}
      )

    bindings =
      Map.new(
        ~w(source harness environment descriptors policy verification model),
        &{&1 <> "_sha256", Contract.sha256(&1)}
      )

    isolation =
      start_supervised!(
        {Agent,
         fn ->
           %{
             source: source,
             root: dir,
             owner: self(),
             status: %{
               "isolated" => true,
               "clean" => true,
               "bindings" => bindings,
               "effects" => ["workspace_write"]
             }
           }
         end}
      )

    owner = self()
    Agent.update(isolation, &%{&1 | owner: owner})

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

    host = [
      cwd: source,
      provider: Scripted.new([]),
      store: store,
      supervisor: runtime,
      # Exercise the loop's turn stop before the separate request cap. The
      # effective CLI runtime takes its limits from the host, not the profile.
      max_turns: 4,
      max_requests: 5,
      environment: {Confined, nil}
    ]

    Agent.update(isolation, &Map.merge(&1, %{options: options, host: host}))
    {:ok, prepared} = CLI.prepare(options, host, surface: ["system_suffix", "tool_descriptions"])

    factory =
      CLI.factory(options, host,
        parent_profile: profile(),
        surface: ["system_suffix", "tool_descriptions"]
      )

    {:ok, plan, _} =
      Campaign.plan(
        [
          id: "refinement",
          seed_profile: profile(),
          evolver_profile: Proposer.profile("test:model", quota: true),
          development_case_ids: ["task"],
          validation_case_ids: ["unexposed"],
          budget: %{
            "maximum_candidates" => 4,
            "maximum_tokens" => 10_000,
            "maximum_time_ms" => 60_000,
            "maximum_cost_usd" => 0.0,
            "unknown_cost" => "allow"
          },
          runtime_factory: factory,
          runtime_identity: CLI.identity(prepared)
        ],
        Contract.sha256("corpus")
      )

    provider = fn ->
      Scripted.new([
        fn request ->
          content =
            cond do
              String.contains?(request.system, "REGRESS") -> "bad"
              String.contains?(request.system, "GOOD") -> "fixed"
              true -> "baseline"
            end

          Scripted.tool_call("w", "write", %{"path" => "result.txt", "content" => content},
            usage: %{"input_tokens" => 2, "output_tokens" => 2}
          )
        end,
        Scripted.complete("done", usage: %{"input_tokens" => 2, "output_tokens" => 2})
      ])
    end

    assess = fn _observation, lease ->
      content = File.read!(Path.join(lease.task.cwd, "result.txt"))

      %{
        "score" => if(content == "fixed", do: 1.0, else: 0.25),
        "regression" => content == "bad",
        "verified_success" => content == "fixed"
      }
    end

    opts = [
      baseline: profile(),
      bindings: bindings,
      original: %{"answer" => "original output"},
      allocation: %{requests: 40, tokens: 10_000, time_ms: 60_000, cost_usd: nil},
      runtime_factory: factory,
      runtime_identity: CLI.identity(prepared),
      sessions_dir: Path.join(dir, "sessions"),
      controller: controller,
      isolation: {Isolated, isolation},
      provider: provider,
      token_bound: fn _ -> 100 end,
      assess: assess,
      expose: fn _ -> :ok end,
      signal: %{
        "id" => "failure",
        "kind" => "verification_failure",
        "hypothesis_supported" => true
      }
    ]

    %{
      handle: handle,
      plan: plan,
      opts: opts,
      isolation: isolation,
      budget: budget,
      controller: controller,
      source: source,
      runtime: runtime
    }
  end

  defp proposals(ctx, suffixes) do
    pairs =
      Enum.with_index(suffixes, fn suffix, index ->
        profile =
          if is_map(suffix),
            do: suffix,
            else: put_in(profile(), ["options", "system"], "Portable base " <> suffix)

        bytes = Contract.encode!(profile)
        rationale = "Observed mechanism: missing verification"

        {:ok, candidate} =
          Candidate.new(ctx.plan, %{
            "id" => "candidate-#{index}",
            "scope" => ctx.plan.scope,
            "parents" => [%{"id" => "seed", "content_sha256" => Contract.digest(profile())}],
            "content" =>
              ArtifactReference.from_bytes("candidate_content", bytes, scope: ctx.plan.scope)
              |> ArtifactReference.to_map(),
            "rationale" =>
              ArtifactReference.from_bytes("rationale", rationale, scope: ctx.plan.scope)
              |> ArtifactReference.to_map(),
            "proposer" => ctx.plan.proposer,
            "interface_validation" =>
              Surface.interface_validation(
                Surface.validate(ctx.plan, profile(), profile, bytes, "task_local")
              ),
            "exposures" => [],
            "mutation_kind" => "clonal",
            "extensions" => %{"mechanism" => "missing_verification"}
          })

        {candidate, [{candidate.content.sha256, bytes}, {candidate.rationale.sha256, rationale}]}
      end)

    {Enum.map(pairs, &elem(&1, 0)), Map.new(Enum.flat_map(pairs, &elem(&1, 1)))}
  end

  defp options(ctx, suffixes) do
    {candidates, artifacts} = proposals(ctx, suffixes)
    Keyword.put(ctx.opts, :propose, fn _context, _provider -> {:ok, candidates, artifacts} end)
  end

  defp bounded_provider(loop?, usage \\ %{"input_tokens" => 2, "output_tokens" => 2}) do
    fn -> Scripted.new(Enum.map(1..4, &bounded_turn(&1, loop?, usage))) end
  end

  defp bounded_turn(turn, loop?, usage) do
    fn request ->
      content = if String.contains?(request.system, "GOOD"), do: "fixed", else: "baseline"

      if turn == 1 or loop?.(request.system),
        do:
          Scripted.tool_call("w#{turn}", "write", %{"path" => "result.txt", "content" => content},
            usage: usage
          ),
        else: Scripted.complete("done", usage: usage)
    end
  end

  test "accounted turn-limited controls are scored failures that refinement can improve", ctx do
    owner = self()

    assess = fn observation, lease ->
      assessment = ctx.opts[:assess].(observation, lease)

      if observation["finish_reason"] == ":max_turns",
        do: send(owner, {:bounded_observation, observation, lease.runtime_identity, assessment})

      assessment
    end

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:verifier, true)
      |> Keyword.put(:assess, assess)
      |> Keyword.put(:provider, bounded_provider(&(not String.contains?(&1, "GOOD"))))

    assert {:ok, receipt} = Refinement.run(ctx.handle, "bounded-control", ctx.plan, opts)
    assert receipt["decision"] == "proposed"
    assert length(receipt["control"]) == 2

    assert Enum.all?(receipt["control"], fn record ->
             record["score"] == 0 and record["verified_success"] == false and
               record["stop_reason"] == "max_turns"
           end)

    assert Enum.all?(receipt["composition"], &(&1["verified_success"] == true))
    assert is_integer(Controller.snapshot(ctx.controller)["accounting"]["tokens"])
    assert :ok = Refinement.verify(receipt)

    assert_receive {:bounded_observation, observation, identity, assessment}

    for reason <- [":agent_timeout", ":benchmark_timeout", ":cancelled", ":error"] do
      assert {:error, :incomplete_probe_evidence} =
               Refinement.Evidence.record(
                 Map.put(observation, "finish_reason", reason),
                 assessment,
                 true,
                 identity
               )
    end

    failed = put_in(observation, ["provider_error", "category"], "timeout")

    assert {:error, :incomplete_probe_evidence} =
             Refinement.Evidence.record(failed, assessment, true, identity)
  end

  test "a turn-limited candidate cannot pass even when its files pass the verifier", ctx do
    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:verifier, true)
      |> Keyword.put(:provider, bounded_provider(&String.contains?(&1, "GOOD")))

    assert {:ok, receipt} = Refinement.run(ctx.handle, "bounded-candidate", ctx.plan, opts)
    assert receipt["decision"] == "baseline"
    assert receipt["composition"] == []
    assert [candidate] = receipt["candidates"]
    assert length(candidate["evaluations"]) == 2

    assert Enum.all?(candidate["evaluations"], fn record ->
             record["score"] == 0 and record["regression"] and
               record["verified_success"] == false and record["stop_reason"] == "max_turns" and
               record["verifier_score"] == 1 and record["scoring_rule"] == "completed_task"
           end)
  end

  test "a turn-limited probe with missing usage still requires recovery", ctx do
    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:provider, bounded_provider(fn _ -> true end, nil))

    assert {:error, {:requires_recovery, "unaccounted-bound"}} =
             Refinement.run(ctx.handle, "unaccounted-bound", ctx.plan, opts)

    assert Controller.snapshot(ctx.controller)["accounting"]["tokens"] == nil
  end

  test "registered artifact research preserves verified file outcomes at a known turn limit",
       ctx do
    policy = %{
      "id" => "experimental_mean/v2",
      "verified_ties" => true,
      "minimum_gain" => 0.1,
      "minimum_repetitions" => 2
    }

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:verifier, true)
      |> Keyword.put(:support_policy, policy)
      |> Keyword.put(:terminal_rule, :artifact_outcome)
      |> Keyword.put(:provider, bounded_provider(&String.contains?(&1, "GOOD")))

    assert {:ok, receipt} = Refinement.run(ctx.handle, "artifact-candidate", ctx.plan, opts)
    assert receipt["decision"] == "proposed"
    assert receipt["terminal_rule"] == "artifact_outcome"
    assert receipt["qualification"] == "experimental_task_local"

    assert Enum.all?(
             receipt["composition"],
             &(&1["score"] == 1 and &1["verified_success"] == true and
                 &1["stop_reason"] == "max_turns")
           )

    assert {:error, :invalid_refinement_configuration} =
             Refinement.run(
               ctx.handle,
               "strict-artifact",
               ctx.plan,
               Keyword.delete(opts, :support_policy)
             )
  end

  test "artifact research cannot credit unknown budget stops, provider failures or cancellation",
       ctx do
    owner = self()

    assess = fn observation, lease ->
      assessment = ctx.opts[:assess].(observation, lease)
      send(owner, {:artifact_source, observation, lease.runtime_identity, assessment})
      assessment
    end

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:verifier, true)
      |> Keyword.put(:terminal_rule, :artifact_outcome)
      |> Keyword.put(:support_policy, %{
        "id" => "experimental_mean/v2",
        "verified_ties" => true,
        "minimum_gain" => 0.1,
        "minimum_repetitions" => 2
      })
      |> Keyword.put(:assess, assess)
      |> Keyword.put(:on_incomplete, fn cause ->
        send(owner, {:incomplete_refinement, cause})
        :ok
      end)
      |> Keyword.put(:provider, bounded_provider(fn _ -> true end))

    result = Refinement.run(ctx.handle, "artifact-sources", ctx.plan, opts)

    assert match?({:ok, _receipt}, result),
           inspect(
             %{
               result: result,
               messages: Process.info(self(), :messages),
               checkpoint: Checkpoint.status(ctx.handle, "artifact-sources"),
               controller: Controller.snapshot(ctx.controller)
             },
             limit: 100,
             printable_limit: 4096
           )

    assert_receive {:artifact_source, observation, identity, assessment}

    assert {:ok, record} =
             Refinement.Evidence.record(
               observation,
               assessment,
               true,
               identity,
               :artifact_outcome
             )

    assert record["score"] == assessment["score"]

    for reason <- [":cancelled", ":error", ":agent_timeout", ":benchmark_timeout"] do
      assert {:error, :incomplete_probe_evidence} =
               Refinement.Evidence.record(
                 Map.put(observation, "finish_reason", reason),
                 assessment,
                 true,
                 identity,
                 :artifact_outcome
               )
    end

    failed = put_in(observation, ["provider_error", "category"], "timeout")

    assert {:error, :incomplete_probe_evidence} =
             Refinement.Evidence.record(failed, assessment, true, identity, :artifact_outcome)
  end

  test "artifact research still requires recovery when turn-limit usage is unknown", ctx do
    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:verifier, true)
      |> Keyword.put(:terminal_rule, :artifact_outcome)
      |> Keyword.put(:support_policy, %{
        "id" => "experimental_mean/v2",
        "verified_ties" => true,
        "minimum_gain" => 0.1,
        "minimum_repetitions" => 2
      })
      |> Keyword.put(:provider, bounded_provider(fn _ -> true end, nil))

    assert {:error, {:requires_recovery, "artifact-unknown"}} =
             Refinement.run(ctx.handle, "artifact-unknown", ctx.plan, opts)
  end

  test "a matched contrast retains a real improvement and records an independent regression",
       ctx do
    assert {:ok, receipt} =
             Refinement.run(ctx.handle, "probe", ctx.plan, options(ctx, ["GOOD", "REGRESS"]))

    assert receipt["decision"] == "proposed"
    assert receipt["qualification"] == "behavioral_unconfirmed"
    assert receipt["original"] == %{"answer" => "original output"}
    assert length(receipt["composition"]) == 2

    assert Enum.any?(receipt["candidates"], fn c ->
             Enum.any?(c["evaluations"], & &1["regression"])
           end)

    assert Enum.all?(receipt["composition"], &is_nil(&1["verified_success"]))
    assert :ok = Refinement.verify(receipt)
    refute File.exists?(Path.join(ctx.source, "result.txt"))
    assert JobBudget.snapshot(ctx.budget).requests == 40
    assert Controller.snapshot(ctx.controller)["accounting"]["tokens"] > 0
  end

  test "a verifier qualifies only task-local checks and a tie keeps the original", ctx do
    assert {:ok, receipt} =
             Refinement.run(
               ctx.handle,
               "verified",
               ctx.plan,
               Keyword.put(options(ctx, ["GOOD"]), :verifier, true)
             )

    assert receipt["qualification"] == "task_local_verified"

    assert {:ok, baseline} =
             Refinement.run(
               ctx.handle,
               "tied",
               ctx.plan,
               options(ctx, ["nothing"])
               |> Keyword.put(:signal, %{
                 "id" => "tied",
                 "kind" => "verification_failure",
                 "hypothesis_supported" => true
               })
             )

    assert baseline["decision"] == "baseline"
    assert length(baseline["candidates"]) == 1
    assert baseline["selected_sha256"] == baseline["original_profile_sha256"]
  end

  test "conflicting supported edits are both excluded", ctx do
    assert {:ok, receipt} =
             Refinement.run(ctx.handle, "conflict", ctx.plan, options(ctx, ["GOOD A", "GOOD B"]))

    assert receipt["decision"] == "baseline"
    assert length(receipt["excluded"]) == 2
    assert Enum.all?(receipt["excluded"], &(&1["reason"] == "conflicting_edit"))
    assert receipt["composition"] == []
  end

  test "experimental append-only proposals compose and execute before scoped selection", ctx do
    owner = self()

    opts =
      options(ctx, ["GOOD GENERAL", "GOOD DOMAIN"])
      |> Keyword.put(:support_policy, %{
        "id" => "experimental_mean/v1",
        "minimum_gain" => 0.1,
        "minimum_repetitions" => 2
      })
      |> Keyword.put(:observe_probe, fn record ->
        send(owner, {:probe_record, record})
        :ok
      end)

    assert {:ok, receipt} = Refinement.run(ctx.handle, "research-compose", ctx.plan, opts)
    assert receipt["decision"] == "proposed"
    assert receipt["qualification"] == "experimental_task_local"

    assert receipt["selected_profile"]["options"]["system"] ==
             "Portable base GOOD GENERAL GOOD DOMAIN"

    assert length(receipt["candidate_ids"]) == 2
    assert length(receipt["composition"]) == 2
    assert receipt["excluded"] == []

    assert_receive {:probe_record,
                    %{"phase" => "composition", "observation" => %{"status" => "completed"}}}
  end

  test "dirty, drifting and unconfined inputs refuse before provider resolution", ctx do
    for changes <- [
          %{"clean" => false},
          %{"bindings" => %{}},
          %{"effects" => ["network"]},
          %{"isolated" => false}
        ] do
      old = Agent.get(ctx.isolation, & &1.status)
      Agent.update(ctx.isolation, &%{&1 | status: Map.merge(old, changes)})

      opts =
        options(ctx, ["GOOD"])
        |> Keyword.put(:provider, fn -> flunk("resolved a refused provider") end)

      assert {:ok, result} =
               Refinement.run(
                 ctx.handle,
                 "refused-#{map_size(changes)}-#{inspect(changes)}",
                 ctx.plan,
                 opts
               )

      assert result["decision"] == "baseline"
      assert result["control"] == []
      Agent.update(ctx.isolation, &%{&1 | status: old})
    end

    assert JobBudget.snapshot(ctx.budget).requests == 0
  end

  test "completed checkpoints recheck current host isolation", ctx do
    opts = options(ctx, ["GOOD"])
    assert {:ok, receipt} = Refinement.run(ctx.handle, "cached", ctx.plan, opts)
    assert {:ok, ^receipt} = Refinement.run(ctx.handle, "cached", ctx.plan, opts)
    Agent.update(ctx.isolation, &put_in(&1, [:status, "clean"], false))
    assert {:error, _} = Refinement.run(ctx.handle, "cached", ctx.plan, opts)
    assert JobBudget.snapshot(ctx.budget).requests == 40
    assert {:error, _} = Refinement.verify(Map.put(receipt, "decision", "baseline"))
  end

  test "unsupported edits and tampered rationale never enter candidate probes", ctx do
    forbidden = put_in(profile(), ["tools"], ["bash"])
    {candidates, artifacts} = proposals(ctx, [forbidden, "GOOD"])
    artifacts = Map.put(artifacts, hd(candidates).rationale.sha256, "tampered rationale")
    opts = Keyword.put(ctx.opts, :propose, fn _, _ -> {:ok, candidates, artifacts} end)
    assert {:ok, receipt} = Refinement.run(ctx.handle, "unsupported", ctx.plan, opts)
    assert receipt["decision"] == "baseline"
    assert receipt["candidates"] == []
    assert length(receipt["excluded"]) == 2
  end

  test "exposure must commit before proposer access and never retries in-doubt work", ctx do
    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:expose, fn _ -> {:error, :storage_failed} end)
      |> Keyword.put(:propose, fn _, _ -> flunk("proposer saw uncommitted input") end)

    assert {:error, {:requires_recovery, "exposure"}} =
             Refinement.run(ctx.handle, "exposure", ctx.plan, opts)

    before = Controller.snapshot(ctx.controller)["accounting"]

    assert {:error, {:requires_recovery, "exposure"}} =
             Refinement.run(ctx.handle, "exposure", ctx.plan, opts)

    assert Controller.snapshot(ctx.controller)["accounting"] == before
  end

  test "a weaker executed composition keeps the baseline and original output", ctx do
    counter = start_supervised!({Agent, fn -> 0 end}, id: :assessments)

    assess = fn observation, lease ->
      index = Agent.get_and_update(counter, &{&1, &1 + 1})
      score = if index in 2..3, do: 1.0, else: 0.25
      ctx.opts[:assess].(observation, lease) |> Map.put("score", score)
    end

    assert {:ok, receipt} =
             Refinement.run(
               ctx.handle,
               "weaker",
               ctx.plan,
               Keyword.put(options(ctx, ["GOOD"]), :assess, assess)
             )

    assert receipt["decision"] == "baseline"
    assert receipt["reason"] == "composition_not_supported"
    assert length(receipt["composition"]) == 2
    assert receipt["original"] == %{"answer" => "original output"}
  end

  test "overlapping repeated scores abstain instead of hiding variability", ctx do
    counter = start_supervised!({Agent, fn -> [0.25, 0.6, 1.0, 0.5] end}, id: :scores)

    assess = fn observation, lease ->
      score = Agent.get_and_update(counter, fn [head | tail] -> {head, tail} end)
      ctx.opts[:assess].(observation, lease) |> Map.put("score", score)
    end

    assert {:ok, receipt} =
             Refinement.run(
               ctx.handle,
               "variable",
               ctx.plan,
               Keyword.put(options(ctx, ["GOOD"]), :assess, assess)
             )

    assert receipt["decision"] == "baseline"
    assert Enum.map(receipt["control"], & &1["score"]) == [0.25, 0.6]
    assert Enum.map(hd(receipt["candidates"])["evaluations"], & &1["score"]) == [1.0, 0.5]
    assert receipt["composition"] == []
  end

  test "caller cancellation cleans sessions and leases, keeps spend uncertain and requires recovery",
       ctx do
    owner = self()

    provider = fn ->
      Scripted.new([
        fn _ ->
          send(owner, {:request_running, self()})
          Process.sleep(60_000)
          Scripted.complete("late")
        end
      ])
    end

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:on_incomplete, fn cause ->
        send(owner, {:incomplete_refinement, cause})
        :ok
      end)

    pid = spawn(fn -> Refinement.run(ctx.handle, "cancelled", ctx.plan, opts) end)
    assert_receive {:leased, path}

    request =
      try do
        assert_receive {:request_running, request}
        request
      rescue
        error in ExUnit.AssertionError ->
          details = {
            Process.info(pid, :current_stacktrace),
            Process.info(self(), :messages),
            Checkpoint.status(ctx.handle, "cancelled"),
            Controller.snapshot(ctx.controller)
          }

          reraise %{
                    error
                    | message:
                        error.message <>
                          "\nRefinement diagnostics: " <>
                          inspect(details, limit: 100, printable_limit: 4096)
                  },
                  __STACKTRACE__
      end

    request_monitor = Process.monitor(request)
    caller_monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^pid, :killed}
    assert_receive {:released, ^path}
    assert_receive {:DOWN, ^request_monitor, :process, ^request, _}
    refute File.exists?(path)

    assert {:error, {:requires_recovery, "cancelled"}} =
             Refinement.run(ctx.handle, "cancelled", ctx.plan, opts)

    assert Controller.snapshot(ctx.controller)["accounting"]["tokens"] == nil
    assert JobBudget.snapshot(ctx.budget).requests == 40
    refute_receive {:request_running, _}, 30
  end

  test "a pre-dispatch acquisition timeout retains its cause and still requires recovery", ctx do
    owner = self()
    Agent.update(ctx.isolation, &Map.put(&1, :hold_acquisition, true))

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:acquisition_timeout_ms, 25)
      |> Keyword.put(:on_incomplete, fn cause ->
        send(owner, {:cause, cause})
        :ok
      end)

    assert {:error, {:requires_recovery, "lease-timeout"}} =
             Refinement.run(ctx.handle, "lease-timeout", ctx.plan, opts)

    assert_receive {:cause,
                    %{
                      "cause" => %{
                        "phase" => "control",
                        "attempt" => 1,
                        "reason" => "resource_start_timeout"
                      }
                    }}

    refute_receive {:leased, _}, 30

    assert {:error, {:requires_recovery, "lease-timeout"}} =
             Refinement.run(ctx.handle, "lease-timeout", ctx.plan, opts)

    refute_receive {:cause, _}, 30
  end

  test "a zero learning allowance resolves no provider", ctx do
    controller =
      start_supervised!(
        {Controller,
         job_id: "disabled",
         job_budget: ctx.budget,
         max_tokens: 100_000,
         max_time_ms: 120_000,
         cost_mode: :quota},
        id: :disabled
      )

    opts =
      options(ctx, ["GOOD"])
      |> Keyword.put(:controller, controller)
      |> Keyword.put(:provider, fn -> flunk("resolved provider with no learning allowance") end)

    assert {:ok, receipt} = Refinement.run(ctx.handle, "disabled", ctx.plan, opts)
    assert receipt["decision"] == "baseline"
    assert receipt["control"] == []
    assert JobBudget.snapshot(ctx.budget).requests == 0
  end
end
