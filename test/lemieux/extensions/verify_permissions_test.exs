defmodule Lemieux.Extensions.VerifyPermissionsTest do
  # The check after edits is the project's own command — `tests/run.sh`,
  # `make test`, `npm test` — and a repository decides what that runs. It used
  # to run unasked in every permission mode, past a `Bash` deny rule that
  # refused the same command typed by the model. It now meets the session's
  # policy as a `bash` call would.
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Extensions.Verify
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    cwd = Path.join(tmp_dir, "work")
    File.mkdir_p!(cwd)
    %{runtime: runtime, cwd: cwd, store: JSONL.new(tmp_dir), marker: Path.join(cwd, "CHECK_RAN")}
  end

  defp start(ctx, extensions) do
    provider =
      Scripted.new([
        Scripted.tool_call("w1", "write", %{"path" => "notes.txt", "content" => "hello\n"}),
        Scripted.complete("Done.")
      ])

    {:ok, harness} = Harness.assemble(Harness.new(), extensions)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:verify",
        cwd: ctx.cwd,
        subscriber: self(),
        harness: harness
      )

    {session, provider}
  end

  defp verify(ctx), do: {Verify, command: "touch #{ctx.marker}", cwd: ctx.cwd}

  defp finish(session) do
    id = Session.id(session)
    assert_receive {:lemieux, ^id, {:finished, reason}}, 10_000
    reason
  end

  defp verify_messages(session) do
    %{entries: entries} = Session.snapshot(session)

    for %Entry{type: :user, payload: %{"text" => text}} <- entries,
        String.starts_with?(text, Verify.marker()),
        do: text
  end

  test "with no permission policy the check runs, as it always has", ctx do
    {session, _provider} = start(ctx, [verify(ctx)])

    :ok = Session.prompt(session, "write the file")
    assert finish(session) == :stop

    assert File.exists?(ctx.marker)
    assert {:ok, %{last: %{"status" => "passed"}}} = Verify.status(session)
  end

  test "accept_edits with a Bash deny rule refuses the check like any other command", ctx do
    {session, provider} =
      start(ctx, [
        {Permissions, mode: :accept_edits, deny: ["Bash(touch:*)"]},
        verify(ctx)
      ])

    :ok = Session.prompt(session, "write the file")
    assert finish(session) == :stop

    # The edit went through — accept_edits lets edits run — and the check did not.
    assert File.read!(Path.join(ctx.cwd, "notes.txt")) == "hello\n"
    refute File.exists?(ctx.marker)

    assert {:ok, %{last: %{"status" => "denied", "reason" => reason}}} = Verify.status(session)
    assert reason =~ "Bash(touch:*)"

    # Nothing for the model to fix: the turn ends without another request.
    assert verify_messages(session) == []
    assert length(Scripted.requests(provider)) == 2
  end

  test "the policy applies whichever extension was applied first", ctx do
    {session, _provider} =
      start(ctx, [
        verify(ctx),
        {Permissions, mode: :accept_edits, deny: ["Bash"]}
      ])

    :ok = Session.prompt(session, "write the file")
    assert finish(session) == :stop

    refute File.exists?(ctx.marker)
    assert {:ok, %{last: %{"status" => "denied"}}} = Verify.status(session)
  end

  test "a check the policy would ask about is put to the person, and runs once allowed", ctx do
    {session, _provider} = start(ctx, [{Permissions, mode: :accept_edits}, verify(ctx)])

    :ok = Session.prompt(session, "write the file")

    assert_receive {:lemieux, _id,
                    {:tool_approval,
                     %{id: call_id, name: "bash", arguments: %{"command" => command}}}},
                   10_000

    assert command == "touch #{ctx.marker}"
    refute File.exists?(ctx.marker)

    assert Session.resolve_tool(session, call_id, :allow) == :ok
    assert finish(session) == :stop

    assert File.exists?(ctx.marker)
    assert {:ok, %{last: %{"status" => "passed"}}} = Verify.status(session)
  end

  test "with nobody to ask, as in `lmx run`, a check that would ask is refused", ctx do
    {session, _provider} =
      start(ctx, [{Permissions, mode: :accept_edits, non_interactive: :deny}, verify(ctx)])

    :ok = Session.prompt(session, "write the file")
    assert finish(session) == :stop

    refute File.exists?(ctx.marker)
    assert {:ok, %{last: %{"status" => "denied", "reason" => reason}}} = Verify.status(session)
    assert reason =~ "nobody can approve"
  end

  test "an allow rule for the command lets it run unasked", ctx do
    {session, _provider} =
      start(ctx, [
        {Permissions, mode: :accept_edits, allow: ["Bash(touch:*)"]},
        verify(ctx)
      ])

    :ok = Session.prompt(session, "write the file")
    assert finish(session) == :stop

    assert File.exists?(ctx.marker)
  end
end
