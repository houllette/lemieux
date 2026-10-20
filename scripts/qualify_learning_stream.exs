# Product-path supplement to the five-arm refinement protocol. All results are
# development evidence: the fixture families are developer-visible, not holdouts.
alias Lemieux.Benchmark.Runtime, as: BenchmarkRuntime
alias Lemieux.CLI.Config
alias Lemieux.CLI.Learning.CodexAuth
alias Lemieux.CLI.Learning.Container
alias Lemieux.CLI.Learning.Fixtures
alias Lemieux.CLI.Learning.Installation
alias Lemieux.CLI.Learning.Leases
alias Lemieux.CLI.Learning.Loop
alias Lemieux.CLI.Learning.Recording
alias Lemieux.CLI.Options
alias Lemieux.CLI.Runtime.Evaluation
alias Lemieux.Contract
alias Lemieux.Providers.ReqLLM
alias Lemieux.Providers.Scripted
alias Lemieux.Store.JSONL

{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      allow_live: :boolean,
      output: :string,
      model: :string,
      effort: :string,
      variants: :integer,
      repetitions: :integer
    ]
  )

live = opts[:allow_live] == true
model = opts[:model] || if(live, do: "openai_codex:gpt-6-luna", else: "test:model")
effort = opts[:effort] || if(live, do: "low", else: "default")
variants = opts[:variants] || 2
repetitions = opts[:repetitions] || 2
true = variants in 1..5 and repetitions in 2..10

if live and
     (not String.starts_with?(model, "openai_codex:") or
        effort not in ~w(low medium high xhigh max)),
   do: raise("Use an authorized Codex subscription model/effort")

if not live and (model != "test:model" or effort != "default"),
  do: raise("Offline uses only Scripted")

{revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
{status, 0} = System.cmd("git", ["status", "--porcelain"])

if live and status != "",
  do: raise("Commit product-path qualification code before live execution")

root = Path.expand(opts[:output] || "tmp/learning-stream-#{Lemieux.ID.generate()}")
:ok = File.mkdir_p(Path.dirname(root))
:ok = File.mkdir(root)
:ok = File.chmod(root, 0o700)

{:ok, environment} =
  Container.new("python@sha256:2dd78ad5cf13a0b68f5134dc49aa9950203a8cf4b7463431b9f3b398287c5059")

fixtures = Fixtures.materialize(Path.join(root, "sources"), variants)

fixtures =
  Enum.map(fixtures, fn fixture ->
    bytes = "test:\n\tpython checks.py\n"
    File.write!(Path.join(fixture.task.cwd, "Makefile"), bytes)

    task = %{
      fixture.task
      | prompt: String.replace(fixture.task.prompt, "python checks.py", "make test")
    }

    %{fixture | task: task, immutable: Map.put(fixture.immutable, "Makefile", bytes)}
  end)

plan = %{
  "schema_version" => 1,
  "claim" => "development_product_path",
  "revision" => String.trim(revision),
  "source_tree_clean" => status == "",
  "model" => model,
  "effort" => effort,
  "image" => elem(environment, 1).image,
  "repetitions" => repetitions,
  "arms" => ["disabled", "ordinary"],
  "requests_per_task" => 32,
  "time_ms_per_task" => 480_000,
  "learning_requests" => 0,
  "inference_route" => if(live, do: "codex_subscription", else: "scripted"),
  "transport_max_retries" => 0,
  "stopping" => "fixed_complete_sample",
  "decision" => "mechanics_and_nonregression_only_no_benefit_claim",
  "tasks" =>
    Enum.map(fixtures, fn f ->
      {:ok, digest} = Leases.source_digest(f.task.cwd)
      %{"id" => f.id, "cluster" => f.cluster, "source_sha256" => digest}
    end)
}

plan = Map.put(plan, "sha256", Contract.digest(plan))
:ok = Installation.write(Path.join(root, "plan.json"), plan)
{:ok, _} = Lemieux.Supervisor.start_link(name: Lemieux.StreamQualificationSupervisor)

auth =
  if live do
    {:ok, path, _summary} =
      CodexAuth.prepare(path: Path.join(root, ".auth/oauth.json"), min_validity_hours: 2)

    path
  end

System.at_exit(fn _ -> if auth, do: CodexAuth.cleanup(auth) end)
Logger.configure(level: :warning)

try do
  rows =
    for repetition <- 1..repetitions,
        fixture <- fixtures,
        arm <-
          if(rem(repetition, 2) == 0,
            do: ["ordinary", "disabled"],
            else: ["disabled", "ordinary"]
          ) do
      name = "#{repetition}-#{fixture.id}-#{arm}"
      IO.puts("product episode #{name}")
      cwd = Path.join([root, "workspaces", "#{repetition}-#{arm}"])

      :ok =
        Installation.write(Path.join(root, name <> "-intent.json"), %{
          "plan_sha256" => plan["sha256"],
          "episode" => name
        })

      File.rm_rf!(cwd)
      :ok = File.mkdir_p(Path.dirname(cwd))
      {:ok, _} = File.cp_r(fixture.task.cwd, cwd)
      home = Path.join([root, "state", "#{repetition}-#{arm}"])

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
          model
        ])

      options = %{options | config: %Config{settings: %{"learning" => arm == "ordinary"}}}
      options = put_in(options.host.state_dir, home)
      {:ok, meter} = Agent.start_link(fn -> %{} end)

      provider =
        if live,
          do: Recording.new(meter, ReqLLM.new(receive_timeout: :infinity, max_retries: 0)),
          else:
            Scripted.new([
              Scripted.tool_call("check", "bash", %{"command" => "make test"},
                usage: %{"input_tokens" => 2, "output_tokens" => 2}
              ),
              Scripted.complete("offline control",
                usage: %{"input_tokens" => 2, "output_tokens" => 2}
              )
            ])

      host = [
        cwd: cwd,
        state_dir: home,
        provider: provider,
        supervisor: Lemieux.StreamQualificationSupervisor,
        store: JSONL.new(Path.join(root, "sessions")),
        environment: environment,
        max_requests: 32,
        max_turns: 32,
        max_cost_usd: nil,
        reasoning_effort: effort,
        params: [max_tokens: 8192],
        interactive?: false
      ]

      started = System.monotonic_time(:millisecond)

      try do
        runtime = Evaluation.runtime(name, options, host)

        observation =
          case BenchmarkRuntime.run(runtime, %{fixture.task | cwd: cwd}) do
            {:ok, observation} -> observation
            {:error, _reason, observation} -> observation
            error -> raise "Product-path episode incomplete: #{inspect(error)}"
          end

        grade = Fixtures.grade(fixture, cwd, environment)
        {:ok, info} = Loop.inspect(home, cwd)

        :ok =
          Installation.write(Path.join(root, name <> "-evidence.json"), %{
            "observation" => observation,
            "grade" => grade,
            "learning" => info
          })

        dispatched =
          if live, do: map_size(Agent.get(meter, & &1)), else: length(Scripted.requests(provider))

        saw_context =
          Enum.any?(observation["transcript"], fn entry ->
            entry["type"] == "request" and
              String.contains?(entry["payload"]["system"] || "", "Prior scoped experience")
          end)

        row = %{
          "arm" => arm,
          "repetition" => repetition,
          "task_id" => fixture.id,
          "cluster" => fixture.cluster,
          "grade" => grade,
          "requests" => dispatched,
          "usage" => observation["usage"],
          "latency_ms" => System.monotonic_time(:millisecond) - started,
          "context_received" => saw_context,
          "learning_requests" => 0,
          "retained" => info["retained"],
          "last" => info["last"],
          "evidence_sha256" => Contract.digest(observation)
        }

        :ok = Installation.write(Path.join(root, name <> "-completed.json"), row)
        row
      after
        Agent.stop(meter)
      end
    end

  report = %{
    "schema_version" => 1,
    "plan_sha256" => plan["sha256"],
    "model" => model,
    "effort" => effort,
    "claim" => "development_product_path",
    "benefit" => "unassessed",
    "rows" => rows,
    "arms" =>
      Map.new(["disabled", "ordinary"], fn arm ->
        selected = Enum.filter(rows, &(&1["arm"] == arm))

        {arm,
         %{
           "passed" => Enum.count(selected, & &1["grade"]["passed"]),
           "tasks" => length(selected),
           "requests" => Enum.sum(Enum.map(selected, & &1["requests"])),
           "tasks_receiving_experience" => Enum.count(selected, & &1["context_received"])
         }}
      end)
  }

  report = Map.put(report, "sha256", Contract.digest(report))
  :ok = Installation.write(Path.join(root, "report.json"), report)
  IO.puts(JSON.encode!(Map.take(report, ~w(sha256 model effort arms benefit))))
after
  if auth, do: CodexAuth.cleanup(auth)
end
