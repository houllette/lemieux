# Explicitly authorized, staged qualification. Never loaded by ordinary lmx.
alias Lemieux.CLI.Learning.CodexAuth
alias Lemieux.CLI.Learning.Container
alias Lemieux.CLI.Learning.Installation
alias Lemieux.CLI.Learning.Projects
alias Lemieux.CLI.Learning.QualificationHost, as: Host
alias Lemieux.CLI.Learning.Recording
alias Lemieux.Contract
alias Lemieux.Learning.Qualification
alias Lemieux.Providers.ReqLLM
alias Lemieux.Providers.Scripted

{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      allow_live: :boolean,
      output: :string,
      model: :string,
      effort: :string,
      stage: :string,
      task_requests: :integer,
      repetitions: :integer
    ]
  )

live = opts[:allow_live] == true
stage = opts[:stage] || "calibration"
true = stage in ~w(calibration development)
requests = opts[:task_requests] || 12
repetitions = opts[:repetitions] || 2
true = requests in 8..24 and repetitions in 2..10
model = opts[:model] || if(live, do: "openai_codex:gpt-6-luna", else: "test:model")
effort = opts[:effort] || if(live, do: "low", else: "default")

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

fixtures =
  Projects.materialize(
    Path.join(root, "sources"),
    "development",
    if(stage == "calibration", do: 1, else: 2)
  )

allowance = %{"requests" => 160, "tokens" => 3_000_000, "time_ms" => 2_000_000, "cost_usd" => nil}

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
  "image" => elem(environment, 1).image,
  "corpus" => "eight_repository_workflow_development_families/v1",
  "corpus_status" => "synthetic_developer_visible_not_independent_confirmation",
  "generation" => %{
    "reasoning_effort" => effort,
    "max_tokens" => 8192,
    "task_requests" => requests
  },
  "transport_max_retries" => 0,
  "inference_route" => if(live, do: "codex_subscription", else: "scripted"),
  "cost_kind" => "subscription_quota_not_api_billing",
  "feedback" => "public_cases_only_no_private_grade_in_proposal_or_selection",
  "acquisition_timeout_ms" => 30_000,
  "probe_selection" => "visible_verification_failed",
  "retry" => %{
    "maximum_attempts" => div(allowance["requests"], requests),
    "stopping" => "first_public_verification_success"
  },
  "library" => "empty_initial_isolated_by_stream_arm_and_repetition",
  "refinement" => %{
    "repetitions" => 2,
    "maximum_candidates" => 1,
    "surface" => ["system_suffix", "tool_descriptions"]
  }
}

runtime = Map.put(runtime, "sha256", Contract.digest(runtime))

config = %{
  root: root,
  enabled: true,
  model: model,
  effort: effort,
  environment: environment,
  isolated: true,
  scope: scope,
  supervisor: Lemieux.StudySupervisor,
  fixtures: Map.new(fixtures, &{&1.id, &1}),
  initial_lessons: [],
  allow_live: live,
  fixture_module: Projects,
  task_requests: requests,
  acquisition_timeout_ms: 30_000,
  retry_attempts: div(allowance["requests"], requests),
  probe_when: :verification_failed
}

plan =
  if stage == "development" do
    {:ok, plan} =
      Qualification.plan(%{
        "id" => Path.basename(root),
        "model" => model,
        "effort" => effort,
        "runtime" => runtime,
        "seed_case_ids" => [],
        "initial_library_sha256" => Contract.digest(%{"lessons" => []}),
        "repetitions" => repetitions,
        "allowance" => allowance,
        "alpha" => 0.05,
        "claim" => "development_qualification",
        "analysis" => analysis,
        "tasks" =>
          Enum.map(fixtures, fn fixture ->
            %{
              "id" => fixture.id,
              "cluster" => fixture.cluster,
              "source_sha256" => fixture.source_sha256,
              "phase" =>
                if(String.ends_with?(fixture.id, "-1"), do: "learning", else: "confirmation")
            }
          end)
      })

    plan
  else
    seal = %{
      "schema_version" => 1,
      "kind" => "mechanism_and_difficulty_calibration",
      "model" => model,
      "effort" => effort,
      "runtime" => runtime,
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

# Freeze the entire plan before resolving credentials or making any request.
:ok = Installation.write(Path.join(root, "plan.json"), plan)

auth =
  if live do
    {:ok, path, _summary} =
      CodexAuth.prepare(path: Path.join(root, ".auth/oauth.json"), min_validity_hours: 2)

    path
  end

System.at_exit(fn _ -> if auth, do: CodexAuth.cleanup(auth) end)

try do
  execute = fn context ->
    IO.puts("episode #{context["repetition"]}/#{context["task"]["id"]}/#{context["arm"]}")
    {:ok, meter} = Agent.start_link(fn -> %{} end)

    provider = fn _role ->
      if live,
        do: Recording.new(meter, ReqLLM.new(receive_timeout: :infinity, max_retries: 0)),
        else:
          Scripted.new([
            Scripted.complete("offline mechanics",
              usage: %{"input_tokens" => 2, "output_tokens" => 2}
            )
          ])
    end

    current = Map.put(config, :provider, provider)
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

  report =
    if stage == "development" do
      {:ok, report} = Qualification.run(plan, execute, observer: observer)
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
          {:ok, row} = execute.(context)
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

  report =
    report
    |> Map.put("runtime", runtime)
    |> Map.delete("sha256")
    |> then(&Map.put(&1, "sha256", Contract.digest(&1)))

  :ok = Installation.write(Path.join(root, "report.json"), report)

  IO.puts(
    JSON.encode!(
      Map.take(report, ~w(kind mechanics benefit baseline_success has_headroom analysis arms))
    )
  )
after
  if auth, do: CodexAuth.cleanup(auth)
end
