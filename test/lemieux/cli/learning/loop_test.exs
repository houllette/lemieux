defmodule Lemieux.CLI.Learning.LoopTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Learning.Loop
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    cwd = Path.join(dir, "workspace")
    File.mkdir_p!(Path.join(cwd, ".git"))
    File.write!(Path.join(cwd, "value"), "broken")
    File.write!(Path.join(cwd, "Makefile"), "test:\n\t@test \"$$(cat value)\" = fixed\n")

    {:ok, options} =
      Options.parse([
        "--no-delegate",
        "--no-web-fetch",
        "--no-project-mcp",
        "--no-sandbox",
        "--permission-mode",
        "off"
      ])

    options = %{options | config: %Config{settings: %{}}}
    options = put_in(options.host.state_dir, Path.join(dir, "personal"))
    supervisor = :"learning_loop_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: supervisor})
    host = [cwd: cwd, supervisor: supervisor, store: JSONL.new(Path.join(dir, "sessions"))]
    %{options: options, host: host, cwd: cwd}
  end

  test "stock headless and interactive assembly reuse the first task's recovery without extra requests",
       ctx do
    for interactive <- [false, true] do
      File.write!(Path.join(ctx.cwd, "value"), "broken")

      first =
        Scripted.new([
          Scripted.tool_call("fail", "bash", %{"command" => "make test"}),
          Scripted.tool_call("read", "read", %{"path" => "value"}),
          Scripted.tool_call("fix", "write", %{"path" => "value", "content" => "fixed"}),
          Scripted.tool_call("pass", "bash", %{"command" => "make test"}),
          Scripted.complete("fixed")
        ])

      run(ctx, first, "Fix the failing test", interactive)
      assert length(Scripted.requests(first)) == 5

      second =
        Scripted.new([
          fn request ->
            Scripted.complete(
              if request.system =~ "Prior scoped experience",
                do: "I will check the recurring verification failure first",
                else: "No experience received"
            )
          end
        ])

      run(ctx, second, "Investigate the next failing test", interactive)
      assert [request] = Scripted.requests(second)
      assert request.system =~ "Prior scoped experience"
      assert request.system =~ "make test"
      assert request.system =~ "unconfirmed"
      assert request.system =~ "observed_exit_statuses"
      assert request.system =~ "[2,0]"
      refute request.system =~ "evidence_file"
      assert {:ok, status} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
      assert status["retained"] >= 1
      assert status["last"]["action"] == "task_local_context"
      assert status["last"]["learning_requests"] == 0
      assert status["last"]["exposure_sha256"]
      assert second_result = List.last(Scripted.requests(second)).system
      assert String.contains?(second_result, "Observed verification_recovery")
    end
  end

  test "undo restores the exact request base and keeps exposure audit", ctx do
    train(ctx)
    recalled = Scripted.new([Scripted.complete("looked at the recovery")])
    run(ctx, recalled, "Investigate the next failing test", false)
    assert [with_experience] = Scripted.requests(recalled)
    base = with_experience.system |> String.split("\n\nPrior scoped experience") |> hd()
    assert {:ok, before_undo} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)

    for n <- 1..1000 do
      File.write!(
        Path.join([before_undo["evidence_directory"], "evidence", "quota-#{n}.json"]),
        ""
      )
    end

    assert :ok = Loop.undo(ctx.options.host.state_dir, ctx.cwd)
    assert {:ok, info} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    assert info["last"]["restored_system_sha256"] == Lemieux.Contract.sha256(base)
    assert info["blocked"] != []
    evidence = File.ls!(Path.join(info["evidence_directory"], "evidence"))

    ordinary = Scripted.new([Scripted.complete("ordinary")])
    run(ctx, ordinary, "Investigate the next failing test", false)
    assert [request] = Scripted.requests(ordinary)
    assert request.system == base

    assert Enum.all?(
             evidence,
             &File.exists?(Path.join([info["evidence_directory"], "evidence", &1]))
           )
  end

  test "one interactive session consumes earlier task experience and obeys an immediate opt-out",
       ctx do
    provider =
      training_steps() ++
        [
          Scripted.complete("second"),
          Scripted.complete("Test recovery"),
          Scripted.complete("third")
        ]

    provider = Scripted.new(provider)
    host = Keyword.merge(ctx.host, provider: provider, interactive?: true, max_requests: 8)
    assert {:ok, session} = Runtime.start_session(ctx.options, host)
    id = Session.id(session)

    for prompt <- ["Fix the failing test", "Investigate the next failing test"] do
      assert :ok = Session.prompt(session, prompt)
      assert_receive {:lemieux, ^id, {:finished, _}}
    end

    assert Enum.at(Scripted.requests(provider), 5).system =~ "Prior scoped experience"
    assert :ok = Loop.set_enabled(ctx.options.host.state_dir, ctx.cwd, false)
    assert :ok = Session.prompt(session, "Investigate a third failing test")
    assert_receive {:lemieux, ^id, {:finished, _}}
    refute List.last(Scripted.requests(provider)).system =~ "Prior scoped experience"
    GenServer.stop(session)
    assert length(Scripted.requests(provider)) == 8
  end

  test "malformed or symlinked policy and busy storage preserve the original task", ctx do
    File.mkdir_p!(Path.join(ctx.cwd, ".lmx"))
    File.write!(Path.join(ctx.cwd, ".lmx/learning.json"), "{bad")
    run(ctx, Scripted.new([Scripted.complete("ordinary")]), "test", false)
    refute File.exists?(Path.join(ctx.options.host.state_dir, "learning"))

    File.rm!(Path.join(ctx.cwd, ".lmx/learning.json"))
    assert :ok = Loop.set_enabled(ctx.options.host.state_dir, ctx.cwd, true)
    assert {:ok, info} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    File.mkdir!(Path.join(info["evidence_directory"], "control.lock"))
    provider = Scripted.new([Scripted.complete("original retained")])
    run(ctx, provider, "test", false)
    assert [request] = Scripted.requests(provider)
    refute request.system =~ "Prior scoped experience"
    File.rmdir!(Path.join(info["evidence_directory"], "control.lock"))
    File.rm!(Path.join(info["evidence_directory"], "control.json"))
    File.ln_s!(Path.join(ctx.cwd, "value"), Path.join(info["evidence_directory"], "control.json"))
    assert {:error, :unsafe_learning_path} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    provider = Scripted.new([Scripted.complete("still ordinary")])
    run(ctx, provider, "test", false)
    assert length(Scripted.requests(provider)) == 1
    assert File.read!(Path.join(ctx.cwd, "value")) == "broken"
  end

  test "undo blocks derived observations from reintroducing the same experience", ctx do
    train(ctx)
    File.write!(Path.join(ctx.cwd, "value"), "broken")
    train(ctx)
    assert {:ok, before_undo} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    assert before_undo["retained"] >= 2
    assert length(before_undo["last"]["lesson_ids"]) == 1
    assert :ok = Loop.undo(ctx.options.host.state_dir, ctx.cwd)
    assert {:ok, undone} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    assert length(undone["blocked"]) == before_undo["retained"]
    provider = Scripted.new([Scripted.complete("original behavior")])
    run(ctx, provider, "Investigate the next failing test", false)
    assert [request] = Scripted.requests(provider)
    refute request.system =~ "Prior scoped experience"
  end

  test "personal opt-out and changed model refuse reuse", ctx do
    train(ctx)

    for options <- [
          %{ctx.options | model: "test:changed"},
          %{ctx.options | config: %Config{settings: %{"learning" => false}}}
        ] do
      provider = Scripted.new([Scripted.complete("ordinary")])
      run(%{ctx | options: options}, provider, "Investigate the next failing test", false)
      assert [request] = Scripted.requests(provider)
      refute request.system =~ "Prior scoped experience"
    end
  end

  defp train(ctx), do: run(ctx, Scripted.new(training_steps()), "Fix the failing test", false)

  defp training_steps,
    do: [
      Scripted.tool_call("fail", "bash", %{"command" => "make test"}),
      Scripted.tool_call("read", "read", %{"path" => "value"}),
      Scripted.tool_call("fix", "write", %{"path" => "value", "content" => "fixed"}),
      Scripted.tool_call("pass", "bash", %{"command" => "make test"}),
      Scripted.complete("fixed")
    ]

  test "opt-out persists and takes effect for an already assembled session", ctx do
    assert :ok = Loop.set_enabled(ctx.options.host.state_dir, ctx.cwd, false)

    provider =
      Scripted.new([
        fn request ->
          refute request.system =~ "Prior scoped experience"
          Scripted.complete("ordinary result")
        end
      ])

    run(ctx, provider, "Investigate the failing test", false)
    assert {:ok, status} = Loop.inspect(ctx.options.host.state_dir, ctx.cwd)
    refute status["enabled"]
    assert status["retained"] == 0
    assert length(Scripted.requests(provider)) == 1
  end

  defp run(ctx, provider, prompt, interactive) do
    host = Keyword.merge(ctx.host, provider: provider, interactive?: interactive, max_requests: 5)
    assert {:ok, session} = Runtime.start_session(ctx.options, host)
    id = Session.id(session)
    assert :ok = Session.prompt(session, prompt)
    assert_receive {:lemieux, ^id, {:finished, _reason}}
    GenServer.stop(session)
  end
end
