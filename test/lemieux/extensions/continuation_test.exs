defmodule Lemieux.Extensions.ContinuationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Extensions
  alias Lemieux.Extensions.Continuation
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Verify
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Session.Aside
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @moduletag :tmp_dir

  describe "init/1" do
    test "rejects options it would silently ignore, and bounds the allowances" do
      assert {:error, message} = Continuation.init(max_continuation: 3)
      assert message =~ "max_continuation"
      assert {:error, _} = Continuation.init(max_continuations: -1)
      assert {:error, _} = Continuation.init(max_output_continuations: 11)
      assert {:error, _} = Continuation.init(enabled: "yes")

      assert {:ok,
              %Continuation{max_continuations: 5, max_output_continuations: 3, enabled: true}} =
               Continuation.init([])
    end

    test "the coding recipe offers it by name, off unless asked, ahead of verify" do
      refute Keyword.has_key?(Extensions.coding("test:model", Scripted.new([])), :continuation)

      recipe =
        Extensions.coding("test:model", Scripted.new([]),
          continuation: [max_continuations: 2],
          verify: true,
          delegate: false
        )

      assert {Continuation, [max_continuations: 2]} = recipe[:continuation]
      # The first stop hook to deny wins, so the order is the policy: a model
      # sent back to its plan is not checked on half-done work.
      assert Keyword.keys(recipe) == [:continuation, :verify]
    end
  end

  describe "in a session" do
    setup %{tmp_dir: tmp_dir} do
      runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
      start_supervised!({Lemieux.Supervisor, name: runtime})
      %{runtime: runtime, store: JSONL.new(tmp_dir), cwd: tmp_dir}
    end

    defp start(ctx, script, opts \\ []) do
      provider = Scripted.new(script)

      {:ok, harness} =
        Harness.assemble(Harness.new(), [Planning, {Continuation, opts}])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: ctx.runtime,
          store: ctx.store,
          provider: provider,
          model: "test:continuation",
          cwd: ctx.cwd,
          subscriber: self(),
          harness: harness
        )

      {session, provider}
    end

    defp run(session, text) do
      id = Session.id(session)
      :ok = Session.prompt(session, text)
      assert_receive {:lemieux, ^id, {:finished, reason}}
      reason
    end

    defp sent_back(session) do
      %{entries: entries} = Session.snapshot(session)

      for %Entry{type: :user} = entry <- entries,
          Transcript.stop_hook?(entry),
          do: entry.payload["text"]
    end

    defp plan(statuses) do
      tasks =
        statuses
        |> Enum.with_index(1)
        |> Enum.map(fn {status, n} -> %{"title" => "step #{n}", "status" => status} end)

      Scripted.tool_call("p#{System.unique_integer([:positive])}", "todo", %{
        "action" => "set",
        "tasks" => tasks
      })
    end

    test "a model that stops with its plan open is sent back to it, and finishes", ctx do
      {session, provider} =
        start(ctx, [
          plan(~w(completed in_progress pending)),
          Scripted.complete("Step 1 is done. Next I'll start on step 2."),
          plan(~w(completed completed completed)),
          Scripted.complete("All three steps are done.")
        ])

      assert run(session, "do the three steps") == :stop
      assert length(Scripted.requests(provider)) == 4

      assert [message] = sent_back(session)
      assert message =~ Continuation.marker()
      assert message =~ "t2 [in_progress] step 2"
      assert message =~ "t3 [pending] step 3"
      refute message =~ "step 1"
      assert message =~ "(Continuation 1 of 5.)"

      # Named first, because live models told "do only the first task, then
      # stop" were carried past it by a message that did not name the case.
      assert message =~
               "If the person asked you to stop at this point, say so in a sentence and " <>
                 "end your turn without calling a tool."
    end

    test "a model that answers without working is believed, and not sent back again", ctx do
      {session, provider} =
        start(ctx, [
          plan(~w(in_progress pending)),
          Scripted.complete("Starting on step 1."),
          Scripted.complete("I need the staging password before step 1 can go further.")
        ])

      assert run(session, "do the steps") == :stop
      assert [_one] = sent_back(session)
      assert length(Scripted.requests(provider)) == 3
    end

    test "the allowance bounds how often one prompt is sent back", ctx do
      {session, provider} =
        start(
          ctx,
          [
            plan(~w(in_progress pending pending)),
            Scripted.complete("Step 1 underway."),
            plan(~w(completed in_progress pending)),
            Scripted.complete("Step 2 underway.")
          ],
          max_continuations: 1
        )

      assert run(session, "do the steps") == :stop
      assert [_one] = sent_back(session)
      assert length(Scripted.requests(provider)) == 4
    end

    test "a plan the model did not touch during this prompt is not this prompt's work", ctx do
      {session, provider} = start(ctx, [Scripted.complete("It parses the config.")])

      # Left open by an earlier task; the person has moved on to a question.
      {:ok, _plan} = Planning.set(session, [%{"title" => "migrate", "status" => "pending"}])

      assert run(session, "what does load/1 do?") == :stop
      assert sent_back(session) == []
      assert length(Scripted.requests(provider)) == 1
    end

    test "a stop with no plan at all is an ordinary stop", ctx do
      {session, provider} = start(ctx, [Scripted.complete("Hello.")])

      assert run(session, "hi") == :stop
      assert sent_back(session) == []
      assert length(Scripted.requests(provider)) == 1
    end

    test "an answer cut off at the output limit is picked up again", ctx do
      {session, provider} =
        start(ctx, [
          Scripted.thinking("The module will be long; writing it now", "",
            finish_reason: :length
          ),
          Scripted.complete("Written.")
        ])

      assert run(session, "write the module") == :stop
      assert [message] = sent_back(session)
      assert message =~ Continuation.output_marker()
      assert message =~ "cut off"
      assert length(Scripted.requests(provider)) == 2
    end

    test "a second cut-off with nothing done in between ends the prompt as it is", ctx do
      {session, provider} =
        start(ctx, [
          Scripted.complete("A very long answer", finish_reason: :length),
          Scripted.complete("The same very long answer", finish_reason: :length)
        ])

      assert run(session, "write the module") == :length
      assert [_one] = sent_back(session)
      assert length(Scripted.requests(provider)) == 2
    end

    test "an aside is never sent back: nobody is waiting on more work from it", ctx do
      {session, provider} =
        start(ctx, [
          plan(~w(completed completed)),
          Scripted.complete("Done."),
          Scripted.complete("The verdict runs past", finish_reason: :length)
        ])

      assert run(session, "do it") == :stop
      id = Session.id(session)

      :ok =
        Session.aside(session, Aside.new(kind: :judge, text: "/judge", system: "Judge the work."))

      assert_receive {:lemieux, ^id, {:finished, :length}}
      assert sent_back(session) == []
      assert length(Scripted.requests(provider)) == 3
    end

    test "turned off, it does nothing", ctx do
      {session, provider} =
        start(
          ctx,
          [plan(~w(in_progress pending)), Scripted.complete("Starting.")],
          enabled: false
        )

      assert run(session, "do the steps") == :stop
      assert sent_back(session) == []
      assert length(Scripted.requests(provider)) == 2
    end

    test "ahead of verify, the plan comes first and the check runs when it is done", ctx do
      provider =
        Scripted.new([
          plan(~w(in_progress pending)),
          Scripted.tool_call("w1", "write", %{"path" => "a.txt", "content" => "a\n"}),
          Scripted.complete("Step 1 written."),
          plan(~w(completed completed)),
          Scripted.complete("Both steps are done."),
          Scripted.complete("The failure was there before I started.")
        ])

      {:ok, harness} =
        Harness.assemble(Harness.new(), [
          Planning,
          Continuation,
          {Verify, command: "echo broken; exit 1"}
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: ctx.runtime,
          store: ctx.store,
          provider: provider,
          model: "test:continuation",
          cwd: ctx.cwd,
          subscriber: self(),
          harness: harness
        )

      assert run(session, "do the steps") == :stop

      assert [plan_message, verify_message] = sent_back(session)
      assert plan_message =~ Continuation.marker()
      assert verify_message =~ Verify.marker()
      assert length(Scripted.requests(provider)) == 6
    end
  end
end
