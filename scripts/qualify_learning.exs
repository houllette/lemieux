# Explicit qualification host, never loaded by ordinary lmx. See
# docs/learning-qualification.md for claims, allowances and recovery boundaries.
alias Lemieux.CLI.Learning.CodexAuth
alias Lemieux.CLI.Learning.Container
alias Lemieux.CLI.Learning.Fixtures
alias Lemieux.CLI.Learning.Installation
alias Lemieux.CLI.Learning.QualificationHost, as: Host
alias Lemieux.CLI.Learning.Recording
alias Lemieux.Contract
alias Lemieux.Learning.Experience.Lessons
alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles
alias Lemieux.Learning.Qualification
alias Lemieux.Providers.ReqLLM
alias Lemieux.Providers.Scripted

{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      allow_live: :boolean,
      output: :string,
      variants: :integer,
      repetitions: :integer,
      model: :string,
      effort: :string
    ]
  )

live = opts[:allow_live] == true
{revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
{status, 0} = System.cmd("git", ["status", "--porcelain"])
if live and status != "", do: raise("Commit qualification code before live execution")
variants = opts[:variants] || 2
repetitions = opts[:repetitions] || 2
true = variants in 1..5 and repetitions in 2..10
root = Path.expand(opts[:output] || "tmp/learning-qualification-#{Lemieux.ID.generate()}")
:ok = File.mkdir_p(Path.dirname(root))
:ok = File.mkdir(root)
:ok = File.chmod(root, 0o700)
Logger.configure(level: :warning)
model = opts[:model] || if(live, do: "openai_codex:gpt-6.1-sol", else: "test:model")
effort = opts[:effort] || if(live, do: "medium", else: "default")

if live and not String.starts_with?(model, "openai_codex:"),
  do: raise("Live qualification requires the explicitly authorized Codex subscription route")

if not live and (model != "test:model" or effort != "default"),
  do: raise("Offline qualification uses only test:model with default effort")

if live and effort not in ~w(low medium high xhigh max), do: raise("Unsupported reasoning effort")

{:ok, environment} =
  Container.new("python@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059")

{:ok, _} = Lemieux.Supervisor.start_link(name: Lemieux.QualificationSupervisor)
scope = %{"id" => "qualification/" <> Contract.sha256(root)}
all = Fixtures.materialize(Path.join(root, "sources"), variants + 1)
{warmup, targets} = Enum.split(all, 2)

warmup =
  Enum.map(warmup, fn fixture ->
    id = "warmup-" <> fixture.id
    %{fixture | id: id, task: %{fixture.task | id: id}}
  end)

config = %{
  root: root,
  enabled: true,
  model: model,
  effort: effort,
  environment: environment,
  isolated: true,
  scope: scope,
  supervisor: Lemieux.QualificationSupervisor,
  fixtures: Map.new(warmup ++ targets, &{&1.id, &1}),
  initial_lessons: [],
  allow_live: live
}

allowance = %{"requests" => 160, "tokens" => 3_000_000, "time_ms" => 2_000_000, "cost_usd" => nil}

runtime = %{
  "revision" => String.trim(revision),
  "source_tree_clean" => status == "",
  "environment" => "networkless_nonroot_container",
  "image" => elem(environment, 1).image,
  "code_sha256" => Contract.sha256(:erlang.term_to_binary(Host.module_info(:md5))),
  "generation" => %{"reasoning_effort" => effort, "max_tokens" => 8192},
  "refinement" => %{"repetitions" => 2, "maximum_candidates" => 1, "critic" => false},
  "retry" => %{"maximum_attempts" => 3, "stopping" => "first_verified_success"},
  "inference_route" => if(live, do: "codex_subscription", else: "scripted"),
  "transport_max_retries" => 0,
  "cost_kind" => "subscription_quota_not_api_billing",
  "billed_api" => false
}

runtime = Map.put(runtime, "sha256", Contract.digest(runtime))

:ok =
  Installation.write(Path.join(root, "warmup-plan.json"), %{
    "model" => model,
    "effort" => effort,
    "tasks" => Enum.map(warmup, & &1.id),
    "allowance_per_task" => allowance,
    "stopping" => "two_fixed_seed_tasks",
    "runtime" => runtime
  })

# The only credential file is an access-only private loan. Codex's refresh token
# is never copied, consumed or rewritten. No token enters an artifact or model.
auth =
  if live do
    case CodexAuth.prepare(path: Path.join(root, ".auth/oauth.json"), min_validity_hours: 2) do
      {:ok, path, _summary} ->
        path

      {:error, _} ->
        raise "Codex subscription access is unavailable or expires within two hours; no qualification calls started"
    end
  end

System.at_exit(fn _ -> if auth, do: CodexAuth.cleanup(auth) end)

try do
  execute = fn context, config ->
    IO.puts("episode #{context["repetition"]}/#{context["task"]["id"]}/#{context["arm"]}")
    {:ok, meter} = Agent.start_link(fn -> %{} end)

    provider = fn _role ->
      if live,
        do: Recording.new(meter, ReqLLM.new(receive_timeout: :infinity, max_retries: 0)),
        else:
          Scripted.new([
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
                          "reason" => "offline control"
                        })
                    },
                    usage: %{"input_tokens" => 2, "output_tokens" => 2}
                  ),
                else:
                  Scripted.complete("offline control",
                    usage: %{"input_tokens" => 2, "output_tokens" => 2}
                  )
            end,
            Scripted.complete("done", usage: %{"input_tokens" => 2, "output_tokens" => 2})
          ])
    end

    try do
      Host.episode(
        Map.merge(
          config,
          if(live, do: %{provider: provider, meter: meter}, else: %{provider: provider})
        ),
        context
      )
    after
      Agent.stop(meter)
    end
  end

  for fixture <- warmup do
    context = %{
      "arm" => "retrieval",
      "repetition" => 1,
      "task" => %{"id" => fixture.id, "source_sha256" => fixture.source_sha256},
      "allowance" => allowance,
      "prior_lesson_ids" => [],
      "available_case_ids" => []
    }

    {:ok, row} = execute.(context, config)
    :ok = Installation.write(Path.join(root, fixture.id <> "-result.json"), row)
  end

  seed_store = LessonFiles.new(Path.join(root, "library-retrieval-1"), scope)
  {:ok, seed_ids} = Lessons.inventory(seed_store)

  seeds =
    Enum.map(seed_ids, fn id ->
      {:ok, lesson} = Lessons.read(seed_store, id)
      lesson
    end)

  # Start each arm/repetition with the same immutable inventory, including
  # retrieval-1's existing seed records. No target case has been run yet.
  config = Map.put(config, :initial_lessons, seeds)
  library_sha = Contract.digest(%{"lessons" => Enum.map(seeds, & &1.sha256) |> Enum.sort()})

  {:ok, plan} =
    Qualification.plan(%{
      "id" => Path.basename(root),
      "model" => model,
      "effort" => effort,
      "runtime" => runtime,
      "seed_case_ids" => Enum.map(warmup, & &1.id),
      "initial_library_sha256" => library_sha,
      "repetitions" => repetitions,
      "allowance" => allowance,
      "alpha" => 0.05,
      "claim" => "development_qualification",
      "tasks" =>
        Enum.map(
          targets,
          &%{"id" => &1.id, "cluster" => &1.cluster, "source_sha256" => &1.source_sha256}
        )
    })

  :ok = Installation.write(Path.join(root, "plan.json"), plan)

  observer = fn event, payload ->
    id =
      case event do
        "intent" -> "#{payload["repetition"]}-#{payload["task"]["id"]}-#{payload["arm"]}"
        "completed" -> "#{payload["repetition"]}-#{payload["task_id"]}-#{payload["arm"]}"
        "report" -> "qualification"
      end

    Installation.write(Path.join(root, "#{id}-#{event}.json"), payload)
  end

  case Qualification.run(plan, &execute.(&1, config), observer: observer) do
    {:ok, report} ->
      IO.puts(JSON.encode!(Map.take(report, ~w(sha256 mechanics benefit arms comparisons))))

    {:error, _} ->
      raise "Qualification incomplete; retain intent and evidence for explicit reconciliation in #{root}"
  end
after
  if auth, do: CodexAuth.cleanup(auth)
end
