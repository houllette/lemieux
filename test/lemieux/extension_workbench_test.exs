defmodule Lemieux.ExtensionWorkbenchTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.Corpus
  alias Lemieux.Benchmark.Manifest
  alias Lemieux.CLI.ExtensionWorkbench
  alias Lemieux.Learning.Extension.ModelSearch
  alias Lemieux.Learning.Extension.Workbench
  alias Lemieux.Learning.Extension.Workbench.View
  alias Lemieux.Providers.Scripted

  import ExUnit.CaptureIO

  @moduletag :tmp_dir

  test "confirmation imports workbench exposure even when a saved case is no longer selected",
       context do
    {:ok, state} = Workbench.open(context.config)
    {:ok, _report, _id} = Workbench.run(state)
    {:ok, manifest} = Manifest.read(context.suite)
    {:ok, corpus} = Corpus.new(manifest, %{"first" => :holdout})
    assert {:ok, exposed} = Workbench.expose_corpus(state, corpus)
    assert [_exposure] = Corpus.exposures(exposed, "first")

    assert {:error, {:case_exposed, "first"}} =
             Corpus.assign(exposed, "first", :holdout)
  end

  defmodule AnswerAgent do
    @behaviour Lemieux.Agent
    @impl true
    def run(input, opts) do
      send(opts[:owner], {:attempt, input, opts})
      answer = if input.prompt == opts[:session_options][:system], do: "yes", else: "no"
      {:ok, %{"status" => "completed", "answer" => answer}}
    end
  end

  defmodule ModelProvider do
    def available_models(_state, _opts), do: ["one:a", "two:b"]
    def reasoning_efforts(_state, "one:a"), do: ["default", "low", "high"]
    def reasoning_efforts(_state, _model), do: []
    def validate_model(_state, _model, _tools), do: :ok

    def run(owner, request, emit) do
      send(owner, {:model_request, request})
      answer = if request.params[:reasoning_effort] == "high", do: "yes", else: "no"
      Enum.each(Scripted.complete(answer, usage: %{"cost_usd" => 0.01}), emit)
      :ok
    end
  end

  test "model search preserves explicit effort and default clearing across repeated comparisons",
       context do
    provider = {ModelProvider, self()}

    # Transcripts in the test's own directory: by default an agent session
    # keeps them in the system's temporary one, where every run added two.
    factory = fn ->
      [
        provider: provider,
        model: "one:a",
        session_options: [params: [reasoning_effort: "high"]],
        sessions_dir: Path.join(context.tmp_dir, "sessions")
      ]
    end

    config = Keyword.put(context.config, :agents, [{"baseline", Lemieux.Agent.Session, factory}])
    {:ok, state} = Workbench.open(config)

    selection = [
      %{"model" => "one:a", "efforts" => ["high"]},
      %{"model" => "two:b", "efforts" => ["default"]}
    ]

    assert {:ok, state, names} = ModelSearch.add(state, "baseline", provider, selection)
    assert {:ok, ^state, ^names} = ModelSearch.add(state, "baseline", provider, selection)
    assert {:ok, state} = Workbench.select(state, ["first"], names)
    assert {:ok, report, id} = Workbench.run(state)
    assert Enum.map(report["results"], & &1["passed"]) == [true, false]
    assert_receive {:model_request, high}
    assert_receive {:model_request, default}
    assert high.model == "one:a"
    assert high.params[:reasoning_effort] == "high"
    assert default.model == "two:b"
    refute Keyword.has_key?(default.params, :reasoning_effort)
    assert {:ok, restored} = Workbench.open(config)
    assert restored.project == state.project
    assert {:ok, ^report} = Workbench.report(restored, id)
    original = File.read!(Path.join(state.root, "project.json"))

    assert {:error, {:effort_not_available, "two:b", "high"}} =
             ModelSearch.add(state, "baseline", provider, [
               %{"model" => "two:b", "efforts" => ["high"]}
             ])

    assert File.read!(Path.join(state.root, "project.json")) == original
  end

  setup context do
    workspace = Path.join(context.tmp_dir, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "source.txt"), "original")

    task = %{
      "id" => "first",
      "prompt" => "first",
      "cwd" => workspace,
      "grader" => %{"command" => ["test", "{answer}", "=", "yes"]}
    }

    suite = Path.join(context.tmp_dir, "suite.json")
    File.write!(suite, JSON.encode!(%{"version" => 1, "tasks" => [task]}))
    owner = self()

    factory = fn ->
      send(owner, :factory_called)
      [owner: owner, session_options: [system: "first"]]
    end

    config = [
      suite: suite,
      agents: [{"baseline", AnswerAgent, factory}],
      execution: :scripted,
      workbench_dir: Path.join(context.tmp_dir, "workbench")
    ]

    %{config: config, task: task, suite: suite}
  end

  test "case curation and variant tuning persist separately from extension source", context do
    original = File.read!(context.suite)
    assert {:ok, state} = Workbench.open(context.config)

    assert {:ok, state} =
             Workbench.put_case(state, %{context.task | "id" => "second", "prompt" => "second"})

    assert {:ok, state} =
             Workbench.put_variant(state, "candidate", "baseline", %{
               "system" => "second",
               "max_turns" => 3
             })

    assert {:ok, state} = Workbench.select(state, ["second"], ["candidate"])
    assert {:ok, restored} = Workbench.open(context.config)
    assert restored.project == state.project
    assert restored.project["selected_cases"] == ["second"]
    assert File.read!(context.suite) == original
    refute File.read!(Path.join(state.root, "project.json")) =~ "owner"
    refute_received :factory_called
    assert {:error, _} = Workbench.select(state, ["missing"], ["candidate"])
    assert {:error, _} = Workbench.put_variant(state, "bad", "baseline", %{"api_key" => "secret"})
  end

  test "repeated comparisons show a win and a regression, with unknown usage intact", context do
    {:ok, state} = Workbench.open(context.config)

    {:ok, state} =
      Workbench.put_case(state, %{context.task | "id" => "second", "prompt" => "second"})

    {:ok, state} = Workbench.put_variant(state, "candidate", "baseline", %{"system" => "second"})
    {:ok, state} = Workbench.select(state, ["first", "second"], ["baseline", "candidate"])

    for _ <- 1..2 do
      assert {:ok, report, id} = Workbench.run(state)

      assert [%{"left_wins" => 1, "right_wins" => 1, "matched_attempts" => 2}] =
               report["summary"]["pairs"]

      assert {:ok, ^report} = Workbench.report(state, id)
      rendered = View.summary(report)
      assert rendered =~ "candidate: 2/2 completed; 1 passed; 1 failed; 0 ungraded"
      assert rendered =~ "1 wins, 1 regressions"
      assert rendered =~ "cost USD unknown"
      assert rendered =~ "Development cases"
      assert View.attempt(report, 1) =~ "Answer:"
      assert File.exists?(Path.join([state.root, "runs", id, "plan.json"]))
    end

    assert {:ok, [_, _]} = Workbench.history(state)
    for _ <- 1..8, do: assert_received(:factory_called)
    assert_received {:attempt, %{cwd: copied}, _}
    refute copied == context.task["cwd"]
    assert {:error, :invalid_run_id} = Workbench.report(state, "../../project")
  end

  test "live execution refuses dispatch before explicit consent and budgets", context do
    {:ok, state} = Workbench.open(Keyword.put(context.config, :execution, :live))
    assert {:error, :live_confirmation_required} = Workbench.run(state)
    assert {:error, :live_budget_required} = Workbench.run(state, allow_live: true)
    refute_received :factory_called

    config =
      context.config
      |> Keyword.put(:execution, :live)
      |> Keyword.put(:benchmark_options, cost_cap_usd: 0.1, max_cost_per_attempt_usd: 0.1)

    {:ok, state} = Workbench.open(config)
    assert {:ok, report, _} = Workbench.run(state, allow_live: true)
    assert report["execution"]["unknown_cost_runs"] == 1
    assert_received {:attempt, _, options}
    assert options[:session_options][:max_cost_usd] == 0.1
  end

  test "quota execution requires consent, reserves attempts and preserves tighter request limits",
       context do
    limits = [usage_mode: :quota, max_attempts: 2, max_requests_per_attempt: 3, repetitions: 2]

    config =
      context.config |> Keyword.put(:execution, :live) |> Keyword.put(:benchmark_options, limits)

    {:ok, state} = Workbench.open(config)
    assert {:error, :live_confirmation_required} = Workbench.run(state)

    assert {:error, :quota_bounds_required} =
             Workbench.run(%{state | benchmark_options: Keyword.put(limits, :max_attempts, 1)},
               allow_live: true
             )

    refute_received :factory_called
    assert {:ok, report, _} = Workbench.run(state, allow_live: true)
    assert report["execution"]["scheduled"] == 2
    assert report["execution"]["unknown_cost_runs"] == 2
    assert View.summary(report) =~ "Direct model requests: unknown"

    for _ <- 1..2 do
      assert_received {:attempt, _, options}
      assert options[:session_options][:max_requests] == 3
      assert options[:session_options][:max_cost_usd] == nil
    end

    owner = self()
    factory = fn -> [owner: owner, session_options: [system: "first", max_requests: 1]] end

    {:ok, tighter} =
      Workbench.open(Keyword.put(config, :agents, [{"baseline", AnswerAgent, factory}]))

    assert {:ok, _, _} = Workbench.run(tighter, allow_live: true)
    assert_received {:attempt, _, options}
    assert options[:session_options][:max_requests] == 1
  end

  test "saved state and tuning values are revalidated before use", context do
    {:ok, state} = Workbench.open(context.config)

    assert {:error, _} =
             Workbench.put_variant(state, "candidate", "baseline", %{"max_turns" => -1})

    assert {:error, _} = Workbench.put_case(state, %{context.task | "grader" => %{}})

    File.write!(
      Path.join(state.root, "project.json"),
      JSON.encode!(Map.put(state.project, "selected_variants", ["absent"]))
    )

    assert {:error, _} = Workbench.open(context.config)
  end

  test "workbench storage cannot be copied into an agent's task workspace", context do
    config =
      Keyword.put(context.config, :workbench_dir, Path.join(context.task["cwd"], "results"))

    assert {:error, :workbench_directory_inside_task_workspace} = Workbench.open(config)
    refute File.exists?(config[:workbench_dir])
    refute_received :factory_called
  end

  test "live reservations stop incomplete comparisons and preserve a stricter session cap",
       context do
    owner = self()
    factory = fn -> [owner: owner, session_options: [system: "first", max_cost_usd: 0.01]] end

    config =
      context.config
      |> Keyword.put(:execution, :live)
      |> Keyword.put(:agents, [{"baseline", AnswerAgent, factory}])
      |> Keyword.put(:benchmark_options,
        cost_cap_usd: 0.1,
        max_cost_per_attempt_usd: 0.1,
        repetitions: 2
      )

    {:ok, state} = Workbench.open(config)
    assert {:ok, report, _} = Workbench.run(state, allow_live: true)
    assert report["execution"]["scheduled"] == 1
    assert report["execution"]["planned"] == 2
    assert report["execution"]["aborted"]
    assert View.summary(report) =~ "1/2 attempts scheduled"
    assert View.summary(report) =~ "cost USD unknown"
    assert_received {:attempt, _, options}
    assert options[:session_options][:max_cost_usd] == 0.01
  end

  test "terminal output removes escape sequences and reports missing attempts", _context do
    report = %{
      "results" => [
        %{
          "runtime" => "bad\e[2J",
          "task_id" => "case",
          "attempt" => 1,
          "passed" => false,
          "observation" => %{"status" => "failed", "answer" => "\e]0;title\aanswer"},
          "grader" => nil,
          "error" => "timeout",
          "wall_time_ms" => 12
        }
      ],
      "execution" => %{
        "scheduled" => 1,
        "planned" => 4,
        "aborted" => true,
        "reason" => "cost_reservation"
      },
      "summary" => %{"pairs" => []}
    }

    assert View.summary(report) =~ "1/4 attempts scheduled"
    assert View.summary(report) =~ "0/1 completed; 0 passed; 0 failed; 1 ungraded"
    refute View.summary(report) =~ "\e"
    refute View.attempt(report, 1) =~ "\a"
    assert View.attempt(report, 1) =~ "timeout"
  end

  test "operator curates a case, tunes a variant, compares and inspects a regression", context do
    input =
      Enum.join(
        [
          "case",
          "second",
          "second",
          context.task["cwd"],
          "1000",
          ~s(["test", "{answer}", "=", "yes"]),
          "variant",
          "candidate",
          "baseline",
          "",
          "second",
          "3",
          "select",
          "first,second",
          "baseline,candidate",
          "run",
          "reports",
          "inspect",
          "",
          "2",
          "quit",
          ""
        ],
        "\n"
      )

    output =
      capture_io(input, fn ->
        assert ExtensionWorkbench.run(context.config) == 0
      end)

    assert output =~ "Saved case second"
    assert output =~ "Saved variant candidate"
    assert output =~ "1 wins, 1 regressions"
    assert output =~ "Grader exit: 1"
    assert output =~ "Answer:\nno"
    assert output =~ "Finished candidate"
    assert output =~ "cost USD unknown"
  end

  test "EOF during live confirmation cancels before constructing a provider", context do
    config = Keyword.put(context.config, :execution, :live)
    output = capture_io("run\n", fn -> assert ExtensionWorkbench.run(config) == 0 end)
    assert output =~ "Type run-live"
    refute_received :factory_called
  end

  test "tuning reaches actual session requests and factories make repeated runs independent",
       context do
    owner = self()

    factory = fn ->
      provider =
        Scripted.new([
          fn request ->
            send(owner, {:request, request})
            Scripted.complete("yes")
          end
        ])

      [
        provider: provider,
        model: "test:old",
        session_options: [model: "test:old"],
        sessions_dir: Path.join(context.tmp_dir, "sessions")
      ]
    end

    config = Keyword.put(context.config, :agents, [{"baseline", Lemieux.Agent.Session, factory}])
    {:ok, state} = Workbench.open(config)

    {:ok, state} =
      Workbench.put_variant(state, "tuned", "baseline", %{
        "system" => "new instructions",
        "model" => "test:new",
        "temperature" => 0.2
      })

    {:ok, state} = Workbench.select(state, ["first"], ["tuned"])

    for _ <- 1..2 do
      assert {:ok, %{"results" => [%{"passed" => true}]}, _} = Workbench.run(state)
      assert_received {:request, request}
      assert request.model == "test:new"
      assert request.system == "new instructions"
      assert request.params[:temperature] == 0.2
    end
  end
end
