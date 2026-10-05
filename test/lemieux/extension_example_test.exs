defmodule Lemieux.ExtensionExampleTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent, as: CustomAgent
  alias Lemieux.Benchmark
  alias Lemieux.Benchmark.Runtime
  alias Lemieux.Benchmark.Runtime.Agent, as: AgentRuntime
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Learning.Extension.Workbench
  alias Lemieux.Learning.Extension.Workbench.View
  alias Lemieux.Providers.Scripted

  @example Path.expand("../../examples/extensions/review", __DIR__)
  Code.require_file(Path.join(@example, "lib/review_extension.ex"))

  @moduletag :tmp_dir

  test "the shipped review extension rejects invented locations and exposes a missed defect",
       context do
    valid = answer(2)
    invalid = answer(100)

    input = %{
      prompt: "review",
      cwd: Path.join(@example, "bench/fixtures/division"),
      timeout_ms: 5_000
    }

    assert {:error, :invalid_review, observation} =
             CustomAgent.run(ReviewExtension, input, options(invalid, context))

    assert observation["answer"] == invalid

    runtimes = [
      Runtime.new("finds-defect", AgentRuntime,
        agent: ReviewExtension,
        agent_options: options(valid, context)
      ),
      Runtime.new("misses-defect", AgentRuntime,
        agent: ReviewExtension,
        agent_options: options(~s({"findings":[]}), context)
      )
    ]

    assert {:ok, report} =
             Benchmark.run_file(Path.join(@example, "bench/manifest.json"), runtimes)

    assert [%{"passed" => true}, %{"passed" => false}] = report["results"]
  end

  test "exported source compiles in another BEAM and executes the public entry point", context do
    destination = Path.join(context.tmp_dir, "extension")
    assert {:ok, _receipt} = Export.export(@example, destination)
    assert :ok = Export.verify(destination)

    script = """
    [root] = System.argv()
    Code.compile_file(Path.join(root, "lib/review_extension.ex"))
    {:ok, _} = Application.ensure_all_started(:req_llm)
    provider = Lemieux.Providers.Scripted.new([
      Lemieux.Providers.Scripted.complete(#{inspect(answer(2))})
    ])
    input = %{prompt: "review", cwd: Path.join(root, "bench/fixtures/division"), timeout_ms: 5_000}
    {:ok, result} = Lemieux.Agent.run(ReviewExtension, input,
      provider: provider, model: "test:model",
      sessions_dir: Path.join(root, "tmp/sessions"))
    true = result["reviewed_files"] == ["calculator.ex"]
    true = result["answer"] == #{inspect(answer(2))}
    IO.puts("extension-consumer-ok")
    """

    # The child VM cannot inherit the example module loaded in the test VM.
    # Real dependency installation is additionally checked by the Mix consumer
    # smoke documented in the phase handoff.
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd("elixir", paths ++ ["-e", script, destination], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "extension-consumer-ok"
  end

  test "workbench reproduces the review extension's missed finding without changing its script",
       context do
    {config, _bindings} = Code.eval_file(Path.join(@example, "bench/compare.exs"))
    sessions = Path.join(context.tmp_dir, "sessions")

    # The script keeps its transcripts in the system's temporary directory,
    # which is right for someone trying the example and left eight there on
    # every run of this test.
    agents =
      for {name, module, options} <- Keyword.fetch!(config, :agents),
          do: {name, module, fn -> Keyword.put(options.(), :sessions_dir, sessions) end}

    config =
      config
      |> Keyword.put(:workbench_dir, Path.join(context.tmp_dir, "workbench"))
      |> Keyword.put(:agents, agents)

    assert {:ok, state} = Workbench.open(config, @example)

    for _ <- 1..2 do
      assert {:ok, report, _id} = Workbench.run(state)
      assert View.summary(report) =~ "finds-defect: 2/2 completed; 2 passed; 0 failed"
      assert View.summary(report) =~ "missing-finding: 2/2 completed; 0 passed; 2 failed"
      assert View.attempt(report, 1) =~ ~s({"findings":[]})
      assert View.attempt(report, 1) =~ "Grader exit: 1"
    end
  end

  defp answer(line) do
    JSON.encode!(%{
      "findings" => [
        %{
          "path" => "calculator.ex",
          "line" => line,
          "message" => "Zero denominator is not validated."
        }
      ]
    })
  end

  defp options(answer, context) do
    [
      provider: Scripted.new([Scripted.complete(answer)]),
      model: "test:model",
      supervisor: :"review_example_#{System.unique_integer([:positive])}",
      sessions_dir: Path.join(context.tmp_dir, "sessions")
    ]
  end
end
