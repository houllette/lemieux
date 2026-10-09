defmodule Lemieux.CLI.RuntimeTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.MCP.Trust
  alias Lemieux.ModelCatalog
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  # A host's own extension, applied after everything `lmx` adds.
  defmodule Audit do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(harness, _state), do: %{harness | max_turns: 3}
  end

  defmodule Relax do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    @impl true
    def apply(harness, _state), do: %{harness | max_requests: 100, hooks: []}
  end

  test "explicit host constraints survive extension assembly", %{tmp_dir: tmp_dir} do
    {:ok, options} = Options.parse(["--no-delegate"])
    hooks = [before_tool_call: fn _call, _context -> {:deny, "host policy"} end]
    supervisor = :"lemieux_constraints_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    provider =
      Scripted.new([
        Scripted.tool_call("denied", "bash", %{"command" => "echo forbidden"}),
        Scripted.complete("unexpected")
      ])

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: supervisor,
        store: JSONL.new(tmp_dir),
        provider: provider,
        max_requests: 1,
        hooks: hooks,
        extensions: [Relax]
      )

    state = :sys.get_state(session)
    assert state.max_requests == 1
    assert state.hooks == hooks
    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, {:budget, %{kind: :requests}}}}
    assert length(Scripted.requests(provider)) == 1
    {:ok, entries} = Lemieux.Store.read(JSONL.new(tmp_dir), id)

    assert Enum.any?(
             entries,
             &(&1.type == :tool_result and &1.payload["output"] =~ "host policy")
           )
  end

  test "explicit nil disables automatic compaction through the CLI", %{tmp_dir: tmp_dir} do
    {:ok, options} = Options.parse(["--no-delegate"])
    supervisor = :"lemieux_nil_compaction_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    {:ok, session} =
      Runtime.start_session(options,
        supervisor: supervisor,
        store: JSONL.new(tmp_dir),
        provider: Scripted.new([]),
        compact_at: nil
      )

    assert :sys.get_state(session).compaction.compact_at == nil
  end

  test "a host's harness fields and its own extensions reach the assembled harness, after lmx's",
       %{tmp_dir: tmp_dir} do
    # A repository of its own, so the Elixir project around this test's
    # temporary directory does not offer the `/elixir` toggle.
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    assert {:ok, options} = Options.parse([])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               provider: Scripted.new([]),
               store: JSONL.new(tmp_dir),
               status_line: MyHost.Status,
               followups: MyHost.Followups,
               interactive?: true,
               cwd: tmp_dir,
               extensions: [Audit]
             )

    harness = prepared.harness
    assert harness.status_line == MyHost.Status
    assert harness.followups == MyHost.Followups
    assert harness.max_turns == 3

    assert Enum.map(harness.applied, & &1["module"]) == [
             "Lemieux.Extensions.Interactive",
             "Lemieux.Extensions.Search",
             "Lemieux.Extensions.ApplyPatch",
             "Lemieux.Extensions.Planning",
             "Lemieux.Extensions.Continuation",
             "Lemieux.Extensions.Budget",
             "Lemieux.Extensions.Delegation",
             "Lemieux.CLI.RuntimeTest.Audit"
           ]
  end

  describe "continuation" do
    defp applied(tmp_dir, settings, argv \\ []) do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, JSON.encode!(Map.put(settings, "version", 1)))
      assert {:ok, options} = Options.parse(["--config", path] ++ argv)

      assert {:ok, prepared} =
               Runtime.prepare(options, provider: Scripted.new([]), store: JSONL.new(tmp_dir))

      prepared.harness.applied
    end

    defp modules(applied), do: Enum.map(applied, & &1["module"])

    test "lmx sends the model back to unfinished work by default, ahead of verify", %{
      tmp_dir: tmp_dir
    } do
      modules = tmp_dir |> applied(%{}) |> modules()
      continuation = Enum.find_index(modules, &(&1 == "Lemieux.Extensions.Continuation"))
      verify = Enum.find_index(modules, &(&1 == "Lemieux.Extensions.Verify"))

      assert is_integer(continuation) and is_integer(verify)
      assert continuation < verify
    end

    test "the config's allowances reach the extension", %{tmp_dir: tmp_dir} do
      applied =
        applied(tmp_dir, %{
          "continuation" => %{
            "max_continuations" => 8,
            "max_output_continuations" => 1,
            "completion_check" => true
          }
        })

      assert %{"options" => options} =
               Enum.find(applied, &(&1["module"] == "Lemieux.Extensions.Continuation"))

      assert options["max_continuations"] == 8
      assert options["max_output_continuations"] == 1
      assert options["completion_check"] == true
    end

    test "\"continuation\": false and disabled_extensions both leave it out", %{tmp_dir: tmp_dir} do
      for settings <- [
            %{"continuation" => false},
            %{"continuation" => %{"enabled" => false}},
            %{"disabled_extensions" => ["continuation"]}
          ] do
        refute "Lemieux.Extensions.Continuation" in modules(applied(tmp_dir, settings)),
               inspect(settings)
      end
    end
  end

  # A session started with `--max-requests` tells the model what is left of
  # it (#35); one without a limit is told nothing, so lmx can always apply it.
  describe "budget" do
    test "lmx tells the model what is left of its limits by default", %{tmp_dir: tmp_dir} do
      assert "Lemieux.Extensions.Budget" in modules(applied(tmp_dir, %{}))
    end

    test "disabled_extensions leaves it out", %{tmp_dir: tmp_dir} do
      applied = applied(tmp_dir, %{"disabled_extensions" => ["budget"]})
      refute "Lemieux.Extensions.Budget" in modules(applied)
    end
  end

  test "config can withhold individual shipped extensions while leaving others enabled", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "config.json")
    File.write!(path, JSON.encode!(%{"version" => 1, "disabled_extensions" => ["interactive"]}))
    assert {:ok, options} = Options.parse(["--config", path])

    assert {:ok, prepared} =
             Runtime.prepare(options,
               provider: Scripted.new([]),
               store: JSONL.new(tmp_dir),
               interactive?: true
             )

    modules = Enum.map(prepared.harness.applied, & &1["module"])
    refute "Lemieux.Extensions.Interactive" in modules
    assert "Lemieux.Extensions.Delegation" in modules
    refute Enum.any?(prepared.harness.tools, &(Lemieux.Tool.name(&1) == "ask_user"))
  end

  # A tool an extension adds is part of what `/elixir` off goes back to.
  defmodule Ping do
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "ping"
    @impl true
    def description, do: "Answers pong."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}
    @impl true
    def run(_args, _context), do: {:ok, "pong"}
  end

  defmodule Equip do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    @impl true
    def apply(harness, _state), do: Lemieux.Harness.update_tools(harness, &(&1 ++ [Ping]))
  end

  defmodule Decorate do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    alias Lemieux.Tool.Override
    @impl true
    def apply(harness, _state) do
      Lemieux.Harness.update_tools(harness, fn tools ->
        Lemieux.Tool.decorate(tools, %{
          "bash" =>
            &Override.new!(&1,
              digest: "audit-v1",
              after: fn result, _args, _context -> result end
            )
        })
      end)
    end
  end

  defmodule PromptSuffix do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]
    @impl true
    def apply(harness, _state),
      do: Lemieux.Harness.update_system(harness, &((&1 || "") <> " + workspace"))
  end

  test "prompt composition starts from its original input on every resume", %{tmp_dir: tmp_dir} do
    {:ok, options} = Options.parse(["--no-delegate"])
    supervisor = :"lemieux_prompt_assembly_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})

    opts = [
      supervisor: supervisor,
      store: JSONL.new(tmp_dir),
      provider: Scripted.new([]),
      system: "host prompt",
      extensions: [PromptSuffix]
    ]

    {:ok, session} = Runtime.start_session(options, opts)
    id = Session.id(session)
    assert :sys.get_state(session).system == "host prompt + workspace"
    GenServer.stop(session)

    for _ <- 1..3 do
      assert {:ok, resumed} =
               Runtime.start_session(
                 Runtime.resume_options(options, id),
                 Keyword.delete(opts, :system)
               )

      assert :sys.get_state(resumed).system == "host prompt + workspace"
      GenServer.stop(resumed)
    end

    assert {:ok, prepared} =
             Runtime.prepare(Runtime.resume_options(options, id), Keyword.put(opts, :system, nil))

    assert prepared.harness.system == " + workspace"
  end

  test "decorated and added tools survive repeated resume without stacking", %{tmp_dir: tmp_dir} do
    {:ok, options} = Options.parse(["--no-delegate"])
    supervisor = :"lemieux_resume_assembly_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    provider = Scripted.new(List.duplicate(Scripted.complete("done"), 3))

    opts = [
      supervisor: supervisor,
      store: JSONL.new(tmp_dir),
      provider: provider,
      extensions: [Decorate, Equip],
      disabled_tools: ["write"]
    ]

    {:ok, session} = Runtime.start_session(options, opts)
    id = Session.id(session)
    GenServer.stop(session)

    for _ <- 1..3 do
      assert {:ok, resumed} =
               Runtime.start_session(
                 Runtime.resume_options(options, id),
                 Keyword.delete(opts, :disabled_tools)
               )

      assert Session.snapshot(resumed).tools == ~w(read grep glob write edit bash todo ping)

      assert %Lemieux.Tool.Override{tool: Tools.Bash} =
               Enum.find(Session.tools(resumed), &(Lemieux.Tool.name(&1) == "bash"))

      :ok = Session.prompt(resumed, "go")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert provider
             |> Scripted.requests()
             |> List.last()
             |> Map.fetch!(:tools)
             |> Enum.map(&Lemieux.Tool.name/1) == ~w(read grep glob edit bash todo ping)

      GenServer.stop(resumed)
    end
  end

  test "removing a wrapper requires an explicit replacement catalog", %{tmp_dir: tmp_dir} do
    {:ok, options} = Options.parse(["--no-delegate"])
    supervisor = :"lemieux_missing_wrapper_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    opts = [supervisor: supervisor, store: JSONL.new(tmp_dir), provider: Scripted.new([])]
    {:ok, session} = Runtime.start_session(options, Keyword.put(opts, :extensions, [Decorate]))
    id = Session.id(session)
    GenServer.stop(session)
    resumed_options = Runtime.resume_options(options, id)
    assert {:error, message} = Runtime.prepare(resumed_options, opts)
    assert message =~ "Decorate"

    assert {:ok, resumed} =
             Runtime.start_session(resumed_options, Keyword.put(opts, :tools, [Tools.Read]))

    assert Session.snapshot(resumed).tools == ["read"]
  end

  test "removing an additive extension and replacing a live catalog leave no stale recipe", %{
    tmp_dir: tmp_dir
  } do
    {:ok, options} = Options.parse(["--no-delegate"])
    supervisor = :"lemieux_replace_assembly_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    opts = [supervisor: supervisor, store: JSONL.new(tmp_dir), provider: Scripted.new([])]
    {:ok, session} = Runtime.start_session(options, Keyword.put(opts, :extensions, [Equip]))
    id = Session.id(session)
    GenServer.stop(session)
    {:ok, resumed} = Runtime.start_session(Runtime.resume_options(options, id), opts)
    assert Session.snapshot(resumed).tools == ~w(read grep glob write edit bash todo)
    GenServer.stop(resumed)

    {:ok, wrapped} = Runtime.start_session(options, Keyword.put(opts, :extensions, [Decorate]))
    wrapped_id = Session.id(wrapped)
    assert {:ok, ["read"]} = Session.set_tools(wrapped, [Tools.Read])
    GenServer.stop(wrapped)

    assert {:ok, replaced} =
             Runtime.start_session(Runtime.resume_options(options, wrapped_id), opts)

    assert Session.snapshot(replaced).tools == ["read"]
  end

  test "the standard catalog keeps the tools a host's extension added" do
    assert {:ok, options} = Options.parse([])

    assert {:ok, tools} = Runtime.standard_tools(options, interactive?: true, extensions: [Equip])

    assert Enum.map(tools, &Lemieux.Tool.name/1) ==
             ~w(read grep glob write edit bash ask_user todo ping)
  end

  test "the standard catalog retains diagram preview across the Elixir toggle" do
    assert {:ok, options} = Options.parse([])
    assert {:ok, tools} = Runtime.standard_tools(options, interactive?: true, a2ui: true)
    assert Enum.any?(tools, &(Lemieux.Tool.name(&1) == "diagram_preview"))
    assert {:ok, plain} = Runtime.standard_tools(options, interactive?: true, a2ui: false)
    refute Enum.any?(plain, &(Lemieux.Tool.name(&1) == "diagram_preview"))
  end

  # Provenance for free: the transcript says which code shaped the session.
  test "every request's snapshot records which extensions shaped the session", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, options} = Options.parse(["--elixir"])
    provider = Scripted.new([[{:done, :stop}]])
    supervisor = :"lemieux_cli_provenance_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: provider,
               store: JSONL.new(tmp_dir),
               supervisor: supervisor,
               interactive?: true
             )

    :ok = Session.prompt(session, "hello")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    snapshot =
      Enum.find_value(Session.snapshot(session).entries, fn entry ->
        if entry.type == :harness_snapshot, do: entry.payload
      end)

    assert Enum.map(snapshot["extensions"]["applied"], & &1["module"]) == [
             "Lemieux.Extensions.Interactive",
             "Lemieux.Extensions.Elixir",
             "Lemieux.Extensions.Continuation",
             "Lemieux.Extensions.Budget",
             "Lemieux.Extensions.Delegation"
           ]

    Supervisor.stop(supervisor)
  end

  test "the standalone host gives its base URL to every req_llm request", %{tmp_dir: tmp_dir} do
    base_url = "https://gateway.example/llm"
    assert {:ok, options} = Options.parse(["--base-url", base_url])

    supervisor = :"lemieux_cli_runtime_test_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               store: JSONL.new(tmp_dir),
               supervisor: supervisor,
               tools: []
             )

    expected =
      [base_url: base_url]
      |> Keyword.merge(
        ModelCatalog.provider_options() ++
          [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]
      )
      |> ReqLLMProvider.new()

    assert :sys.get_state(session).provider == expected

    Supervisor.stop(supervisor)
  end

  test "the standalone host allows slow Ollama prefill without hanging forever", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, options} = Options.parse(["--model", "ollama:qwen3.8:27b-mxfp8"])

    supervisor = :"lemieux_cli_ollama_runtime_test_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               store: JSONL.new(tmp_dir),
               supervisor: supervisor,
               tools: []
             )

    expected =
      ReqLLMProvider.new(
        ModelCatalog.provider_options() ++
          [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]
      )

    assert :sys.get_state(session).provider == expected

    Supervisor.stop(supervisor)
  end

  test "the streaming timeout policy survives switching from a hosted model to Ollama", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, options} = Options.parse([])
    supervisor = :"lemieux_cli_switched_ollama_test_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               store: JSONL.new(tmp_dir),
               supervisor: supervisor,
               tools: []
             )

    assert {:ok, "ollama:qwen3.8:27b-mxfp8"} =
             Session.set_model(session, "ollama:qwen3.8:27b-mxfp8")

    expected =
      ReqLLMProvider.new(
        ModelCatalog.provider_options() ++
          [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]
      )

    assert :sys.get_state(session).provider == expected

    Supervisor.stop(supervisor)
  end

  test "a resumed Ollama session restores the local provider tuning", %{tmp_dir: tmp_dir} do
    store = JSONL.new(tmp_dir)
    assert {:ok, original_options} = Options.parse(["--model", "ollama:qwen3.8:27b-mxfp8"])
    original_supervisor = :"lemieux_cli_ollama_original_#{System.unique_integer([:positive])}"

    assert {:ok, original} =
             Runtime.start_session(original_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: original_supervisor,
               tools: []
             )

    id = Session.id(original)
    Supervisor.stop(original_supervisor)

    assert {:ok, resume_options} = Options.parse(["--resume", id])
    resume_supervisor = :"lemieux_cli_ollama_resume_#{System.unique_integer([:positive])}"

    assert {:ok, resumed} =
             Runtime.start_session(resume_options,
               store: store,
               supervisor: resume_supervisor
             )

    expected =
      ReqLLMProvider.new(
        ModelCatalog.provider_options() ++
          [receive_timeout: :infinity, stream_idle_timeout: :timer.minutes(5)]
      )

    assert :sys.get_state(resumed).provider == expected

    Supervisor.stop(resume_supervisor)
  end

  # A resume that was given no tools takes them from its transcript, so the
  # scout has to be appended to *those*; and since the delegate is a struct the
  # session never records, re-equipping it writes no new configuration.
  test "resuming with --delegate re-equips the scout beside the recorded tools", %{
    tmp_dir: tmp_dir
  } do
    store = JSONL.new(tmp_dir)
    assert {:ok, original_options} = Options.parse(["--no-delegate", "--model", "test:model"])
    original_supervisor = :"lemieux_cli_delegate_original_#{System.unique_integer([:positive])}"

    assert {:ok, original} =
             Runtime.start_session(original_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: original_supervisor,
               tools: [Tools.Read, Tools.Edit]
             )

    id = Session.id(original)

    assert Enum.map(Session.tools(original), &Lemieux.Tool.name/1) ==
             ["read", "grep", "glob", "edit", "todo"]

    {:ok, before} = Lemieux.Store.read(store, id)
    Supervisor.stop(original_supervisor)

    assert {:ok, resume_options} = Options.parse(["--resume", id, "--delegate"])
    resume_supervisor = :"lemieux_cli_delegate_resume_#{System.unique_integer([:positive])}"

    assert {:ok, resumed} =
             Runtime.start_session(resume_options,
               provider: Scripted.new([]),
               store: store,
               supervisor: resume_supervisor
             )

    assert Enum.map(Session.tools(resumed), &Lemieux.Tool.name/1) ==
             ["read", "grep", "glob", "edit", "todo", "delegate"]

    {:ok, after_resume} = Lemieux.Store.read(store, id)

    assert Enum.count(after_resume, &(&1.type == :session)) ==
             Enum.count(before, &(&1.type == :session))

    Supervisor.stop(resume_supervisor)
  end

  test "a TUI workspace composes instructions while the bare runtime does not discover them", %{
    tmp_dir: tmp_dir
  } do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "always run the focused test")

    skill = Path.join(tmp_dir, ".agents/skills/review/SKILL.md")
    File.mkdir_p!(Path.dirname(skill))

    File.write!(
      skill,
      "---\nname: review\ndescription: Review changes when asked.\n---\nLATE SKILL BODY"
    )

    assert {:ok, options} = Options.parse(["--system", "custom base"])
    provider = Scripted.new([[{:done, :stop}]])
    supervisor = :"lemieux_cli_workspace_test_#{System.unique_integer([:positive])}"

    assert {:ok, workspace} = Discovery.discover(tmp_dir, personal?: false)

    assert {:ok, session} =
             Runtime.start_session(options,
               cwd: tmp_dir,
               workspace: workspace,
               provider: provider,
               store: JSONL.new(Path.join(tmp_dir, "sessions")),
               supervisor: supervisor,
               tools: []
             )

    :ok = Session.prompt(session, "hello")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert [%{system: system}] = Scripted.requests(provider)
    assert system =~ "custom base"
    assert system =~ "always run the focused test"
    assert system =~ "review: Review changes when asked."
    refute system =~ "LATE SKILL BODY"

    Supervisor.stop(supervisor)

    bare_provider = Scripted.new([[{:done, :stop}]])
    bare_supervisor = :"lemieux_cli_bare_workspace_test_#{System.unique_integer([:positive])}"

    assert {:ok, bare} =
             Runtime.start_session(options,
               cwd: tmp_dir,
               provider: bare_provider,
               store: JSONL.new(Path.join(tmp_dir, "bare-sessions")),
               supervisor: bare_supervisor,
               tools: []
             )

    :ok = Session.prompt(bare, "hello")
    bare_id = Session.id(bare)
    assert_receive {:lemieux, ^bare_id, {:finished, :stop}}
    assert [%{system: "custom base"}] = Scripted.requests(bare_provider)
    Supervisor.stop(bare_supervisor)
  end

  test "ecosystem flags require the TUI workspace host", %{tmp_dir: tmp_dir} do
    assert {:ok, options} = Options.parse(["--skill-dir", Path.join(tmp_dir, "skills")])
    supervisor = :"lemieux_cli_profile_boundary_#{System.unique_integer([:positive])}"

    assert {:error, reason} =
             Runtime.start_session(options,
               provider: Scripted.new([]),
               store: JSONL.new(tmp_dir),
               supervisor: supervisor,
               tools: []
             )

    assert reason =~ "full TUI workspace experience"
    refute Process.whereis(supervisor)
  end

  test "a TUI resume refreshes only the marked current workspace layer", %{tmp_dir: tmp_dir} do
    File.mkdir_p!(Path.join(tmp_dir, ".git"))
    instructions = Path.join(tmp_dir, "AGENTS.md")
    File.write!(instructions, "old workspace rule")
    store = JSONL.new(Path.join(tmp_dir, "sessions"))
    assert {:ok, options} = Options.parse(["--system", "stable base"])
    assert {:ok, old_workspace} = Discovery.discover(tmp_dir, personal?: false)
    original_supervisor = :"lemieux_tui_original_#{System.unique_integer([:positive])}"

    assert {:ok, original} =
             Runtime.start_session(options,
               workspace: old_workspace,
               provider: Scripted.new([]),
               store: store,
               supervisor: original_supervisor,
               tools: []
             )

    id = Session.id(original)
    Supervisor.stop(original_supervisor)

    File.write!(instructions, "new workspace rule")
    assert {:ok, new_workspace} = Discovery.discover(tmp_dir, personal?: false)
    assert {:ok, resumed_options} = Options.parse(["--resume", id])
    provider = Scripted.new([[{:done, :stop}]])
    resumed_supervisor = :"lemieux_tui_resumed_#{System.unique_integer([:positive])}"

    assert {:ok, resumed} =
             Runtime.start_session(resumed_options,
               workspace: new_workspace,
               provider: provider,
               store: store,
               supervisor: resumed_supervisor
             )

    :ok = Session.prompt(resumed, "continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert [%{system: system}] = Scripted.requests(provider)
    assert system =~ "stable base"
    assert system =~ "new workspace rule"
    refute system =~ "old workspace rule"

    Supervisor.stop(resumed_supervisor)
  end

  test "an explicit subscriber lets an async host start a session for another process", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, options} = Options.parse([])
    supervisor = :"lemieux_cli_subscriber_test_#{System.unique_integer([:positive])}"
    subscriber = spawn(fn -> receive do: (:stop -> :ok) end)

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: Scripted.new([]),
               store: JSONL.new(tmp_dir),
               subscriber: subscriber,
               supervisor: supervisor,
               tools: []
             )

    assert MapSet.member?(:sys.get_state(session).subscribers.pids, subscriber)

    Process.exit(subscriber, :kill)
    Supervisor.stop(supervisor)
  end

  test "the Elixir flag preserves ask_user only for an interactive baseline", %{tmp_dir: tmp_dir} do
    assert {:ok, options} = Options.parse(["--elixir"])

    interactive_supervisor =
      :"lemieux_cli_interactive_elixir_test_#{System.unique_integer([:positive])}"

    assert {:ok, interactive} =
             Runtime.start_session(options,
               provider: Scripted.new([]),
               store: JSONL.new(Path.join(tmp_dir, "interactive")),
               supervisor: interactive_supervisor,
               interactive?: true
             )

    # Delegation survives the mode: it narrows what this session may run, not
    # who it may ask.
    assert Session.snapshot(interactive).tools == ["elixir", "ask_user", "delegate"]

    headless_supervisor =
      :"lemieux_cli_headless_elixir_test_#{System.unique_integer([:positive])}"

    assert {:ok, headless} =
             Runtime.start_session(options,
               provider: Scripted.new([]),
               store: JSONL.new(Path.join(tmp_dir, "headless")),
               supervisor: headless_supervisor
             )

    assert Session.snapshot(headless).tools == ["elixir", "delegate"]

    Supervisor.stop(interactive_supervisor)
    Supervisor.stop(headless_supervisor)
  end

  test "the standalone delegate bounds child output before applying its cost cap", %{
    tmp_dir: tmp_dir
  } do
    result =
      JSON.encode!(%{
        "answer" => "The session owns cancellation.",
        "findings" => [],
        "artifacts" => [],
        "uncertainties" => [],
        "coverage" => %{"searched" => ["lib/lemieux/session.ex"], "skipped" => []}
      })

    child =
      Scripted.new(
        [
          [
            {:text_delta, result},
            {:usage, %{"input_tokens" => 8, "output_tokens" => 3, "cost_usd" => 0.01}},
            {:done, :stop}
          ]
        ],
        estimated_cost_usd: fn request ->
          if request.params[:max_tokens] == 8_192, do: 0.1, else: 2.0
        end
      )

    # Priced, because the bound under test exists only to satisfy the cost gate
    # and only a route that can price a request has one.
    parent =
      Scripted.new(
        [
          [
            {:tool_call,
             %{
               id: "delegate-1",
               name: "delegate",
               arguments: %{
                 "tasks" => [
                   %{
                     "definition_id" => "repository-scout",
                     "objective" => "Find who owns cancellation"
                   }
                 ]
               }
             }},
            {:done, :tool_calls}
          ],
          [{:done, :stop}]
        ],
        estimated_cost_usd: 0.001
      )

    assert {:ok, options} = Options.parse(["--delegate", "--model", "test:model"])
    supervisor = :"lemieux_cli_delegate_budget_test_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: parent,
               store: JSONL.new(tmp_dir),
               subscriber: self(),
               subagent_options: [providers: %{"repository-scout" => child}],
               supervisor: supervisor
             )

    :ok = Session.prompt(session, "Investigate first")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    assert [request] = Scripted.requests(child)
    assert request.params[:max_tokens] == 8_192

    Supervisor.stop(supervisor)
  end

  # The same delegation on a route that cannot price a request. The bound has
  # no gate to satisfy there and starves a reasoning model: `max_tokens`
  # becomes `max_completion_tokens`, reasoning spends it first, and the child
  # truncates before it answers.
  @tag :tmp_dir
  test "an unpriced route bounds the child in requests and leaves its output alone", %{
    tmp_dir: tmp_dir
  } do
    child = Scripted.new([[{:done, :stop}]])

    parent =
      Scripted.new([
        [
          {:tool_call,
           %{
             id: "delegate-1",
             name: "delegate",
             arguments: %{
               "tasks" => [
                 %{"definition_id" => "repository-scout", "objective" => "Find the owner"}
               ]
             }
           }},
          {:done, :tool_calls}
        ],
        [{:done, :stop}]
      ])

    assert {:ok, options} = Options.parse(["--delegate", "--model", "test:model"])
    supervisor = :"lemieux_cli_delegate_unpriced_test_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: parent,
               store: JSONL.new(tmp_dir),
               subscriber: self(),
               subagent_options: [providers: %{"repository-scout" => child}],
               supervisor: supervisor
             )

    :ok = Session.prompt(session, "Investigate first")
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

    assert [request] = Scripted.requests(child)
    assert request.params[:max_tokens] == nil

    Supervisor.stop(supervisor)
  end

  # Deliberately not inside `start_session/2`: that is the seam a host or a
  # test uses, and the repository a process happens to be running in is not a
  # reason to hand a session somebody else's servers — for a stdio server,
  # starting it means running its command.
  describe "project_mcp/2" do
    @servers ~s|{"mcpServers": {"tidewave": {"type": "http", "url": "http://localhost:4000/mcp"}}}|

    setup %{tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, ".git"))
      File.write!(Path.join(tmp_dir, ".mcp.json"), @servers)

      {:ok, root: tmp_dir}
    end

    # The repository's file is no longer copied into `mcp_config`, where it
    # was indistinguishable from a file somebody named; the MCP extension
    # reads it itself, behind the trust gate.
    @tag :tmp_dir
    test "nothing said leaves the repository's configuration to the trust gate", %{root: root} do
      options = %Options{mcp_config: nil}

      assert Runtime.project_mcp(options, cwd: root).mcp_config == nil
    end

    @tag :tmp_dir
    test "a repository's servers wait for trust, and start once trusted", %{root: root} do
      {:ok, parsed} = Options.parse(["--no-delegate"])
      options = %{parsed | mcp_config: nil}
      state = Path.join(root, "state")
      opts = [provider: Scripted.new([]), store: JSONL.new(root), cwd: root, state_dir: state]

      assert {:ok, held} = Runtime.prepare(options, opts)
      assert held.harness.mcp_servers in [nil, []]
      assert Enum.any?(held.harness.notices, &(&1 =~ "were not started"))
      assert %{status: :untrusted, store: ^state, cwd: ^root} = held.mcp_trust

      :ok =
        Trust.record(
          state,
          held.mcp_trust.workspace,
          held.mcp_trust.servers,
          :trusted
        )

      assert {:ok, trusted} = Runtime.prepare(options, opts)
      assert Enum.map(trusted.harness.mcp_servers, & &1["name"]) == ["tidewave"]
      assert trusted.mcp_trust == nil
    end

    @tag :tmp_dir
    test "--project-mcp trusts them for one run; with no state lmx says how", %{root: root} do
      {:ok, parsed} = Options.parse(["--no-delegate"])
      opts = [provider: Scripted.new([]), store: JSONL.new(root), cwd: root]

      assert {:ok, once} =
               Runtime.prepare(
                 %{parsed | mcp_config: nil, host: %{parsed.host | project_mcp_trusted: true}},
                 opts
               )

      assert Enum.map(once.harness.mcp_servers, & &1["name"]) == ["tidewave"]

      assert {:ok, hermetic} = Runtime.prepare(%{parsed | mcp_config: nil}, opts)
      assert hermetic.harness.mcp_servers in [nil, []]
      assert Enum.any?(hermetic.harness.notices, &(&1 =~ "--project-mcp"))
    end

    # A trust decision is one digest over the servers asked about. The
    # terminal UI asks again itself, so it is handed the names to leave out:
    # asked over the repository's whole file, it would record a digest the
    # extension, gating only `docs`, never matches.
    @tag :tmp_dir
    test "a server of the person's own replaces the repository's, in the session and the question",
         %{root: root} do
      File.write!(
        Path.join(root, ".mcp.json"),
        JSON.encode!(%{
          "mcpServers" => %{
            "search" => %{"type" => "http", "url" => "http://localhost:4000/mcp"},
            "docs" => %{"command" => "docs-server"}
          }
        })
      )

      config = Path.join(root, "config.json")
      mine = "http://127.0.0.1:9999/mcp"

      File.write!(
        config,
        JSON.encode!(%{"version" => 1, "mcp_servers" => %{"search" => %{"url" => mine}}})
      )

      File.chmod!(config, 0o600)

      {:ok, parsed} = Options.parse(["--no-delegate", "--config", config])
      options = %{parsed | mcp_config: nil}
      state = Path.join(root, "state")
      opts = [provider: Scripted.new([]), store: JSONL.new(root), cwd: root, state_dir: state]

      assert Runtime.claimed_mcp_names(options) == ["search"]
      assert {:ok, prepared} = Runtime.prepare(options, opts)

      # The person's server starts; the repository's `docs` waits for trust.
      assert [%{"name" => "search", "url" => ^mine, "source" => "personal"}] =
               prepared.harness.mcp_servers

      assert %{servers: [%{"name" => "docs"}], except: ["search"]} = prepared.mcp_trust
    end

    @tag :tmp_dir
    test "a named file is left alone, because naming one is the instruction", %{root: root} do
      options = %Options{mcp_config: "/tmp/elsewhere.json"}

      assert Runtime.project_mcp(options, cwd: root).mcp_config == "/tmp/elsewhere.json"
    end

    @tag :tmp_dir
    test "an opt-out is left alone, so `false` never becomes a path", %{root: root} do
      options = %Options{mcp_config: false}

      assert Runtime.project_mcp(options, cwd: root).mcp_config == false
    end

    # A resumed session's servers belong to its transcript; applying the
    # repository's here would rewrite what it recorded, the same mistake as
    # re-modelling it.
    @tag :tmp_dir
    test "a resume keeps the servers its transcript recorded", %{root: root} do
      options = %Options{mcp_config: nil, resume: "01ABC"}

      assert Runtime.project_mcp(options, cwd: root).mcp_config == nil
    end

    @tag :tmp_dir
    test "a repository without one is left with nothing to start", %{tmp_dir: tmp_dir} do
      empty = Path.join(tmp_dir, "empty")
      File.mkdir_p!(Path.join(empty, ".git"))

      assert Runtime.project_mcp(%Options{mcp_config: nil}, cwd: empty).mcp_config == nil
    end
  end
end
