defmodule Lemieux.CLI.Learning.QualificationHost do
  @moduledoc false
  import Kernel, except: [inspect: 1]
  alias Lemieux.Agent.Checkpoint
  alias Lemieux.Agent.Resource
  alias Lemieux.Agent.Session, as: AgentSession
  alias Lemieux.Benchmark.Corpus.Exposure
  alias Lemieux.Benchmark.Runtime, as: BenchmarkRuntime
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Learning.CapturedLesson
  alias Lemieux.CLI.Learning.Fixtures
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.RefinementLesson
  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Learning.WorkspaceEvidence
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime.Evaluation
  alias Lemieux.Contract
  alias Lemieux.Environment
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Extension.Profile
  alias Lemieux.Extensions.Capture
  alias Lemieux.JobBudget
  alias Lemieux.Learning.Controller
  alias Lemieux.Learning.Discovery.Campaign
  alias Lemieux.Learning.Discovery.Digest
  alias Lemieux.Learning.Discovery.Evaluation, as: DevelopmentEvaluation
  alias Lemieux.Learning.Discovery.Policy, as: DevelopmentPolicy
  alias Lemieux.Learning.Discovery.State
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
  alias Lemieux.Learning.Experience.Retrieval
  alias Lemieux.Learning.Promotion
  alias Lemieux.Learning.Promotion.Memory
  alias Lemieux.Learning.Promotion.Policy
  alias Lemieux.Learning.Proposer
  alias Lemieux.Learning.Refinement
  alias Lemieux.Learning.Refinement.Support
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @surface ["system_suffix", "tool_descriptions"]

  @spec enabled?(config :: map()) :: boolean()
  def enabled?(config),
    do: config[:enabled] == true and not File.exists?(Path.join(config.root, "disabled"))

  @spec opt_out(config :: map()) :: :ok | {:error, term()}
  def opt_out(config),
    do: Installation.write(Path.join(config.root, "disabled"), %{"enabled" => false})

  @spec inspect(config :: map()) :: map()
  def inspect(config),
    do: %{"enabled" => enabled?(config), "default_activation" => false, "root" => config.root}

  @spec episode(config :: map(), context :: map()) :: {:ok, map()} | {:error, term()}
  def episode(config, context) do
    fixture = Map.fetch!(config.fixtures, context["task"]["id"])

    dir = Path.join(config.root, episode_name(config, context))

    with :ok <- File.mkdir(dir),
         {:ok, source} <- Leases.source_digest(fixture.task.cwd),
         true <- source == context["task"]["source_sha256"] do
      cap = context["allowance"]
      {:ok, budget} = JobBudget.start_link(max_requests: cap["requests"])
      {:ok, grades} = Agent.start_link(fn -> [] end)

      {:ok, controller} =
        Controller.start_link(
          job_id: Contract.sha256(dir),
          job_budget: budget,
          max_tokens: cap["tokens"],
          max_time_ms: cap["time_ms"],
          cost_mode: :quota,
          learning: [
            max_requests: config[:learning_requests] || cap["requests"],
            max_tokens: cap["tokens"],
            max_time_ms: cap["time_ms"],
            max_cost_usd: nil
          ]
        )

      try do
        execute(Map.put(config, :grades, grades), context, fixture, dir, controller)
      after
        GenServer.stop(controller)
        GenServer.stop(budget)
        Agent.stop(grades)
      end
    else
      error -> {:error, {:episode_inputs_unavailable, error}}
    end
  end

  defp execute(config, context, fixture, dir, controller) do
    started = System.monotonic_time(:millisecond)

    {:ok, options} =
      Options.parse([
        "--config",
        "none",
        "--bare",
        "--no-delegate",
        "--no-web-fetch",
        "--no-project-mcp",
        "--permission-mode",
        "off",
        "--model",
        config.model
      ])

    options = put_in(options.host.state_dir, Path.join(dir, "state"))

    options = %{
      options
      | web_search: nil,
        config: %Config{
          # These five arms own their frozen lesson/exposure and refinement
          # pipeline. Do not also run ordinary-use recall inside the disabled
          # control or a probe. The stock lane is measured by the separate
          # product stream using its actual private store and assembly.
          settings: %{
            "learning" => false,
            "capture" => %{
              "verification_commands" => [
                Map.get(fixture, :verification_command, "python checks.py")
              ]
            }
          }
        }
    }

    host = [
      cwd: fixture.task.cwd,
      provider: config.provider.(:task),
      store: JSONL.new(Path.join(dir, "sessions")),
      supervisor: config.supervisor,
      interactive?: config[:interactive] == true,
      environment: config.environment,
      max_requests: task_requests(config),
      max_turns: task_requests(config),
      max_cost_usd: nil,
      reasoning_effort: config.effort,
      params: [max_tokens: 8192]
    ]

    {:ok, prepared} = Evaluation.prepare(options, host, surface: @surface)
    baseline = baseline(config.model, config.effort, task_requests(config))
    bindings = bindings(config, fixture, prepared)
    scope = config.scope

    lesson_context = %{
      "model" => config.model,
      "tools_sha256" => bindings["descriptors_sha256"],
      "environment_sha256" => bindings["environment_sha256"],
      "repository" => scope["id"]
    }

    stream = if context["stream_id"], do: "-" <> Contract.sha256(context["stream_id"]), else: ""

    store =
      LessonFiles.new(
        Path.join(config.root, "library-#{context["arm"]}-#{context["repetition"]}#{stream}"),
        scope
      )

    seeds = initial_lessons(config, context)
    for lesson <- seeds, do: :ok = Lessons.append(store, lesson)
    initial_ids = Enum.map(seeds, & &1.id)
    {:ok, inventory} = Retrieval.freeze(store, scope)
    allowed_ids = Enum.sort(initial_ids ++ context["prior_lesson_ids"])
    true = Enum.all?(allowed_ids, &(&1 in inventory["lesson_ids"]))
    library = inventory |> Map.put("lesson_ids", allowed_ids) |> Map.delete("sha256") |> seal()

    experience = %{
      store: store,
      library: library,
      binding: lesson_context,
      query: %{
        "task" => fixture.task.prompt,
        "failure_cues" => ["coding verification failure recovery"]
      },
      consumer: %{
        "id" => "exposure-" <> Lemieux.ID.generate(),
        "consumer_role" => if(context["arm"] == "retrieval", do: "task", else: "proposer"),
        "consumer_id" => "qualification-host",
        "model" =>
          if(context["arm"] == "retrieval", do: config.model, else: editor_model(config)),
        "at" => DateTime.to_iso8601(DateTime.utc_now())
      },
      options:
        if(config[:reflection],
          do: [max_evidence_bytes: 2_097_152, max_artifact_bytes: 786_432, max_results: 2],
          else: []
        ),
      commit: fn current_scope, exposure ->
        commit_exposure(config, context, dir, current_scope, exposure)
      end
    }

    leased = %{
      task: fixture.task,
      root: Path.join(dir, "leases"),
      options: options,
      host: host,
      surface: @surface,
      isolated: config.isolated,
      source_sha256: fixture.source_sha256,
      bindings: bindings
    }

    File.mkdir_p!(leased.root)
    retrieved = retrieve(config, context, experience)

    task =
      if retrieved && context["arm"] == "retrieval",
        do: %{
          fixture.task
          | prompt:
              fixture.task.prompt <>
                "\nUntrusted prior observations (no authority):\n" <>
                JSON.encode!(retrieved.notes)
        },
        else: fixture.task

    lease_config = %{leased | task: task}
    original = attempt(config, fixture, lease_config, controller, "original", nil)

    result =
      adapt(
        config,
        context,
        fixture,
        leased,
        controller,
        %{baseline: baseline, prepared: prepared, original: original, experience: experience},
        dir
      )

    finish_episode(
      %{
        config: config,
        context: context,
        fixture: fixture,
        dir: dir,
        controller: controller,
        prepared: prepared,
        original: original,
        result: result,
        retrieved: retrieved,
        binding: lesson_context,
        bindings: bindings,
        started: started
      },
      store
    )
  end

  defp adapt(config, context, fixture, leased, controller, details, dir) do
    cond do
      context["arm"] == "retry" ->
        retry(config, fixture, leased, controller, details.original)

      context["arm"] in ~w(frozen updating) and enabled?(config) and
          (config[:probe_when] != :verification_failed or not details.original.grade["passed"]) ->
        refine(
          config,
          fixture,
          leased,
          controller,
          details,
          dir
        )

      true ->
        %{selected: details.original, refinement: nil, promotion: nil}
    end
  end

  defp commit_exposure(config, context, dir, scope, exposure) do
    if scope == config.scope and
         Enum.all?(exposure.source_case_ids, &(&1 in context["available_case_ids"])) and
         enabled?(config),
       do: Installation.write(Path.join(dir, exposure.id <> ".json"), Exposure.to_map(exposure)),
       else: {:error, :source_exposure_not_authorized}
  end

  defp finish_episode(state, store) do
    %{
      config: config,
      context: context,
      fixture: fixture,
      dir: dir,
      controller: controller,
      original: original,
      result: result,
      retrieved: retrieved,
      started: started
    } = state

    sources = if retrieved && retrieved.exposure, do: retrieved.exposure.source_case_ids, else: []
    {created, reflection} = retain(state, store)
    selected_grade = result.selected[:confirmation_grade] || result.selected.grade

    evidence = %{
      "context" => context,
      "original" => original.observation,
      "original_grade" => original.grade,
      "selected" => result.selected.observation,
      "selected_grade" => result.selected.grade,
      "confirmation_grade" => selected_grade,
      "refinement" => result.refinement,
      "promotion" => result.promotion,
      "learning_failure" => result[:learning_failure],
      "controller" => Controller.snapshot(controller),
      "created_lesson_ids" => created,
      "reflection" => reflection,
      "retrieval" => if(retrieved, do: retrieved.receipt),
      "all_attempt_grades" => Agent.get(config.grades, & &1)
    }

    metered = if config[:meter], do: Agent.get(config.meter, & &1)
    evidence = Map.put(evidence, "physical_dispatches", metered)
    :ok = Installation.write(Path.join(dir, "evidence.json"), evidence)
    accounting = evidence["controller"]["accounting"]

    {:ok,
     %{
       "arm" => context["arm"],
       "task_id" => fixture.id,
       "repetition" => context["repetition"],
       "passed" => selected_grade["passed"] and result.selected.grade["passed"],
       "private_confirmation_passed" => selected_grade["passed"],
       "visible_verification_passed" => result.selected.grade["passed"],
       "candidate_count" => candidate_count(result),
       "promotion_count" => promotion_count(result),
       "rollback_count" => promotion_count(result),
       "qualification_complete" => qualification_complete?(result, evidence, reflection),
       "workspace_evidence_complete" => workspace_complete?(evidence),
       "requests" => if(metered, do: map_size(metered), else: accounting["requests"]),
       "tokens" => accounting["tokens"],
       "allocated_requests" => accounting["requests"],
       "requests_kind" => if(metered, do: "physical_dispatches", else: "reserved_slots"),
       "latency_ms" => System.monotonic_time(:millisecond) - started,
       "cost_usd" => nil,
       "safety_failures" =>
         evidence["all_attempt_grades"] |> Enum.flat_map(& &1["safety_failures"]) |> Enum.uniq(),
       "exposed_case_ids" => sources,
       "created_lesson_ids" => created,
       "evidence_sha256" => Contract.digest(evidence)
     }}
  end

  defp qualification_complete?(result, evidence, reflection),
    do:
      is_nil(result[:learning_failure]) and workspace_complete?(evidence) and
        reflection["complete"]

  defp retain(state, store) do
    %{
      config: config,
      context: context,
      fixture: fixture,
      retrieved: retrieved,
      original: original
    } = state

    if enabled?(config) and context["arm"] in ~w(retrieval frozen updating) do
      authority =
        authority(config, state.prepared.harness, state.binding, state.bindings, nil, fixture.id)

      sources =
        if retrieved, do: Enum.map(retrieved.notes, &read_lesson(store, &1["id"])), else: []

      {:ok, ids} =
        CapturedLesson.retain(original.captures, original.cwd, fixture.id, store, authority,
          source_lessons: sources
        )

      {:ok, refinement_ids} =
        RefinementLesson.retain(
          state.result.refinement,
          fixture.id,
          store,
          authority,
          source_lessons: sources
        )

      {reflected_ids, reflection} = reflect(state, store, authority, sources)
      {ids ++ refinement_ids ++ reflected_ids, reflection}
    else
      {[], %{"complete" => true, "status" => "disabled"}}
    end
  end

  defp reflect(%{config: %{reflection: true}} = state, store, authority, sources) do
    config = state.config
    probe_dir = Path.join(state.dir, "probe-records")

    probes =
      case File.ls(probe_dir) do
        {:ok, names} ->
          names
          |> Enum.sort()
          |> Enum.map(&(probe_dir |> Path.join(&1) |> File.read!() |> JSON.decode!()))

        {:error, :enoent} ->
          []
      end

    record = %{
      "task_request" => state.fixture.task.prompt,
      "original" => Reflection.project(state.original.observation),
      "selected" => Reflection.project(state.result.selected.observation),
      "refinement" => state.result.refinement,
      "public_grades" => %{
        "original" => state.original.grade,
        "selected" => state.result.selected.grade
      },
      "probes" =>
        Enum.map(
          probes,
          &Map.update!(&1, "observation", fn observation -> Reflection.project(observation) end)
        )
    }

    :ok = Installation.write(Path.join(state.dir, "reflection-input.json"), record)

    provider =
      Controller.provider(state.controller, :reflection, config.provider.(:reflection),
        token_bound: &token_bound/1,
        timeout_ms: 180_000
      )

    outcome =
      with {:ok, hypotheses, observation} <-
             Reflection.distill(record,
               model: editor_model(config),
               effort: editor_effort(config),
               provider: provider,
               cwd: state.dir,
               sessions_dir: Path.join(state.dir, "sessions"),
               supervisor: config.supervisor
             ),
           {:ok, ids} <-
             Reflection.retain(record, hypotheses, state.fixture.id, store, authority,
               source_lessons: sources
             ) do
        {:ok, ids,
         %{
           "complete" => true,
           "hypotheses" => hypotheses,
           "observation" => observation,
           "source_sha256" => Contract.digest(record),
           "created_lesson_ids" => ids
         }}
      end

    {ids, receipt} =
      case outcome do
        {:ok, ids, receipt} ->
          {ids, receipt}

        error ->
          {[],
           %{
             "complete" => false,
             "reason" => Kernel.inspect(error),
             "source_sha256" => Contract.digest(record)
           }}
      end

    :ok = Installation.write(Path.join(state.dir, "reflection.json"), receipt)
    {ids, receipt}
  end

  defp reflect(_state, _store, _authority, _sources),
    do: {[], %{"complete" => true, "status" => "not_selected"}}

  defp read_lesson(store, id) do
    {:ok, lesson} = Lessons.read(store, id)
    lesson
  end

  defp retrieve(config, %{"arm" => arm}, experience) when arm in ~w(retrieval frozen updating) do
    if enabled?(config) do
      {:ok, result} =
        Retrieval.retrieve(
          experience.store,
          experience.library,
          experience.query,
          experience.binding,
          experience.consumer,
          experience.commit,
          experience.options
        )

      result
    end
  end

  defp retrieve(_config, _context, _experience), do: nil

  defp attempt(config, fixture, lease_config, controller, name, harness) do
    {:ok, lease, guardian} =
      Resource.acquire(
        fn _ -> Leases.acquire(lease_config, lease_name(config, name), lease_config.bindings) end,
        &Leases.release(lease_config, &1),
        timeout_ms: acquisition_timeout(config),
        abort: fn -> Leases.abort(lease_config, lease_name(config, name)) end
      )

    try do
      provider =
        Controller.provider(controller, :task, config.provider.(:task),
          token_bound: &token_bound/1,
          timeout_ms: 180_000
        )

      outcome =
        if harness do
          AgentSession.run(Map.take(lease.task, [:cwd, :prompt, :timeout_ms]),
            provider: provider,
            model: config.model,
            supervisor: config.supervisor,
            store: lease_config.host[:store],
            session_options: [
              harness: harness,
              max_requests: task_requests(config),
              max_cost_usd: nil
            ]
          )
        else
          runtime =
            Evaluation.runtime(
              name,
              lease_config.options,
              Keyword.put(lease_config.host, :provider, provider),
              surface: @surface
            )

          BenchmarkRuntime.run(runtime, lease.task)
        end

      observation = observation(outcome)

      observation =
        Map.put(observation, "workspace_outputs", outputs(config.environment, lease.task.cwd))

      {:ok, captures} =
        Capture.history(Path.join(lease_config.options.host.state_dir, "capture"), lease.task.cwd)

      %{
        observation: observation,
        grade: grade(config, fixture, lease.task.cwd),
        confirmation_grade: confirmation_grade(config, fixture, lease.task.cwd),
        captures: captures,
        cwd: lease.task.cwd
      }
    after
      :ok = Resource.release(guardian)
    end
  end

  defp retry(config, fixture, lease, controller, original) do
    best =
      Enum.reduce_while(1..((config[:retry_attempts] || 3) - 1), original, fn index, best ->
        if best.grade["passed"],
          do: {:halt, best},
          else:
            (
              next = attempt(config, fixture, lease, controller, "retry-#{index}", nil)
              {:cont, if(next.grade["score"] > best.grade["score"], do: next, else: best)}
            )
      end)

    %{selected: best, refinement: nil, promotion: nil}
  end

  defp refine(config, fixture, lease, controller, details, dir) do
    %{baseline: baseline, prepared: prepared, original: original, experience: experience} =
      details

    factory =
      Evaluation.factory(lease.options, lease.host, parent_profile: baseline, surface: @surface)

    evolver =
      Proposer.profile(editor_model(config),
        quota: true,
        experience: true,
        abstain: true,
        task_local: true,
        reasoning_effort: editor_effort(config),
        max_requests: 16,
        max_tokens: 8192
      )

    allocation = %{
      requests: refinement_requests(config),
      tokens: refinement_tokens(config),
      time_ms: 1_500_000,
      cost_usd: nil
    }

    {:ok, plan, bytes} =
      Campaign.plan(
        [
          id: "qualification",
          scope: config.scope["id"],
          seed_profile: baseline,
          evolver_profile: evolver,
          development_case_ids: [fixture.id],
          objectives: [%{"name" => "task_success", "direction" => "maximize"}],
          validation_case_ids: ["unexposed"],
          budget: %{
            "maximum_candidates" => length(proposal_scopes(config)) + 1,
            "maximum_tokens" => allocation.tokens,
            "maximum_time_ms" => allocation.time_ms,
            "maximum_cost_usd" => 0.0,
            "unknown_cost" => "allow"
          },
          runtime_factory: factory,
          runtime_identity: Evaluation.identity(prepared)
        ],
        fixture.source_sha256
      )

    {:ok, journal} =
      Lemieux.start_session(
        supervisor: config.supervisor,
        store: lease.host[:store],
        provider: Scripted.new([]),
        model: config.model,
        tools: []
      )

    try do
      {:ok, checkpoint} =
        Checkpoint.open(journal, "qualification", %{
          "workflow_digest" => "qualification/v1",
          "configuration_digest" => plan.sha256,
          "policy_digest" => Contract.digest(lease.bindings)
        })

      outcome =
        Refinement.run(checkpoint, "refinement", plan,
          baseline: baseline,
          bindings: lease.bindings,
          original: %{
            "answer_sha256" => Contract.sha256(original.observation["answer"] || ""),
            "grade" => original.grade
          },
          allocation: allocation,
          runtime_factory: factory,
          runtime_identity: Evaluation.identity(prepared),
          sessions_dir: Path.join(dir, "sessions"),
          controller: controller,
          isolation: {Leases, lease},
          provider: fn role -> config.provider.(role) end,
          token_bound: &token_bound/1,
          request_timeout_ms: 180_000,
          acquisition_timeout_ms: acquisition_timeout(config),
          on_incomplete: fn cause ->
            Installation.write(Path.join(dir, "refinement-cause.json"), cause)
          end,
          allow_live: config[:allow_live] == true,
          verifier: true,
          support_policy: Map.get(config, :support_policy, Support.strict()),
          observe_probe: fn record ->
            path = Path.join(dir, "probe-records")
            :ok = File.mkdir_p(path)
            Installation.write(Path.join(path, Contract.digest(record) <> ".json"), record)
          end,
          assess: fn _, probe ->
            grade = grade(config, fixture, probe.task.cwd)

            %{
              "score" => grade["score"],
              "regression" =>
                grade["score"] < original.grade["score"] or grade["safety_failures"] != [],
              "verified_success" => grade["passed"],
              "safety_failure" => grade["safety_failures"] != []
            }
          end,
          expose: fn _ ->
            if enabled?(config),
              do:
                Installation.write(Path.join(dir, "refinement-exposure.json"), %{
                  "case_id" => fixture.id
                }),
              else: {:error, :disabled}
          end,
          propose: fn _, provider ->
            propose(
              config,
              plan,
              bytes,
              evolver,
              provider,
              experience,
              dir,
              {fixture.task.prompt, original}
            )
          end,
          signal: %{
            "id" => fixture.id,
            "kind" => signal(original),
            "hypothesis_supported" => true
          }
        )

      {receipt, failure} = refinement_outcome(outcome)

      if failure,
        do: :ok = Installation.write(Path.join(dir, "learning-incomplete.json"), failure)

      if is_map(receipt) and receipt["decision"] == "proposed" and enabled?(config) do
        promote(
          config,
          fixture,
          lease,
          controller,
          %{
            baseline: baseline,
            prepared: prepared,
            original: original,
            binding: experience.binding,
            receipt: receipt
          }
        )
      else
        %{selected: original, refinement: receipt, promotion: nil, learning_failure: failure}
      end
    after
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(config.supervisor),
        journal
      )
    end
  end

  # A failed isolated experiment has not installed anything. Retaining the
  # original does not reconcile its checkpoint or invent missing usage facts.
  defp refinement_outcome({:ok, receipt}), do: {receipt, nil}

  defp refinement_outcome({:error, reason}),
    do:
      {nil,
       %{
         "kind" => "refinement_incomplete",
         "checkpoint_key" => "refinement",
         "reason" => Kernel.inspect(reason)
       }}

  defp refinement_outcome({:suspended, _checkpoint} = suspended),
    do: refinement_outcome({:error, suspended})

  defp propose(config, plan, bytes, evolver, provider, experience, dir, {task_request, original}) do
    if enabled?(config) do
      {:ok, retained} = Agent.start_link(fn -> %{hd(plan.seeds)["content_sha256"] => bytes} end)

      try do
        context = %{
          parent: {:seed, hd(plan.seeds)},
          operator: "task_local",
          candidates: [],
          evaluations: [],
          artifacts: Agent.get(retained, & &1),
          ordinal: 1,
          workspace_root: Path.join(dir, "proposals"),
          sessions_dir: Path.join(dir, "sessions"),
          provider: provider,
          evolver_profile: evolver,
          timeout_ms: 480_000,
          experience: %{
            experience
            | consumer:
                Map.merge(experience.consumer, %{
                  "id" => "exposure-" <> Lemieux.ID.generate(),
                  "consumer_role" => "proposer",
                  "model" => editor_model(config),
                  "at" => DateTime.to_iso8601(DateTime.utc_now())
                })
          },
          evidence: %{
            "operator" => "task_local",
            # A bounded transcript excerpt may omit the first user entry. Keep
            # the public task request explicit; private grading stays outside
            # the proposer, retry and selection paths.
            "task_request" => task_request,
            "failed_case_ids" =>
              if(original.grade["passed"], do: [], else: plan.development_case_ids),
            "original_observation" => %{
              "answer" => original.observation["answer"],
              "grade" => original.grade,
              "transcript" =>
                Digest.excerpt(
                  original.observation["transcript"] || [],
                  max_bytes: 4096
                )
            }
          },
          retain: fn sha, data -> Agent.update(retained, &Map.put(&1, sha, data)) end
        }

        context = proposal_context(context, plan, original)

        search_scopes(proposal_scopes(config), context, plan, retained)
      after
        Agent.stop(retained)
      end
    else
      {:error, :disabled}
    end
  end

  defp search_scopes(scopes, context, plan, retained) do
    scopes
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {scope, ordinal}, {:ok, candidates} ->
      scoped =
        context
        |> Map.put(:ordinal, ordinal)
        |> Map.put(:artifacts, Agent.get(retained, & &1))
        |> Map.update!(:evidence, &Map.put(&1, "proposal_scope", scope))

      case Proposer.propose(plan, State.new(plan), scoped) do
        {:ok, candidate, _} -> {:cont, {:ok, candidates ++ [candidate]}}
        {:noop, _} -> {:cont, {:ok, candidates}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, candidates, Agent.get(retained, & &1)}
      error -> error
    end
  end

  # Operator metadata alone does not populate the first-party digest or
  # transcript directory. Excerpts are selected by Evaluation.id, not a task
  # or session id, and require matching retained source bytes.
  defp proposal_context(context, plan, original) do
    {:ok, seed, _} =
      Proposer.propose(plan, State.new(plan), %{context | operator: "seed"})

    bytes = JSON.encode!(original.observation["transcript"] || [])

    reference =
      ArtifactReference.from_bytes("transcript", bytes,
        scope: plan.scope,
        id: "original-" <> original.observation["session_id"],
        media_type: "application/json",
        content_schema: "lemieux.transcript.entries/v2"
      )

    usage = original.observation["usage"] || %{}
    known = is_integer(usage["input_tokens"]) and is_integer(usage["output_tokens"])

    {:ok, evaluation} =
      DevelopmentEvaluation.new(plan, seed, %{
        "id" => "evaluation-" <> original.observation["session_id"],
        "scope" => plan.scope,
        "case_id" => hd(plan.development_case_ids),
        "split" => "development",
        "objectives" => %{"task_success" => original.grade["score"]},
        "safety" => %{
          "passed" => original.grade["safety_failures"] == [],
          "failures" => original.grade["safety_failures"]
        },
        "completeness" => %{
          "usage" => if(known, do: "complete", else: "unknown"),
          "cost" => "not_applicable",
          "sandbox" => "complete"
        },
        "usage" => usage,
        "cost" => %{"usd" => nil},
        "latency" => %{},
        "artifacts" => [ArtifactReference.to_map(reference)],
        "within_budget" => is_nil(original.observation["provider_error"]),
        "terminal" => original.observation["status"] in ~w(completed failed),
        "observations" =>
          Map.take(original.observation, ~w(status finish_reason provider_error))
          |> Map.put("independent_grade", original.grade)
      })

    context.retain.(reference.sha256, bytes)
    artifacts = Map.put(context.artifacts, reference.sha256, bytes)

    context
    |> Map.put(:artifacts, artifacts)
    |> Map.put(:candidates, [seed])
    |> Map.put(:evaluations, [evaluation])
    |> Map.put(:digest, Digest.build(plan, [evaluation], artifacts, DevelopmentPolicy.read(plan)))
    |> Map.update!(:evidence, &Map.put(&1, "evaluation_ids", [evaluation.id]))
  end

  defp promote(config, fixture, lease, controller, details) do
    %{
      baseline: baseline,
      prepared: prepared,
      original: original,
      binding: binding,
      receipt: receipt
    } = details

    authority = authority(config, prepared.harness, binding, lease.bindings, receipt, fixture.id)
    {:ok, server} = Memory.start_link(base: prepared.harness, scope: config.scope)

    try do
      host = {Memory, server}

      {:ok, harness, activation} =
        Promotion.promote(
          host,
          "qualified",
          %{mode: :task_local, baseline: baseline, refinement: receipt},
          authority
        )

      {:ok, ^harness, _} = Promotion.current(host, authority)
      final = attempt(config, fixture, lease, controller, "promoted", harness)
      {:ok, restored, undo} = Promotion.undo(host, authority)
      true = restored == prepared.harness

      # An empty promoted result can tie useful partial work at zero after a
      # provider failure. A tie establishes no improvement over the original.
      selected =
        if final.grade["score"] > original.grade["score"] and
             final.grade["safety_failures"] == [], do: final, else: original

      %{
        selected: selected,
        refinement: receipt,
        promotion: %{
          "activation" => activation,
          "undo" => undo,
          "final_grade" => final.grade,
          "final_observation" => final.observation
        }
      }
    after
      GenServer.stop(server)
    end
  end

  defp authority(config, base, binding, bindings, receipt, task_id) do
    issued = DateTime.utc_now()

    {:ok, policy} =
      Policy.new(%{
        "id" => "qualification/v1",
        "actor" => "qualification-host",
        "scope" => config.scope,
        "capabilities" => capabilities(config),
        "trust" => "personal",
        "maximum_bytes" => 16_384,
        "ttl_ms" => 600_000,
        "expires_at" => DateTime.to_iso8601(DateTime.add(issued, 3600)),
        "canary" => %{"percent" => 100, "salt" => "qualification", "minimum_observations" => 2}
      })

    fn ->
      now = DateTime.utc_now()

      if enabled?(config),
        do:
          {:ok,
           %{
             policy: policy,
             scope: config.scope,
             base: base,
             now: now,
             task_id: task_id,
             runtime_sha256:
               if(receipt,
                 do: receipt["source_runtime"]["sha256"],
                 else: Contract.sha256("capture-only")
               ),
             bindings: bindings,
             refinements: if(receipt, do: [receipt["sha256"]], else: []),
             confirmations: [],
             lesson_context: binding,
             description_tools: ~w(read write edit bash)
           }},
        else: {:error, :disabled}
    end
  end

  defp signal(%{captures: [capture | _]}), do: capture["kind"]
  defp signal(%{grade: %{"passed" => false}}), do: "verification_failure"
  defp signal(_original), do: "no_signal"
  defp editor_model(config), do: config[:editor_model] || config.model
  defp editor_effort(config), do: config[:editor_effort] || config.effort
  defp proposal_scopes(config), do: config[:proposal_scopes] || ["task_local"]

  defp capabilities(%{support_policy: %{"id" => "experimental_mean/v1"}}),
    do: ["retain", "task_local", "experimental_task_local"]

  defp capabilities(_config), do: ["retain", "task_local"]
  defp observation({:ok, observation}), do: observation
  defp observation({:error, _, observation}), do: observation

  defp observation(_error),
    do: %{"status" => "failed", "error" => "runtime_unavailable", "answer" => ""}

  defp outputs(environment, cwd) do
    with {:ok, %{type: :regular, size: size}} when size <= 1_048_576 <-
           File.lstat(Path.join(cwd, "solution.py")),
         {:ok, bytes} <- Environment.read_file(environment, cwd, "solution.py") do
      %{"solution.py" => %{"sha256" => Contract.sha256(bytes), "base64" => Base.encode64(bytes)}}
    else
      _unavailable -> %{"state" => "unavailable_or_oversized"}
    end
  end

  defp grade(config, fixture, cwd) do
    workspace = retain_workspace(config, fixture, cwd, %{})

    grade =
      fixture_grade(
        config,
        Map.put(fixture, :cases, Map.get(fixture, :probe_cases, fixture.cases)),
        cwd
      )

    grade = Map.merge(grade, workspace)
    Agent.update(config.grades, &[grade | &1])
    grade
  end

  defp retain_workspace(%{capture_workspace: true} = config, fixture, cwd, grade) do
    evidence = WorkspaceEvidence.capture(fixture.task.cwd, cwd)
    path = Path.join([config.root, "workspaces", Contract.sha256(cwd) <> ".json"])
    :ok = File.mkdir_p(Path.dirname(path))
    :ok = Installation.write(path, evidence)

    Map.merge(grade, %{
      "workspace_evidence_sha256" => evidence["sha256"],
      "workspace_evidence_complete" => evidence["complete"]
    })
  end

  defp retain_workspace(_config, _fixture, _cwd, grade), do: grade

  defp workspace_complete?(evidence),
    do:
      Enum.all?(evidence["all_attempt_grades"], &Map.get(&1, "workspace_evidence_complete", true))

  defp confirmation_grade(config, %{probe_cases: _} = fixture, cwd),
    do: fixture_grade(config, fixture, cwd)

  defp confirmation_grade(_config, _fixture, _cwd), do: nil

  defp task_requests(config), do: config[:task_requests] || 16

  defp episode_name(config, context) do
    name = "#{context["repetition"]}-#{context["task"]["id"]}-#{context["arm"]}"
    if config[:opaque_paths], do: Contract.sha256(name), else: name
  end

  defp lease_name(config, name),
    do: if(config[:opaque_paths], do: Contract.sha256(name), else: name)

  defp initial_lessons(%{seed_libraries: libraries}, context),
    do: Map.get(libraries, context["stream_id"], [])

  defp initial_lessons(config, _context), do: config[:initial_lessons] || []
  defp acquisition_timeout(config), do: config[:acquisition_timeout_ms] || 5000
  defp refinement_requests(config), do: config[:refinement_requests] || 112
  defp refinement_tokens(config), do: config[:refinement_tokens] || 1_500_000
  defp candidate_count(%{refinement: nil}), do: 0
  defp candidate_count(%{refinement: receipt}), do: length(receipt["candidates"] || [])
  defp promotion_count(%{promotion: nil}), do: 0
  defp promotion_count(_result), do: 1

  defp fixture_grade(config, fixture, cwd),
    do: Map.get(config, :fixture_module, Fixtures).grade(fixture, cwd, config.environment)

  @spec token_bound(term()) :: pos_integer()
  def token_bound(_request), do: 131_072

  defp bindings(config, fixture, prepared) do
    %{
      "source_sha256" => fixture.source_sha256,
      "harness_sha256" => prepared.qualification["control"]["sha256"],
      "environment_sha256" => Contract.sha256(:erlang.term_to_binary(config.environment)),
      "descriptors_sha256" =>
        Contract.digest(%{"catalog" => prepared.qualification["control"]["catalog"]}),
      "policy_sha256" => Contract.sha256("qualification-explicit-opt-in/v1"),
      "verification_sha256" =>
        Contract.digest(%{"cases" => Enum.map(fixture.cases, fn {a, b} -> [a, b] end)}),
      "model_sha256" => Contract.sha256(config.model <> config.effort)
    }
  end

  @spec baseline(model :: String.t(), effort :: String.t(), requests :: pos_integer()) :: map()
  def baseline(model, effort, requests \\ 16),
    do:
      Profile.quota(
        %{
          "execution" => "live",
          "model" => model,
          "tools" => ~w(read write edit bash),
          "options" => %{
            "system" => "Portable baseline",
            "max_turns" => requests,
            "max_tokens" => 8192,
            "temperature" => 0.3,
            "max_cost_usd" => nil,
            "reasoning_effort" => effort,
            "tool_descriptions" => %{}
          }
        },
        requests
      )

  defp seal(map), do: Map.put(map, "sha256", Contract.digest(map))
end
