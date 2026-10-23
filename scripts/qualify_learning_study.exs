# Explicitly authorized, staged qualification. Never loaded by ordinary lmx.
alias Lemieux.CLI.Learning.AssetSearch
alias Lemieux.CLI.Learning.CodexAuth
alias Lemieux.CLI.Learning.Container
alias Lemieux.CLI.Learning.Installation
alias Lemieux.CLI.Learning.Mechanism
alias Lemieux.CLI.Learning.Projects
alias Lemieux.CLI.Learning.QualificationHost, as: Host
alias Lemieux.CLI.Learning.Recording
alias Lemieux.CLI.Learning.Repositories
alias Lemieux.CLI.Learning.Reflection
alias Lemieux.CLI.Learning.StudyBudget
alias Lemieux.CLI.Learning.StudyAllowance
alias Lemieux.Contract
alias Lemieux.Learning.Experience.Lessons
alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
alias Lemieux.Learning.Qualification
alias Lemieux.Learning.Qualification.Endpoints
alias Lemieux.Providers.ReqLLM
alias Lemieux.Providers.Scripted

Code.require_file(Application.app_dir(:lemieux, "priv/qualification/reference.exs"))

{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      allow_live: :boolean,
      output: :string,
      model: :string,
      effort: :string,
      stage: :string,
      task_requests: :integer,
      repetitions: :integer,
      manifest: :string,
      offline_smoke: :boolean,
      research: :boolean,
      editor_model: :string,
      editor_effort: :string,
      streams: :string,
      assets: :boolean,
      asset_only: :boolean,
      mechanism: :string,
      allowance_dir: :string,
      max_total_requests: :integer,
      max_total_tokens: :integer,
      max_total_time_ms: :integer
    ]
  )

live = opts[:allow_live] == true

study_limits = [
  max_requests: opts[:max_total_requests],
  max_tokens: opts[:max_total_tokens],
  max_time_ms: opts[:max_total_time_ms]
]

if (live or is_binary(opts[:allowance_dir])) and
     not (is_binary(opts[:allowance_dir]) and
            Enum.all?(study_limits, fn {_key, value} -> is_integer(value) and value > 0 end)),
   do:
     raise(
       "Hosted stages require --allowance-dir and positive --max-total-requests, --max-total-tokens and --max-total-time-ms from the authorized study allowance"
     )

if live and opts[:offline_smoke],
  do: raise("The offline smoke subset cannot select a hosted provider")

stage = opts[:stage] || "calibration"
true = stage in ~w(calibration mechanism development confirmation)
research = opts[:research] == true
assets = opts[:assets] == true
if assets and not research, do: raise("Asset experiments require --research")
if opts[:asset_only] == true and not assets, do: raise("--asset-only requires --assets")
if stage == "mechanism" and not research, do: raise("Mechanism stage requires --research")

if stage == "confirmation" and is_nil(opts[:manifest]),
  do:
    raise("Independent confirmation requires a separately curated, unexposed repository manifest")

requests = opts[:task_requests] || 12
repetitions = opts[:repetitions] || 2
true = requests in 8..if(research, do: 200, else: 24) and repetitions in 2..10
model = opts[:model] || if(live, do: "openai_codex:gpt-6-luna", else: "test:model")
effort = opts[:effort] || if(live, do: "low", else: "default")

editor_model =
  opts[:editor_model] || if(live and research, do: "openai_codex:gpt-6-sol", else: model)

editor_effort = opts[:editor_effort] || if(live and research, do: "high", else: effort)

if not research and (opts[:editor_model] || opts[:editor_effort]),
  do: raise("Separate editor requires --research")

true =
  if live,
    do:
      String.starts_with?(editor_model, "openai_codex:") and
        editor_effort in ~w(low medium high xhigh max),
    else: editor_model == "test:model" and editor_effort == "default"

true =
  if live,
    do: String.starts_with?(model, "openai_codex:") and effort in ~w(low medium high xhigh max),
    else: model == "test:model" and effort == "default"

{revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
{status, 0} = System.cmd("git", ["status", "--porcelain"])
if live and status != "", do: raise("Commit qualification code before live execution")
root = Path.expand(opts[:output] || "tmp/learning-study-#{Lemieux.ID.generate()}")
:ok = File.mkdir_p(Path.dirname(root))
:ok = File.mkdir(root)
:ok = File.chmod(root, 0o700)
Logger.configure(level: :warning)

{:ok, environment} =
  Container.new("python@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059")

{:ok, _} = Lemieux.Supervisor.start_link(name: Lemieux.StudySupervisor)
scope = %{"id" => "qualification-study/" <> Contract.sha256(root)}

{fixtures, corpus, fixture_module} =
  if opts[:manifest] do
    {fixtures, metadata} = Repositories.materialize(opts[:manifest], Path.join(root, "sources"))

    if stage == "confirmation" and metadata["exposure"] != "unexposed",
      do: raise("Exposed repositories are development material")

    {fixtures, metadata, Repositories}
  else
    fixtures =
      Projects.materialize(
        Path.join(root, "sources"),
        "development",
        if(stage == "calibration", do: 1, else: 2)
      )

    {fixtures,
     %{
       "id" => "eight_repository_workflow_development_families/v2",
       "exposure" => "developer_exposed",
       "kind" => "synthetic_diagnostics"
     }, Projects}
  end

{seeds, fixtures} =
  if opts[:manifest] do
    Enum.split_with(fixtures, &(&1.phase == "seed"))
  else
    seeds =
      if stage == "calibration",
        do: [],
        else: Projects.materialize(Path.join(root, "seed-sources"), "seed", 1)

    {seeds, fixtures}
  end

fixtures = if opts[:offline_smoke], do: Enum.take(fixtures, 2), else: fixtures

selected_streams =
  if opts[:streams],
    do: String.split(opts[:streams], ","),
    else: if(stage == "mechanism", do: ["graph"])

fixtures =
  if selected_streams,
    do: Enum.filter(fixtures, &(&1.cluster in selected_streams)),
    else: fixtures

fixtures =
  if stage == "mechanism",
    do: Enum.reject(fixtures, &String.ends_with?(&1.id, "-1")),
    else: fixtures

true = fixtures != []
streams = Enum.map(fixtures, & &1.cluster) |> Enum.uniq()
seeds = Enum.filter(seeds, &(&1.cluster in streams))
seed_ids = Enum.map(seeds, & &1.id)

research_budget =
  if research, do: StudyBudget.research(requests, opts[:asset_only] != true, assets)

allowance =
  if research,
    do: research_budget.allowance,
    else: %{
      "requests" =>
        cond do
          assets -> 320
          research -> max(192, 8 * requests + 48)
          true -> max(160, 8 * requests + 16)
        end,
      "tokens" =>
        cond do
          assets -> 12_000_000
          research -> 6_000_000
          true -> 3_000_000
        end,
      "time_ms" => if(assets, do: 4_000_000, else: 2_000_000),
      "cost_usd" => nil
    }

analysis = %{
  "method" => "exact_paired_stream_success",
  "minimum_effect" => 0.1,
  "maximum_regression_rate" => 0.1,
  "desired_power" => 0.8,
  "win_probability" => 0.25,
  "loss_probability" => 0.05,
  "maximum_request_ratio" => 8,
  "maximum_latency_ratio" => 10
}

runtime = %{
  "revision" => String.trim(revision),
  "source_tree_clean" => status == "",
  "environment" => "networkless_nonroot_container",
  "image" => if(opts[:manifest], do: "per_task_environments", else: elem(environment, 1).image),
  "corpus" => corpus,
  "environments" =>
    Enum.map(fixtures, fn fixture ->
      elem(Map.get(fixture, :environment, environment), 1).image
    end)
    |> Enum.uniq()
    |> Enum.sort(),
  "generation" => %{
    "reasoning_effort" => effort,
    "max_tokens" => 8192,
    "task_requests" => requests
  },
  "transport_max_retries" => 0,
  "study_allowance" =>
    if(live,
      do: %{
        "id" => Contract.sha256(Path.expand(opts[:allowance_dir])),
        "limits" => Map.new(study_limits),
        "policy" => "durable_shared_across_stages_no_replay_on_unknown_usage"
      }
    ),
  "inference_route" => if(live, do: "codex_subscription", else: "scripted"),
  "cost_kind" => "subscription_quota_not_api_billing",
  "cost_estimate_policy" => "subscription_dollars_informational_no_usd_admission_estimate",
  "feedback" => "public_cases_only_no_private_grade_in_proposal_or_selection",
  "acquisition_timeout_ms" => 30_000,
  "episode_paths" => "opaque_arm_and_attempt_identifiers",
  "workspace_evidence" => "bounded_actual_changed_file_bytes_before_lease_release",
  "offline_smoke" => opts[:offline_smoke] == true,
  "probe_selection" =>
    if(research, do: "all_completed_task_records", else: "visible_verification_failed"),
  "probe_terminal_rule" => "verified_accounted_max_turns_is_scored_failure",
  "proposal_task_request" => "explicit_public_prompt_without_private_grading",
  "search_directory_policy" => "owned_workspace_root_and_in_environment_directory_change",
  "imported_task_contract" => "frozen_public_verification_paths_disclosed_to_all_arms",
  "retry" => %{
    "maximum_attempts" => div(allowance["requests"], requests),
    "stopping" => "first_public_verification_success"
  },
  "library" => "fixed_common_seed_inventory_per_stream_isolated_by_arm_and_repetition",
  "retrieval_updates" => "causal_observations_without_refinement",
  "refinement" => %{
    "repetitions" => 2,
    "maximum_candidates" => 1,
    "reserved_requests" => 6 * requests + 16,
    "surface" => ["system_suffix", "tool_descriptions"]
  }
}

runtime =
  if research do
    Map.merge(runtime, %{
      "research_protocol" => %{
        "id" => "whole_record_research/v3",
        "terminal_rule" => "verified_artifact_outcome_same_as_ordinary_arms",
        "stage" => stage,
        "reflection" => "whole_public_record_including_rejected_and_uncertain_experiments",
        "reflection_source_bytes" => Reflection.source_limit(),
        "editor_model" => editor_model,
        "editor_effort" => editor_effort,
        "support_policy" => %{
          "id" => "experimental_mean/v2",
          "verified_ties" => true,
          "minimum_gain" => 0.1,
          "minimum_repetitions" => 2
        },
        "proposal_scopes" => ["general", "domain"],
        "composition" => "append_only_system_union_then_fresh_execution",
        "activation" => "experimental_task_local_permission_no_persistent_canary",
        "final_selection" =>
          "candidate_on_completed_accounted_verified_tie_otherwise_public_gain",
        "efficacy" =>
          "separate_quality_and_efficiency_endpoints_no_changed_historical_thresholds",
        "endpoints" => Endpoints.policy(),
        "asset_search" => if(assets, do: AssetSearch.protocol()),
        "profile_search" => opts[:asset_only] != true
      },
      "probe_terminal_rule" => "verified_accounted_artifact_grade",
      "refinement" => %{
        "repetitions" => 2,
        "maximum_candidates" => 2,
        "reserved_requests" => research_budget.profile_requests,
        "reserved_tokens" => research_budget.experiment_tokens,
        "reserved_time_ms" => research_budget.profile_time_ms,
        "asset_reserved_requests" => research_budget.asset_requests,
        "asset_reserved_time_ms" => research_budget.asset_time_ms,
        "surface" => ["system_suffix", "tool_descriptions"]
      }
    })
  else
    runtime
  end

runtime = Map.put(runtime, "sha256", Contract.digest(runtime))

if live and research and stage in ~w(development confirmation) do
  if is_nil(opts[:mechanism]),
    do: raise("A matching hosted --mechanism receipt is required before a larger research study")

  receipt = opts[:mechanism] |> File.read!() |> JSON.decode!()
  :ok = Mechanism.gate(receipt, runtime, model, effort)
end

config = %{
  root: root,
  enabled: true,
  model: model,
  effort: effort,
  environment: environment,
  isolated: true,
  scope: scope,
  supervisor: Lemieux.StudySupervisor,
  fixtures: Map.new(seeds ++ fixtures, &{&1.id, &1}),
  initial_lessons: [],
  allow_live: live,
  fixture_module: fixture_module,
  task_requests: requests,
  acquisition_timeout_ms: 30_000,
  retry_attempts: div(allowance["requests"], requests),
  refinement_requests: 6 * requests + 16,
  probe_when: :verification_failed,
  opaque_paths: true,
  capture_workspace: true
}

config =
  if research,
    do:
      Map.merge(config, %{
        reflection: true,
        editor_model: editor_model,
        editor_effort: editor_effort,
        proposal_scopes: ["general", "domain"],
        refinement_tokens: research_budget.experiment_tokens,
        refinement_time_ms: research_budget.profile_time_ms,
        asset_tokens: research_budget.experiment_tokens,
        asset_time_ms: research_budget.asset_time_ms,
        asset_requests: research_budget.asset_requests,
        task_time_ms: research_budget.task_time_ms,
        probe_when: :all_observations,
        terminal_rule: :artifact_outcome,
        asset_search: assets,
        profile_search: opts[:asset_only] != true,
        support_policy: runtime["research_protocol"]["support_policy"],
        refinement_requests: research_budget.profile_requests
      }),
    else: config

build_plan = fn library_sha, current_runtime ->
  if stage != "calibration" do
    attrs = %{
      "id" => Path.basename(root),
      "model" => model,
      "effort" => effort,
      "runtime" => current_runtime,
      "seed_case_ids" => seed_ids,
      "initial_library_sha256" => library_sha,
      "repetitions" => repetitions,
      "allowance" => allowance,
      "alpha" => 0.05,
      "claim" =>
        if(stage == "confirmation",
          do: "independent_confirmation",
          else: "development_qualification"
        ),
      "analysis" => analysis,
      "tasks" =>
        Enum.map(fixtures, fn fixture ->
          %{
            "id" => fixture.id,
            "cluster" => fixture.cluster,
            "source_sha256" => fixture.source_sha256,
            "phase" =>
              Map.get_lazy(fixture, :phase, fn ->
                if(String.ends_with?(fixture.id, "-1"), do: "learning", else: "confirmation")
              end)
          }
        end)
    }

    attrs =
      if research, do: Map.put(attrs, "ablation", "withheld_proposer_experience/v1"), else: attrs

    {:ok, plan} = Qualification.plan(attrs)

    if research, do: :ok = Endpoints.preflight(plan)
    plan
  else
    seal = %{
      "schema_version" => 1,
      "kind" => "mechanism_and_difficulty_calibration",
      "model" => model,
      "effort" => effort,
      "runtime" => current_runtime,
      "tasks" =>
        Enum.map(
          fixtures,
          &%{"id" => &1.id, "source_sha256" => &1.source_sha256, "cluster" => &1.cluster}
        ),
      "arms" => ["disabled", "reference"],
      "repetitions" => 1,
      "allowance" => allowance,
      "analysis" => analysis,
      "reference" => "developer_authored_workflow_guidance_no_solution_or_private_cases",
      "headroom" => %{"minimum_baseline_success" => 0.1, "maximum_baseline_success" => 0.9},
      "stopping" => "complete_fixed_sample_no_retries_of_incomplete_intents"
    }

    Map.put(seal, "sha256", Contract.digest(seal))
  end
end

# Freeze selection, ordering, budgets, hypotheses and the complete seed recipe
# before any paid work. Only actual immutable seed bytes are filled in later.
template = build_plan.(Contract.digest(%{"lessons" => []}), runtime)

:ok =
  Installation.write(Path.join(root, "registration.json"), %{
    "template" => template,
    "seed_recipe" => "one_fixed_ordinary_capture_per_stream_no_search_or_selection",
    "seed_tasks" =>
      Enum.map(
        seeds,
        &%{"id" => &1.id, "cluster" => &1.cluster, "source_sha256" => &1.source_sha256}
      ),
    "seed_allowance" => allowance,
    "stopping" => "complete_fixed_seed_prefix_then_complete_target_sample"
  })

study_allowance =
  if opts[:allowance_dir] do
    {:ok, handle} = StudyAllowance.open(opts[:allowance_dir], study_limits)
    handle
  end

auth = if live, do: Path.join(root, ".auth/oauth.json")
System.at_exit(fn _ -> if auth, do: CodexAuth.cleanup(auth) end)

try do
  if live do
    {:ok, ^auth, _summary} = CodexAuth.prepare(path: auth, min_validity_hours: 2)
  end

  execute = fn context, config ->
    IO.puts("episode #{context["repetition"]}/#{context["task"]["id"]}/#{context["arm"]}")
    {:ok, meter} = Agent.start_link(fn -> %{} end)
    fixture = Map.fetch!(config.fixtures, context["task"]["id"])

    provider = fn role ->
      raw =
        cond do
          live ->
            Recording.new(meter, ReqLLM.new(receive_timeout: :infinity, max_retries: 0),
              role: role,
              cost_mode: :quota
            )

          research ->
            LemieuxQualificationReference.provider(role, fixture, model, effort, requests)

          fixture[:offline_oracle] ->
            # Reference implementations remain host-only. This branch is
            # unreachable for a hosted provider and makes no efficacy claim.
            usage = %{"input_tokens" => 2, "output_tokens" => 2}

            Scripted.new([
              Scripted.tool_call("reproduce", "bash", %{"command" => "python checks.py"},
                usage: usage
              ),
              Scripted.tool_call("read-source", "read", %{"path" => "src/project/core.py"},
                usage: usage
              ),
              Scripted.tool_call("read-built", "read", %{"path" => ".build/project/core.py"},
                usage: usage
              ),
              Scripted.tool_call(
                "source",
                "write",
                %{"path" => "src/project/core.py", "content" => fixture.offline_oracle},
                usage: usage
              ),
              Scripted.tool_call(
                "built",
                "write",
                %{"path" => ".build/project/core.py", "content" => fixture.offline_oracle},
                usage: usage
              ),
              Scripted.tool_call("verify", "bash", %{"command" => "python checks.py"},
                usage: usage
              ),
              Scripted.complete("offline reference repair", usage: usage)
            ])

          true ->
            Scripted.new([
              Scripted.complete("offline mechanics",
                usage: %{"input_tokens" => 2, "output_tokens" => 2}
              )
            ])
        end

      if study_allowance,
        do: StudyAllowance.provider(study_allowance, role, raw),
        else: raw
    end

    current =
      config
      |> Map.put(:provider, provider)
      |> Map.put(:environment, Map.get(fixture, :environment, environment))

    current = if live, do: Map.put(current, :meter, meter), else: current

    current =
      if context["arm"] == "reference" do
        fixture = Map.fetch!(current.fixtures, context["task"]["id"])

        put_in(
          current.fixtures[fixture.id].task.prompt,
          fixture.task.prompt <> "\nReference workflow guidance:\n" <> fixture.reference_guidance
        )
      else
        current
      end

    try do
      Host.episode(current, context)
    after
      Agent.stop(meter)
    end
  end

  observer = fn event, payload ->
    task_id = payload["task_id"] || get_in(payload, ["task", "id"])

    name =
      if event == "report",
        do: "report",
        else: "#{payload["repetition"]}-#{task_id}-#{payload["arm"]}-#{event}"

    Installation.write(Path.join(root, name <> ".json"), payload)
  end

  warmup =
    Enum.map(seeds, fn fixture ->
      context = %{
        "arm" => "retrieval",
        "repetition" => 1,
        "task" => %{"id" => fixture.id, "source_sha256" => fixture.source_sha256},
        "allowance" => allowance,
        "prior_lesson_ids" => [],
        "available_case_ids" => [],
        "stream_id" => fixture.cluster
      }

      :ok = observer.("intent", context)
      {:ok, row} = execute.(context, config)
      :ok = Installation.write(Path.join(root, fixture.id <> "-seed-completed.json"), row)
      true = is_integer(row["tokens"]) and row["qualification_complete"]
      row
    end)

  libraries =
    Map.new(seeds, fn fixture ->
      path = Path.join(root, "library-retrieval-1-" <> Contract.sha256(fixture.cluster))
      store = LessonFiles.new(path, scope)
      {:ok, ids} = Lessons.inventory(store)

      lessons =
        Enum.map(ids, fn id ->
          {:ok, lesson} = Lessons.read(store, id)
          lesson
        end)

      {fixture.cluster, lessons}
    end)

  {inventory_status, inventory} =
    Lemieux.CLI.Learning.SeedInventory.check(libraries, Enum.map(seeds, & &1.cluster))

  :ok = Installation.write(Path.join(root, "seed-inventory.json"), inventory)

  if inventory_status == :error do
    raise "Seed inventory incomplete; no target episodes dispatched. Review seed-inventory.json; do not replay the frozen intent."
  end

  library_sha =
    Contract.digest(
      Map.new(libraries, fn {stream, lessons} ->
        {stream, Enum.map(lessons, & &1.sha256) |> Enum.sort()}
      end)
    )

  config = Map.put(config, :seed_libraries, libraries)

  seed_usage = %{
    "requests" => Enum.sum(Enum.map(warmup, & &1["requests"])),
    "tokens" => Enum.sum(Enum.map(warmup, & &1["tokens"])),
    "episodes" => length(warmup),
    "requests_by_stream" =>
      Map.new(streams, fn stream ->
        {stream,
         warmup
         |> Enum.filter(&(config.fixtures[&1["task_id"]].cluster == stream))
         |> Enum.map(& &1["requests"])
         |> Enum.sum()}
      end)
  }

  runtime =
    runtime
    |> Map.put("seed_usage", seed_usage)
    |> Map.delete("sha256")
    |> then(&Map.put(&1, "sha256", Contract.digest(&1)))

  plan = build_plan.(library_sha, runtime)
  :ok = Installation.write(Path.join(root, "plan.json"), plan)

  report =
    if stage != "calibration" do
      {:ok, report} = Qualification.run(plan, &execute.(&1, config), observer: observer)
      report
    else
      rows =
        for fixture <- fixtures, arm <- ~w(disabled reference) do
          context = %{
            "arm" => arm,
            "repetition" => 1,
            "task" => %{"id" => fixture.id, "source_sha256" => fixture.source_sha256},
            "allowance" => allowance,
            "prior_lesson_ids" => [],
            "available_case_ids" => [],
            "stream_id" => fixture.cluster
          }

          :ok = observer.("intent", context)
          {:ok, row} = execute.(context, config)
          :ok = Installation.write(Path.join(root, "#{fixture.id}-#{arm}-completed.json"), row)
          row
        end

      baseline = Enum.filter(rows, &(&1["arm"] == "disabled"))
      rate = Enum.count(baseline, & &1["passed"]) / length(baseline)

      %{
        "kind" => "development_calibration_only",
        "plan_sha256" => plan["sha256"],
        "rows" => rows,
        "baseline_success" => rate,
        "has_headroom" => rate >= 0.1 and rate <= 0.9,
        "benefit" => "not_tested",
        "independent_confirmation" => false
      }
    end

  if not live and fixture_module == Projects do
    true = Enum.all?(warmup ++ report["rows"], & &1["passed"])
  end

  report =
    if research and stage != "calibration" do
      {:ok, endpoints} = Endpoints.report(plan, report["rows"])

      stops =
        Map.new(Enum.group_by(report["rows"], & &1["arm"]), fn {arm, rows} ->
          {arm,
           %{
             "original" => Enum.count(rows, & &1["original_budget_stop"]),
             "selected" => Enum.count(rows, & &1["selected_budget_stop"]),
             "probes" => Enum.sum(Enum.map(rows, & &1["probe_budget_stops"]))
           }}
        end)

      report
      |> Map.put("research_endpoints", endpoints)
      |> Map.put("budget_stops", %{
        "by_arm" => stops,
        "interpretation" =>
          "Original and selected are overlapping views. Verified artifact success does not imply agent completion; probe counts cover task executions, not editor sessions."
      })
    else
      report
    end

  report =
    report
    |> Map.put("runtime", runtime)
    |> Map.put("warmup_rows", warmup)
    |> Map.put("initial_library_sha256", library_sha)
    |> Map.put(
      "workspace_artifacts",
      Enum.map(Path.wildcard(Path.join([root, "workspaces", "*.json"])), fn path ->
        bytes = File.read!(path)
        content = JSON.decode!(bytes)

        %{
          "file" => Path.basename(path),
          "bytes_sha256" => Contract.sha256(bytes),
          "sha256" => content["sha256"],
          "complete" => content["complete"],
          "changed_files" => length(content["changed_paths"] || [])
        }
      end)
    )
    |> Map.put(
      "study_allowance",
      if(study_allowance, do: StudyAllowance.snapshot(study_allowance))
    )
    |> Map.delete("sha256")
    |> then(&Map.put(&1, "sha256", Contract.digest(&1)))

  :ok = Installation.write(Path.join(root, "report.json"), report)

  if stage == "mechanism" do
    {:ok, mechanism} = Mechanism.audit(root, plan, report)
    :ok = Installation.write(Path.join(root, "mechanism.json"), mechanism)
    IO.puts(JSON.encode!(Map.take(mechanism, ~w(status checks interpretation))))
  end

  if not live and stage != "calibration" do
    true = report["mechanics"] == "passed"
  end

  IO.puts(
    JSON.encode!(
      Map.take(report, ~w(kind mechanics benefit baseline_success has_headroom analysis arms))
    )
  )
after
  if auth, do: CodexAuth.cleanup(auth)
  if study_allowance, do: StudyAllowance.close(study_allowance)
end
