defmodule Lemieux.ExtensionCompareTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Options
  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Builder
  alias Lemieux.Learning.Builder.Scaffold
  alias Lemieux.Learning.Extension.Workbench
  alias Mix.Tasks.Lemieux.Extension.Compare

  @moduletag :tmp_dir

  defmodule Provider do
    alias Lemieux.Providers.Scripted
    def available_models(_state, _opts), do: ["test:chosen"]
    def reasoning_efforts(_state, _model), do: ["default", "high"]
    def validate_model(_state, _model, _tools), do: :ok
    def estimate_cost(_state, _request), do: 0.01

    def run(_state, request, emit) do
      answer = if request.params[:reasoning_effort] == "high", do: "yes", else: "no"
      Enum.each(Scripted.complete(answer, usage: %{"cost_usd" => 0.01}), emit)
      :ok
    end
  end

  test "builder resolves an absent implicit default from the connection but preserves explicit choices" do
    previous = System.get_env("LMX_MODEL")
    System.delete_env("LMX_MODEL")

    on_exit(fn ->
      if previous, do: System.put_env("LMX_MODEL", previous), else: System.delete_env("LMX_MODEL")
    end)

    {:ok, options} = Options.parse(["--build-ext", "--quota"])
    options = %{options | model: "test:absent"}

    assert {:ok, resolved, runtime} =
             ExtensionExperience.prepare(options, provider: {Provider, nil})

    assert resolved.model == "test:chosen"
    assert runtime[:welcome] =~ "test:chosen"

    {:ok, explicit} = Options.parse(["--build-ext", "--model", "test:explicit"])

    assert {:ok, selected, _} =
             ExtensionExperience.prepare(explicit, provider: {Provider, nil})

    assert selected.model == "test:explicit"
    System.put_env("LMX_MODEL", "test:environment")
    {:ok, environment} = Options.parse(["--build-ext"])

    assert {:ok, selected, _} =
             ExtensionExperience.prepare(environment, provider: {Provider, nil})

    assert selected.model == "test:environment"
    {:ok, quota_only} = Options.parse(["--quota"])

    assert {:error, message} =
             ExtensionExperience.prepare(quota_only, provider: {Provider, nil})

    assert message =~ "quota_flag_requires_builder"
  end

  test "generated config resolves case and grader paths after workspace copying", %{tmp_dir: root} do
    profile = Builder.profile("test:chosen")
    source = Path.join(root, "generated")
    assert {:ok, _} = Scaffold.create(source, "generated_builder_case", profile)
    [{module, _beam}] = Code.compile_file(Path.join(source, "lib/generated_builder_case.ex"))
    assert module.profile() == profile

    File.cd!(source, fn ->
      {config, _} = Code.eval_file("bench/workbench.exs")
      {:ok, options, ^profile} = Profile.configure(profile, provider: {Provider, nil})
      # Not the system's temporary directory, an agent session's default.
      options = Keyword.put(options, :sessions_dir, Path.join(root, "sessions"))

      config =
        config
        |> Keyword.put(:execution, :scripted)
        |> Keyword.put(:agents, [{"baseline", module, options}])

      {:ok, state} = Workbench.open(config)

      assert state.project["suite"]["tasks"] |> hd() |> Map.fetch!("cwd") ==
               Path.join(source, "bench/cases/example")

      assert {:ok, %{"results" => [result]}, _} = Workbench.run(state)
      refute result["passed"]
      assert result["observation"]["status"] == "completed"
      assert result["grader"]["output"] =~ "Acceptance criteria have not been implemented"
      assert result["grader"]["exit_status"] == 1
    end)
  end

  test "compare plans without dispatch, repeats its selected search and records real request effort",
       %{tmp_dir: root} do
    cwd = Path.join(root, "case")
    File.mkdir!(cwd)
    suite = Path.join(root, "suite.json")

    File.write!(
      suite,
      JSON.encode!(%{
        "version" => 1,
        "tasks" => [
          %{
            "id" => "case",
            "prompt" => "answer",
            "cwd" => cwd,
            "grader" => %{"command" => ["test", "{answer}", "=", "yes"]}
          }
        ]
      })
    )

    config = Path.join(root, "workbench.exs")
    workbench = Path.join(root, "workbench")
    # Not the system's temporary directory, an agent session's default, where
    # every run of this test left four transcripts.
    sessions = Path.join(root, "sessions")

    File.write!(config, """
    provider = {#{inspect(Provider)}, nil}
    [suite: #{inspect(suite)}, workbench_dir: #{inspect(workbench)}, execution: :scripted,
     search_provider: provider,
     agents: [{"baseline", Lemieux.Agent.Session, fn ->
       [provider: provider, model: "test:chosen", session_options: [max_cost_usd: 0.1],
        sessions_dir: #{inspect(sessions)}]
     end}], benchmark_options: [cost_cap_usd: 0.3, max_cost_per_attempt_usd: 0.1]]
    """)

    selections = Path.join(root, "models.json")
    File.write!(selections, JSON.encode!([%{"model" => "test:chosen", "efforts" => ["high"]}]))
    output = capture_io(fn -> Compare.run([config, selections]) end)
    assert output =~ "Plan only"
    refute File.exists?(Path.join(workbench, "runs"))
    {settings, _} = Code.eval_file(config)

    for _ <- 1..2 do
      assert capture_io(fn -> Compare.run([config, selections, "--run"]) end) =~ "Saved run"
    end

    {:ok, state} = Workbench.open(settings)
    {:ok, ids} = Workbench.history(state)
    assert length(ids) == 2
    {:ok, report} = Workbench.report(state, hd(ids))
    assert Enum.map(report["results"], & &1["passed"]) == [false, true]

    assert Enum.all?(
             report["results"],
             &(get_in(&1, ["observation", "usage", "cost_usd"]) == 0.01)
           )

    File.write!(
      config,
      File.read!(config) |> String.replace("execution: :scripted", "execution: :live")
    )

    assert_raise Mix.Error, ~r/live_confirmation_required/, fn ->
      capture_io(fn -> Compare.run([config, selections, "--run"]) end)
    end

    {:ok, same_ids} = Workbench.history(state)
    assert same_ids == ids
  end
end
