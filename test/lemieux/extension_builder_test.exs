defmodule Lemieux.ExtensionBuilderTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  alias Lemieux.CLI.ExtensionExperience
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extension.Profile
  alias Lemieux.Harness
  alias Lemieux.Learning.Builder
  alias Lemieux.Learning.Builder.Scaffold
  alias Lemieux.Learning.Builder.Workflow
  alias Lemieux.Learning.Extension.Build
  alias Lemieux.Learning.Extension.Export
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Descriptor

  defmodule EffortProvider do
    alias Lemieux.Providers.Scripted
    def available_models(_, _), do: ["test:model"]
    def reasoning_efforts(_state, _model), do: ["default", "low", "high"]
    def validate_model(_state, _model, _tools), do: :ok

    def run(owner, request, emit) do
      send(owner, {:effort_request, request})
      Enum.each(Scripted.complete("Tuned builder ready"), emit)
      :ok
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    supervisor = :"builder_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    %{runtime: [supervisor: supervisor, store: JSONL.new(Path.join(root, "sessions")), cwd: root]}
  end

  test "TUI, headless and Agent use the same tuning and runtime provider", context do
    profile = Builder.profile("test:model")
    path = Path.join(context.tmp_dir, "profile.json")
    File.write!(path, JSON.encode!(profile))
    provider = Scripted.new([Scripted.complete("built")], estimated_cost_usd: 0.001)
    runtime = Keyword.put(context.runtime, :provider, provider)
    {:ok, cli} = Options.parse(["--extension-profile", path])
    # One profile extension leaves the experience; an attached host and a
    # headless one assemble the same tuning and differ only in the question tool.
    assert {:ok, cli, prepared} = ExtensionExperience.prepare(cli, runtime)
    interactive = Keyword.put(prepared, :interactive?, true)
    assert {:ok, %{harness: attached}} = Runtime.prepare(cli, interactive)
    assert {:ok, %{harness: bare}} = Runtime.prepare(cli, prepared)

    assert Map.take(attached, [:max_turns, :max_cost_usd, :params, :reasoning_effort]) ==
             Map.take(bare, [:max_turns, :max_cost_usd, :params, :reasoning_effort])

    assert {:ok, standard} = Runtime.standard_tools(cli, interactive)

    assert Enum.map(standard, &Lemieux.Tool.name/1) == [
             "read",
             "write",
             "edit",
             "bash",
             "ask_user"
           ]

    refute Enum.any?(bare.tools, &(Lemieux.Tool.name(&1) == "ask_user"))
    assert {:ok, session} = Runtime.start_session(cli, prepared)
    assert :ok = Lemieux.Session.prompt(session, "build")
    assert_receive {:lemieux, _, {:finished, :stop}}
    [request] = Scripted.requests(provider)

    agent_provider = Scripted.new([Scripted.complete("built")], estimated_cost_usd: 0.001)

    assert {:ok, agent_opts, ^profile} =
             Profile.configure(profile, Keyword.put(context.runtime, :provider, agent_provider))

    assert {:ok, %{"answer" => "built"}} =
             Lemieux.Agent.run(
               Builder,
               %{prompt: "build", cwd: context.tmp_dir, timeout_ms: 3000},
               agent_opts
             )

    [agent_request] = Scripted.requests(agent_provider)
    assert request.system == agent_request.system
    assert request.model == agent_request.model
    assert request.params == agent_request.params

    cli_provider = Scripted.new([Scripted.complete("CLI built")], estimated_cost_usd: 0.001)

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          assert :ok =
                   Lemieux.CLI.run(
                     ["run", "build", "--extension-profile", path],
                     Keyword.put(context.runtime, :provider, cli_provider)
                   )
        end)
      end)

    assert output =~ "CLI built"
    assert [cli_request] = Scripted.requests(cli_provider)
    assert cli_request.system == request.system
    assert cli_request.params == request.params
  end

  test "builder acceptance reads project-local notes and rejects altered tuning", context do
    profile = %{
      "execution" => "live",
      "model" => "test:placeholder",
      "tools" => ["read"],
      "options" => %{
        "system" => "Summarize local reports.",
        "max_turns" => 4,
        "max_tokens" => 512,
        "temperature" => 0.2,
        "max_cost_usd" => 0.5,
        "reasoning_effort" => "default"
      }
    }

    target = Path.join(context.tmp_dir, "report_helper")
    assert {:ok, _} = Scaffold.create(target, "report_helper", profile)

    File.write!(
      Path.join(target, "BUILDING.md"),
      "Real acceptance cases, model selection and confirmation remain outstanding."
    )

    grader = Path.expand("../../examples/extensions/builder/bench/grade.exs", __DIR__)
    arguments = ["--erl", "+S 2:2", grader, context.tmp_dir, "create", "created"]
    assert {_, 0} = System.cmd("elixir", arguments, stderr_to_stdout: true)
    export = Path.join(context.tmp_dir, "exported")
    assert {:ok, receipt} = Export.export(target, export)
    assert Map.has_key?(receipt["files"], "BUILDING.md")
    assert File.read!(Path.join(export, "BUILDING.md")) =~ "remain outstanding"
    assert :ok = Export.verify(export)

    File.write!(
      Path.join(target, "priv/profile.json"),
      JSON.encode!(put_in(profile, ["tools"], ["bash"]))
    )

    assert {_, 1} = System.cmd("elixir", arguments, stderr_to_stdout: true)
  end

  test "quota profiles run without a price estimate and enforce the session request bound",
       context do
    profile = Builder.profile("test:model") |> Profile.quota(1)
    assert :ok = Profile.validate(profile)

    for {key, value} <- [{"max_requests", 0}, {"max_requests", 1.5}, {"max_cost_usd", 1}] do
      assert {:error, :invalid_session_profile} =
               Profile.validate(put_in(profile, ["options", key], value))

      assert {:error, :invalid_frozen_profile} =
               Build.freeze(
                 context.tmp_dir,
                 Path.join(context.tmp_dir, "invalid"),
                 put_in(profile, ["options", key], value)
               )
    end

    provider =
      Scripted.new([
        Scripted.tool_call("guide", "extension_workflow", %{"action" => "guide"}),
        Scripted.complete("must not execute")
      ])

    {:ok, options, ^profile} =
      Profile.configure(profile, Keyword.put(context.runtime, :provider, provider))

    assert {:error, _, observation} =
             Lemieux.Agent.run(
               Builder,
               %{prompt: "guide", cwd: context.tmp_dir, timeout_ms: 3000},
               options
             )

    assert observation["tool_metrics"]["requests"] == 1
    snapshot = Enum.find(observation["transcript"], &(&1["type"] == "harness_snapshot"))
    assert snapshot["payload"]["context_limits"]["max_requests"] == 1
    assert observation["usage"]["cost_usd"] == nil
    assert length(Scripted.requests(provider)) == 1

    cli_provider = Scripted.new([Scripted.complete("quota builder ready")])

    # stderr too: `lmx run` announces the session and its unknown context
    # window there, and this was where those lines in a passing run came from.
    # Kept for the failure message, which is where a failed run explains itself.
    {{status, output}, stderr} =
      with_io(:stderr, fn ->
        with_io(fn ->
          Lemieux.CLI.run(
            ["run", "build", "--build-ext", "--quota", "--model", "test:model"],
            Keyword.put(context.runtime, :provider, cli_provider)
          )
        end)
      end)

    assert status == :ok, "lmx run returned #{inspect(status)}; on stderr:\n#{stderr}"
    assert output =~ "quota builder ready"
    assert [_request] = Scripted.requests(cli_provider)
    {:ok, cli} = Options.parse(["--build-ext", "--quota", "--model", "test:model"])

    {:ok, _, resolved} =
      ExtensionExperience.prepare(cli, Keyword.put(context.runtime, :provider, cli_provider))

    assert {:ok, tuned} = Harness.assemble(Harness.new(), [resolved[:profile]])
    assert tuned.max_requests == 30
    assert tuned.max_cost_usd == nil
    assert resolved[:welcome] =~ "remaining provider quota is unknown"

    target = Path.join(context.tmp_dir, "quota_source")
    assert {:ok, _} = Scaffold.create(target, "quota_source", profile)
    assert {:ok, ^profile} = Profile.read(Path.join(target, "priv/profile.json"))
    config = File.read!(Path.join(target, "bench/workbench.exs"))
    assert config =~ "usage_mode: :quota"
    assert config =~ "max_requests_per_attempt: 1"
  end

  test "the dollar-capped builder refuses an unpriceable Ixway route before opening", context do
    {:ok, options} = Options.parse(["--build-ext", "--model", "ixway:gpt-6-luna"])
    provider = Scripted.new([])

    assert {:error, message} =
             ExtensionExperience.prepare(
               options,
               Keyword.put(context.runtime, :provider, provider)
             )

    assert message =~ "Ixway"
    assert message =~ "/create-extension"
    assert message =~ "--quota"
    assert Scripted.requests(provider) == []
  end

  test "an explicit builder effort survives portable export and reaches CLI and Agent requests",
       context do
    profile = Builder.profile("test:model", quota: true, reasoning_effort: "low")
    source = Path.join(context.tmp_dir, "tuned")
    assert {:ok, _} = Scaffold.create(source, "tuned", profile)
    path = Path.join(source, "priv/profile.json")
    assert {:ok, ^profile} = Profile.read(path)
    provider = {EffortProvider, self()}
    runtime = Keyword.put(context.runtime, :provider, provider)

    capture_io(fn ->
      capture_io(:stderr, fn ->
        assert :ok = Lemieux.CLI.run(["run", "ready", "--extension-profile", path], runtime)
      end)
    end)

    assert_received {:effort_request, cli_request}
    assert cli_request.params[:reasoning_effort] == "low"
    assert {:ok, options, ^profile} = Profile.configure(profile, runtime)

    assert {:ok, _} =
             Lemieux.Agent.run(
               Builder,
               %{prompt: "ready", cwd: context.tmp_dir, timeout_ms: 3000},
               options
             )

    assert_received {:effort_request, agent_request}
    assert agent_request.params == cli_request.params
    assert agent_request.system == cli_request.system
  end

  test "the tested GLM-5.3 quota recipe is the CLI default for that explicit model", context do
    model = "zai_coding_plan:glm-5.3"

    profile = Builder.profile(model, quota: true)
    assert profile["options"]["max_requests"] == 12
    assert profile["options"]["reasoning_effort"] == "low"
    {:ok, cli} = Options.parse(["--build-ext", "--quota", "--model", model])
    runtime = Keyword.put(context.runtime, :provider, {EffortProvider, self()})
    assert {:ok, _, resolved} = ExtensionExperience.prepare(cli, runtime)
    assert {:ok, tuned} = Harness.assemble(Harness.new(), [resolved[:profile]])
    assert tuned.max_requests == profile["options"]["max_requests"]

    capture_io(fn ->
      capture_io(:stderr, fn ->
        assert :ok =
                 Lemieux.CLI.run(
                   ["run", "ready", "--build-ext", "--quota", "--model", model],
                   runtime
                 )
      end)
    end)

    assert_received {:effort_request, request}
    assert request.params[:reasoning_effort] == "low"
    assert request.system == profile["options"]["system"]

    assert Builder.profile(model, reasoning_effort: "default")["options"]["reasoning_effort"] ==
             "default"

    assert Builder.profile("zai_coding_plan:glm-4.7")["options"]["reasoning_effort"] == "default"
  end

  test "saving model choices writes the accepted grouped schema and refuses invalid replacements",
       context do
    tool = Workflow.new({EffortProvider, self()})
    selection = [%{"model" => "test:model", "efforts" => ["default", "low"]}]

    args = %{
      "action" => "save_models",
      "path" => "bench/models.json",
      "selection_json" => JSON.encode!(selection)
    }

    assert {:ok, _} =
             Workflow.run(tool, args, %{
               cwd: context.tmp_dir,
               environment: Lemieux.Environment.local()
             })

    path = Path.join(context.tmp_dir, "bench/models.json")
    bytes = File.read!(path)
    assert JSON.decode!(bytes) == selection

    for invalid <- [
          [%{"model" => "test:model", "effort" => "low"}],
          [%{"model" => "absent:model", "efforts" => ["default"]}]
        ] do
      assert {:error, _} =
               Workflow.run(tool, %{args | "selection_json" => JSON.encode!(invalid)}, %{
                 cwd: context.tmp_dir,
                 environment: Lemieux.Environment.local()
               })

      assert File.read!(path) == bytes
    end

    assert {:error, _} =
             Workflow.run(tool, %{args | "path" => "../outside.json"}, %{
               cwd: context.tmp_dir,
               environment: Lemieux.Environment.local()
             })

    refute_received {:effort_request, _}
  end

  test "profile flags refuse silent tuning changes and unsupported options", context do
    for argv <- [
          ["--build-ext", "--system", "replace"],
          ["--build-ext", "--elixir"],
          ["--build-ext", "--resume", "old"],
          ["--build-ext", "--extension-profile", "file"]
        ] do
      {:ok, options} = Options.parse(argv)
      assert {:error, _} = ExtensionExperience.prepare(options, context.runtime)
    end

    profile = Builder.profile("test:model")

    assert {:error, :invalid_session_profile} =
             Profile.validate(put_in(profile, ["options", "api_key"], "secret"))

    assert {:error, :invalid_session_profile} =
             Profile.validate(put_in(profile, ["options", "temperatur"], 0.2))

    assert {:error, :profile_effort_not_supported} =
             Profile.session_options(
               put_in(profile, ["options", "reasoning_effort"], "invented"),
               Scripted.new([])
             )
  end

  test "scaffold recovery names missing inputs and unsupported tools without blaming the environment",
       context do
    tool = Workflow.new(Scripted.new([]))

    assert {:error, missing} =
             Workflow.run(
               tool,
               %{"action" => "scaffold", "directory" => "created", "name" => "created"},
               %{cwd: context.tmp_dir, environment: Lemieux.Environment.local()}
             )

    assert missing =~ "Missing: profile_json"

    profile =
      Builder.profile("test:model")
      |> Profile.quota(20)
      |> Map.put("tools", ~w(read write edit bash fetch))

    args = %{
      "action" => "scaffold",
      "directory" => "created",
      "name" => "created",
      "profile_json" => JSON.encode!(profile)
    }

    assert {:error, invalid} =
             Workflow.run(tool, args, %{
               cwd: context.tmp_dir,
               environment: Lemieux.Environment.local()
             })

    assert invalid =~ "unsupported profile tools"
    assert invalid =~ "fetch"
    refute invalid =~ "environment"
    refute File.exists?(Path.join(context.tmp_dir, "created"))
    repaired = Map.update!(profile, "tools", &List.delete(&1, "fetch"))

    assert {:ok, _} =
             Workflow.run(tool, %{args | "profile_json" => JSON.encode!(repaired)}, %{
               cwd: context.tmp_dir,
               environment: Lemieux.Environment.local()
             })

    assert File.exists?(Path.join(context.tmp_dir, "created/priv/profile.json"))
  end

  test "comparison plans calculate candidate expansion and whole-comparison bounds" do
    tool = Workflow.new({EffortProvider, self()})

    args = %{
      "action" => "plan_models",
      "selection_json" =>
        JSON.encode!([%{"model" => "test:model", "efforts" => ["default", "low", "high"]}]),
      "case_count" => 2,
      "repetitions" => 2,
      "max_attempts" => 2,
      "max_requests_per_attempt" => 20
    }

    assert {:ok, json} = Workflow.run(tool, args, %{})
    plan = JSON.decode!(json)
    assert plan["candidate_count"] == 3
    assert plan["planned_attempts"] == 12
    assert plan["maximum_direct_requests"] == 240
    refute plan["fits_budget"]
    refute plan["executed"]
    assert {:ok, enough} = Workflow.run(tool, %{args | "max_attempts" => 12}, %{})
    assert JSON.decode!(enough)["fits_budget"]
    assert {:error, _} = Workflow.run(tool, Map.delete(args, "case_count"), %{})
  end

  test "workflow credentials stay outside descriptors and remote hosts cannot write local scaffolds",
       context do
    provider = ReqLLMProvider.new(api_keys: %{"openai" => "private-test-key"})
    tool = Workflow.new(provider)

    descriptor =
      tool |> Lemieux.Tool.descriptor() |> Descriptor.to_map() |> JSON.encode!()

    refute descriptor =~ "private-test-key"
    refute inspect(tool) =~ "private-test-key"
    profile = Builder.profile("test:model")
    environment = {RemoteWorkspace, nil}

    assert {:ok, options, ^profile} =
             Profile.configure(profile, provider: provider, environment: environment)

    assert options[:session_options][:environment] == environment

    assert {:error, message} =
             Workflow.run(
               tool,
               %{
                 "action" => "scaffold",
                 "directory" => "remote",
                 "name" => "remote",
                 "profile_json" => JSON.encode!(profile)
               },
               %{cwd: context.tmp_dir, environment: environment}
             )

    assert message =~ "local environment"
    refute File.exists?(Path.join(context.tmp_dir, "remote"))
  end

  test "first-party builder calls the scaffold tool through the ordinary agent loop", context do
    target = Path.join(context.tmp_dir, "created")
    profile = Builder.profile("test:model")

    provider =
      Scripted.new(
        [
          Scripted.tool_call("guide", "extension_workflow", %{"action" => "guide"},
            usage: %{"cost_usd" => 0.001}
          ),
          Scripted.tool_call(
            "scaffold",
            "extension_workflow",
            %{
              "action" => "scaffold",
              "directory" => "created",
              "name" => "created_extension",
              "profile_json" => JSON.encode!(profile)
            },
            usage: %{"cost_usd" => 0.001}
          ),
          Scripted.complete("Created; acceptance is still unassessed.")
        ],
        estimated_cost_usd: 0.001
      )

    {:ok, options, _} =
      Profile.configure(profile, Keyword.put(context.runtime, :provider, provider))

    assert {:ok, observation} =
             Lemieux.Agent.run(
               Builder,
               %{prompt: "Create a builder extension", cwd: context.tmp_dir, timeout_ms: 5000},
               options
             )

    assert observation["tool_metrics"]["calls"] == 2
    assert observation["tool_metrics"]["errors"] == 0
    assert :ok = Export.verify(target)
    assert {:ok, ^profile} = Profile.read(Path.join(target, "priv/profile.json"))

    assert File.read!(Path.join(target, "lib/created_extension.ex")) =~
             "Lemieux.Extension.Profile.run"

    assert {:error, :destination_exists} = Scaffold.create(target, "created_extension", profile)

    assert {:error, _} =
             Workflow.run(
               Workflow.new(provider),
               %{
                 "action" => "scaffold",
                 "directory" => "../escape",
                 "name" => "escape",
                 "profile_json" => JSON.encode!(profile)
               },
               %{cwd: context.tmp_dir, environment: Lemieux.Environment.local()}
             )
  end

  test "builder TUI welcomes the developer and carries questions through the normal channel",
       context do
    owner = self()

    provider =
      Scripted.new(
        [
          Scripted.tool_call(
            "question",
            "ask_user",
            %{
              "question" => "What counts as a correct review?",
              "options" => [
                %{"label" => "Find regressions", "description" => "Focus on behavior changes"},
                %{"label" => "Review style", "description" => "Focus on code conventions"}
              ]
            },
            usage: %{"cost_usd" => 0.001}
          ),
          Scripted.complete("I will use that acceptance criterion.")
        ],
        estimated_cost_usd: 0.001
      )

    {:ok, options} = Options.parse(["--build-ext", "--model", "test:model"])

    # `interactive?:` is what puts `ask_user` in the catalog, the same way the
    # TUI says it before preparing a session.
    {:ok, options, opts} =
      ExtensionExperience.prepare(
        options,
        context.runtime |> Keyword.put(:provider, provider) |> Keyword.put(:interactive?, true)
      )

    start = fn ->
      {:ok, session} =
        Runtime.start_session(options, Keyword.put(opts, :subscriber, [self(), owner]))

      send(owner, {:session, session})
      {:ok, session}
    end

    {:ok, app} =
      Lemieux.TUI.start_link(
        test_mode: {90, 28},
        name: nil,
        start: start,
        welcome: opts[:welcome]
      )

    assert_receive {:session, session}
    state = :sys.get_state(app).user_state

    assert Enum.any?(state.lines, fn {_, text} ->
             is_binary(text) and String.contains?(text, "What job should")
           end)

    for character <- ["b", "u", "i", "l", "d", "enter"] do
      ExRatatui.Runtime.inject_event(app, %ExRatatui.Event.Key{code: character, kind: "press"})
    end

    assert_receive {:lemieux, _, {:question, question}}
    assert question.question == "What counts as a correct review?"
    assert :ok = Lemieux.Session.answer(session, "question", "Find regressions with evidence")
    assert_receive {:lemieux, _, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 2
    GenServer.stop(app)
  end
end
