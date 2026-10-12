defmodule Lemieux.Extensions.WorkflowTest do
  use ExUnit.Case, async: true

  alias Lemieux.Conversation.Command.Plan
  alias Lemieux.Conversation.Command.Review
  alias Lemieux.Conversation.Dispatch
  alias Lemieux.Environment.Local
  alias Lemieux.Extensions.Continuation
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Workflow
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.Write

  @moduletag :tmp_dir

  defp start(dir, script) do
    runtime = :"workflow_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new(script)
    {:ok, continuation} = Continuation.init([])

    harness =
      Harness.new(tools: [Write])
      |> Planning.apply([])
      |> Continuation.apply(continuation)
      |> Workflow.apply([])

    store = JSONL.new(Path.join(dir, "sessions"))

    opts = [
      supervisor: runtime,
      provider: provider,
      store: store,
      cwd: dir,
      model: "test:model",
      harness: harness,
      subscriber: self()
    ]

    assert {:ok, session} = Lemieux.start_session(opts)
    {session, provider, opts}
  end

  test "a model cannot write while planning even when the host otherwise allows it", %{
    tmp_dir: dir
  } do
    {session, provider, _opts} =
      start(dir, [
        Scripted.tool_call("edit", "write", %{"path" => "marker", "content" => "unsafe"}),
        Scripted.complete("plan ready")
      ])

    assert {:ok, _document} = Workflow.enter(session, "planning")
    assert {:ok, result} = Lemieux.Testing.prompt(session, "plan")
    refute File.exists?(Path.join(dir, "marker"))

    assert Enum.any?(
             result.entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )

    [request | _] = Scripted.requests(provider)
    refute Enum.any?(request.tools, &(Lemieux.Tool.name(&1) == "write"))
  end

  test "a drafted plan stops at the human handoff despite open obligations", %{tmp_dir: dir} do
    {session, provider, _opts} =
      start(dir, [
        Scripted.tool_call("plan", "todo", %{
          "action" => "set",
          "tasks" => [%{"title" => "Implement", "status" => "pending"}]
        }),
        Scripted.complete("ready for approval")
      ])

    assert {:ok, _document} = Workflow.enter(session, "planning")
    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "draft")
    assert length(Scripted.requests(provider)) == 2
    assert {:ok, %{value: %{"phase" => "planning"}}} = Workflow.read(session)
  end

  test "approval permits progress updates but changed obligations need a new decision", %{
    tmp_dir: dir
  } do
    {session, _provider, _opts} = start(dir, [Scripted.complete("execute")])
    assert {:ok, _document} = Workflow.enter(session, "planning")
    assert {:ok, _plan} = Planning.set(session, [%{"title" => "Fix", "status" => "pending"}])
    assert {:ok, approved} = Workflow.approve(session)
    assert approved.value["plan_revision"] == 1

    assert {:ok, _plan} =
             Planning.set(session, [%{"id" => "t1", "title" => "Fix", "status" => "in_progress"}])

    assert {:ok, _result} = Lemieux.Testing.prompt(session, "execute")

    assert {:ok, _plan} =
             Planning.set(session, [
               %{"id" => "t1", "title" => "Delete everything", "status" => "pending"}
             ])

    assert {:deny, reason} =
             Workflow.prepare(Lemieux.Request.new("test:model"), %{session: session})

    assert reason =~ "approved plan changed"
  end

  test "resume retains review restrictions under the new host", %{tmp_dir: dir} do
    {session, _provider, opts} = start(dir, [])
    assert {:ok, _document} = Workflow.enter(session, "review", %{"target" => "staged"})
    id = Session.id(session)
    GenServer.stop(session)

    provider =
      Scripted.new([
        Scripted.tool_call("edit", "write", %{"path" => "marker", "content" => "unsafe"}),
        Scripted.complete("reviewed")
      ])

    assert {:ok, resumed} =
             Lemieux.resume_session(Keyword.merge(opts, resume: id, provider: provider))

    assert {:ok, _result} = Lemieux.Testing.prompt(resumed, "continue review")
    refute File.exists?(Path.join(dir, "marker"))
    assert {:ok, %{value: %{"phase" => "review"}}} = Workflow.read(resumed)
  end

  test "plan command exports concrete tasks through the confined environment", %{tmp_dir: dir} do
    {session, _provider, _opts} = start(dir, [])
    assert {:ok, _plan} = Planning.set(session, [%{"title" => "Verify", "status" => "pending"}])

    host =
      Dispatch.new(
        session: session,
        say: fn acc, _text -> acc end,
        write: fn acc, _text -> acc end,
        fold: fn acc, _event -> acc end,
        react: fn acc, _event -> acc end,
        cwd: dir,
        environment: Local.new(),
        run: fn acc, work -> [work.() | acc] end
      )

    assert [{:said, message}] = Plan.perform([], host, {:plan, "export plan.md"})
    assert message =~ "exported plan revision 1"
    assert File.read!(Path.join(dir, "plan.md")) =~ "Verify"
    assert [{:said, failure}] = Plan.perform([], host, {:plan, "export ../escaped.md"})
    assert failure =~ "could not change plan"
  end

  test "review selections distinguish staged and working changes and pin commits", %{tmp_dir: dir} do
    git(dir, ["init", "-q"])
    File.write!(Path.join(dir, "file"), "original\n")
    git(dir, ["add", "file"])

    git(dir, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-qm",
      "initial"
    ])

    File.write!(Path.join(dir, "file"), "staged\n")
    git(dir, ["add", "file"])
    File.write!(Path.join(dir, "file"), "working\n")
    assert {:ok, staged} = Review.capture(dir, "staged")
    assert staged["diff"] =~ "+staged"
    refute staged["diff"] =~ "+working"
    assert {:ok, working} = Review.capture(dir, "working")
    assert working["diff"] =~ "+working"
    assert staged["diff_sha256"] != working["diff_sha256"]
    assert {:ok, commit} = Review.capture(dir, "commit HEAD")
    assert commit["diff"] =~ "+original"
    assert {:ok, range} = Review.capture(dir, "range HEAD..HEAD")
    assert range["diff"] == ""
    assert {:error, :unknown_commit} = Review.capture(dir, "commit --output=marker")
    refute File.exists?(Path.join(dir, "marker"))
  end

  test "review findings are schema checked and tied to the selected diff", %{tmp_dir: dir} do
    answer = %{
      "summary" => "One issue",
      "findings" => [
        %{
          "severity" => "P1",
          "file" => "lib/app.ex",
          "line" => 12,
          "explanation" => "Missing validation",
          "evidence" => ["Changed branch accepts unchecked input"]
        }
      ]
    }

    {session, _provider, _opts} = start(dir, [Scripted.complete(JSON.encode!(answer))])

    assert {:ok, _document} =
             Workflow.enter(session, "review", %{
               "target" => "staged",
               "diff_sha256" => "fixture-digest"
             })

    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "review")
    assert {:ok, %{value: report}} = Session.document(session, "lemieux.review_result")
    assert report["status"] == "validated"
    assert report["value"] == answer
    assert report["diff_sha256"] == "fixture-digest"
    assert report["verification"] == "model_reported"
    assert is_binary(report["prompt_id"])
  end

  test "free-form review text is retained as an invalid structured report", %{tmp_dir: dir} do
    {session, provider, _opts} = start(dir, [Scripted.complete("looks good")])
    assert {:ok, _document} = Workflow.enter(session, "review")
    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "review")

    assert {:ok, %{value: %{"status" => "invalid", "reason" => "invalid_json"}}} =
             Session.document(session, "lemieux.review_result")

    assert length(Scripted.requests(provider)) == 1
  end

  test "a model cannot rewrite approved obligations and then execute them in one wave", %{
    tmp_dir: dir
  } do
    {session, provider, _opts} =
      start(dir, [
        Scripted.tool_call("rewrite", "todo", %{
          "action" => "set",
          "tasks" => [%{"id" => "t1", "title" => "Changed obligations", "status" => "pending"}]
        }),
        Scripted.complete("kept original")
      ])

    assert {:ok, _document} = Workflow.enter(session, "planning")
    assert {:ok, _plan} = Planning.set(session, [%{"title" => "Original", "status" => "pending"}])
    assert {:ok, _approval} = Workflow.approve(session)
    assert {:ok, result} = Lemieux.Testing.prompt(session, "execute")

    assert Enum.any?(
             result.entries,
             &(&1.type == :tool_result and &1.payload["outcome"] == "denied")
           )

    assert {:ok, %{value: plan}} = Planning.read(session)
    assert [%{"title" => "Original"}] = Planning.tasks(plan)
    assert length(Scripted.requests(provider)) == 2
  end

  defp git(dir, args) do
    assert {_output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
  end
end
