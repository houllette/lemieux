defmodule Lemieux.Extensions.VerifyChangesTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Checkpoints
  alias Lemieux.Extensions.Verify
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    cwd = Path.join(dir, "work")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "tracked.txt"), "original\n")

    for args <- [["init", "-q"], ["add", "."], ["commit", "-qm", "initial"]] do
      assert {_output, 0} =
               System.cmd(
                 "git",
                 [
                   "-c",
                   "user.name=test",
                   "-c",
                   "user.email=test@example.com",
                   "-c",
                   "commit.gpgsign=false"
                 ] ++ args,
                 cd: cwd,
                 stderr_to_stdout: true
               )
    end

    %{
      runtime: runtime,
      cwd: cwd,
      store: JSONL.new(Path.join(dir, "sessions")),
      checkpoints: Path.join(dir, "checkpoints")
    }
  end

  defp run(ctx, calls, opts \\ []) do
    {:ok, harness} =
      Harness.assemble(Harness.new(), [
        {Checkpoints, dir: ctx.checkpoints, git: true},
        {Verify,
         Keyword.merge(
           [checkpoints: ctx.checkpoints, command: "printf checked >> check.log"],
           opts
         )}
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: Scripted.new(calls ++ [Scripted.complete("Done.")]),
        model: "test:verify",
        cwd: ctx.cwd,
        harness: harness
      )

    assert {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "do the task")
    assert {:ok, status} = Verify.status(session)
    {session, status.last}
  end

  test "shell changes trigger verification even when the command exits nonzero", ctx do
    {_session, last} =
      run(ctx, [
        Scripted.tool_call("shell", "bash", %{"command" => "printf changed > tracked.txt; exit 1"})
      ])

    assert File.read!(Path.join(ctx.cwd, "check.log")) == "checked"
    assert last["status"] == "passed"
    assert [%{"call_id" => "shell", "paths" => ["tracked.txt"]}] = last["changes"]
  end

  test "read-only commands and unchanged writes do not run the check", ctx do
    {_session, last} =
      run(ctx, [
        Scripted.tool_call("read", "bash", %{"command" => "cat tracked.txt"}),
        Scripted.tool_call("seen", "read", %{"path" => "tracked.txt"}),
        Scripted.tool_call("same", "write", %{"path" => "tracked.txt", "content" => "original\n"})
      ])

    refute File.exists?(Path.join(ctx.cwd, "check.log"))
    assert last["status"] == "skipped"
    assert last["reason"] == "no observed workspace changes"
  end

  test "pre-existing dirty files are not attributed to a read-only command", ctx do
    File.write!(Path.join(ctx.cwd, "tracked.txt"), "person's change\n")
    {_session, last} = run(ctx, [Scripted.tool_call("read", "bash", %{"command" => "pwd"})])
    refute File.exists?(Path.join(ctx.cwd, "check.log"))
    assert last["status"] == "skipped"
  end

  test "no discovered command is visible as unavailable", ctx do
    {_session, last} =
      run(
        ctx,
        [
          Scripted.tool_call("write", "write", %{"path" => "new.txt", "content" => "changed"})
        ],
        command: :auto
      )

    assert last["status"] == "unavailable"
    assert last["reason"] == "no verification command configured or discovered"
    assert [%{"paths" => ["new.txt"]}] = last["changes"]
  end

  test "an exact check already passed after shell edits is recorded without repeating it", ctx do
    {_session, last} =
      run(ctx, [
        Scripted.tool_call("edit", "bash", %{"command" => "printf changed > tracked.txt"}),
        Scripted.tool_call("check", "bash", %{"command" => "printf checked >> check.log"})
      ])

    assert File.read!(Path.join(ctx.cwd, "check.log")) == "checked"
    assert last["status"] == "passed"
    assert last["source"] == "model"
  end

  test "a check followed by a mutation is checked again", ctx do
    {_session, last} =
      run(ctx, [
        Scripted.tool_call("check-and-edit", "bash", %{
          "command" => "printf checked >> check.log; printf changed > tracked.txt"
        })
      ])

    assert File.read!(Path.join(ctx.cwd, "check.log")) == "checkedchecked"
    assert last["status"] == "passed"
    refute last["source"] == "model"
  end
end
