defmodule Lemieux.Tools.DeferredQuestionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Clock
  alias Lemieux.Clock.Manual
  alias Lemieux.Conversation
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools.AskUser
  alias Lemieux.Transcript
  alias Lemieux.TUI.QuestionFlow

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir)}
  end

  defp entries(session), do: Session.snapshot(session).entries

  defp question(id \\ "ask") do
    %{
      id: id,
      name: "ask_user",
      arguments: %{
        "mode" => "deferred",
        "questions" => [%{"id" => "name", "question" => "Preferred name?", "type" => "text"}]
      }
    }
  end

  defp start(context, script, opts \\ []) do
    provider = Scripted.new(script)

    opts =
      Keyword.merge(
        [
          supervisor: context.runtime,
          store: context.store,
          model: "test:model",
          tools: [AskUser],
          subscriber: self(),
          provider: provider
        ],
        opts
      )

    {:ok, session} = Lemieux.start_session(opts)
    :ok = Session.prompt(session, "Work independently")
    {session, provider, Session.id(session)}
  end

  test "continues before an answer, pairs the tool result, delivers a busy answer exactly once",
       ctx do
    owner = self()

    {session, provider, id} =
      start(ctx, [
        [{:tool_call, question()}, {:done, :tool_calls}],
        fn request ->
          send(owner, {:independent_work, self(), request})

          receive do
            :finish -> Scripted.complete("Independent investigation complete")
          end
        end,
        Scripted.complete("Answer incorporated")
      ])

    assert_receive {:lemieux, ^id, {:question, %{call_id: question_id, deferred: true}}}
    assert_receive {:independent_work, task, request}
    result = Enum.find(request.entries, &(&1.type == :tool_result))
    assert result.payload["call_id"] == "ask"
    assert JSON.decode!(result.payload["output"])["question_id"] == question_id
    assert :ok = Session.answer(session, question_id, %{"answers" => [%{"text" => "Widget"}]})
    assert {:error, :unknown_call} = Session.answer(session, question_id, "duplicate")
    send(task, :finish)
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 3

    answers =
      Enum.filter(
        entries(session),
        &(&1.type == :user and &1.payload["source"] == "question_answer")
      )

    assert [answer] = answers
    assert answer.payload["question_id"] == question_id
    assert answer.payload["text"] =~ "Widget"
    assert Session.snapshot(session).pending == []
  end

  test "idle answer waits for an explicit prompt and survives resume without another delivery",
       ctx do
    {session, provider, id} =
      start(ctx, [
        [{:tool_call, question()}, {:done, :tool_calls}],
        Scripted.complete("Independent work finished"),
        Scripted.complete("Continued")
      ])

    assert_receive {:lemieux, ^id, {:question, %{call_id: qid}}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert :ok = Session.answer(session, qid, "Widget")
    assert length(Scripted.requests(provider)) == 2
    assert :ok = Session.prompt(session, "Continue with the answer")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert Enum.count(entries(session), &(&1.payload["source"] == "question_answer")) == 1
    :ok = GenServer.stop(session)

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        resume: id,
        provider: Scripted.new([Scripted.complete("Resumed")]),
        subscriber: self(),
        tools: [AskUser]
      )

    assert Session.snapshot(resumed).pending == []
    assert :ok = Session.prompt(resumed, "Again")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert Enum.count(entries(resumed), &(&1.payload["source"] == "question_answer")) == 1
  end

  test "restores a pending question, bounds new batches and rejects answers after cancellation",
       ctx do
    {session, _provider, id} =
      start(ctx, [[{:tool_call, question()}, {:done, :tool_calls}], Scripted.complete("Done")])

    assert_receive {:lemieux, ^id, {:question, %{call_id: qid}}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    :ok = GenServer.stop(session)

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        resume: id,
        provider:
          Scripted.new([
            [{:tool_call, question("ask-again")}, {:done, :tool_calls}],
            Scripted.complete("Done")
          ]),
        subscriber: self(),
        tools: [AskUser]
      )

    assert [%{call_id: ^qid, payload: %{deferred: true}}] = Session.snapshot(resumed).pending
    :ok = Session.prompt(resumed, "More independent work")
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    assert List.last(Enum.filter(entries(resumed), &(&1.type == :tool_result))).payload[
             "output"
           ] =~ "another question"

    :ok = Session.cancel(resumed)
    assert {:error, :unknown_call} = Session.answer(resumed, qid, "late")
    assert Session.snapshot(resumed).pending == []
  end

  test "expiration closes optional attention without polling the provider", ctx do
    clock = start_supervised!({Manual, []})

    {session, provider, id} =
      start(ctx, [[{:tool_call, question()}, {:done, :tool_calls}], Scripted.complete("Done")],
        approval_timeout: 60_000,
        clock: clock
      )

    assert_receive {:lemieux, ^id, {:question, %{call_id: qid}}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    Manual.advance(clock, 60_000, settle: session)

    assert_receive {:lemieux, ^id,
                    {:entry,
                     %{type: :approval, payload: %{"call_id" => ^qid, "status" => "timed_out"}}}}

    assert {:error, :unknown_call} = Session.answer(session, qid, "late")
    assert length(Scripted.requests(provider)) == 2
  end

  test "a reply after the durable deadline is refused even before its timeout message runs",
       ctx do
    {session, _provider, id} =
      start(ctx, [
        [{:tool_call, question()}, {:done, :tool_calls}],
        Scripted.complete("Done"),
        Scripted.complete("Continued")
      ])

    assert_receive {:lemieux, ^id, {:question, %{call_id: qid}}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}

    :sys.replace_state(session, fn state ->
      put_in(state.deferred_question.deadline, Clock.now_ms(state.clock) - 1)
    end)

    assert {:error, :unknown_call} = Session.answer(session, qid, "too late")
    assert Session.snapshot(session).pending == []
    :ok = Session.prompt(session, "Continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert [answer] = Enum.filter(entries(session), &(&1.payload["source"] == "question_answer"))
    assert answer.payload["text"] =~ "timed_out"
    refute answer.payload["text"] =~ "too late"
  end

  test "a queued idle answer is restored, while a fork inherits no pending attention", ctx do
    {session, _provider, id} =
      start(ctx, [[{:tool_call, question()}, {:done, :tool_calls}], Scripted.complete("Done")])

    assert_receive {:lemieux, ^id, {:question, %{call_id: qid}}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    {:ok, fork_id} = Transcript.fork(ctx.store, id)

    {:ok, forked} =
      Lemieux.resume_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        resume: fork_id,
        provider: Scripted.new([]),
        subscriber: self(),
        tools: [AskUser]
      )

    assert Session.snapshot(forked).pending == []
    assert {:error, :invalid_answer} = Session.answer(session, qid, String.duplicate("x", 33_000))
    assert :ok = Session.answer(session, qid, "Persisted answer")
    :ok = GenServer.stop(session)
    provider = Scripted.new([Scripted.complete("Resumed")])

    {:ok, resumed} =
      Lemieux.resume_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        resume: id,
        provider: provider,
        subscriber: self(),
        tools: [AskUser]
      )

    assert Scripted.requests(provider) == []
    :ok = Session.prompt(resumed, "Continue")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert [entry] = Enum.filter(entries(resumed), &(&1.payload["source"] == "question_answer"))
    assert entry.payload["text"] =~ "Persisted answer"
  end

  test "turn completion retains an optional question in the conversation and panel" do
    question = %{call_id: "optional", question: "Name?", options: [], deferred: true}
    conversation = Conversation.new(model: "test:model")
    {conversation, _} = Conversation.event(conversation, {:question, question})
    {conversation, _} = Conversation.event(conversation, {:finished, :stop})
    assert conversation.asking == "optional"
    assert QuestionFlow.new(question, "draft").deferred?

    {conversation, _} =
      Conversation.event(
        conversation,
        {:entry,
         %{
           type: :approval,
           payload: %{"kind" => "question", "status" => "cancelled", "call_id" => "optional"}
         }}
      )

    assert conversation.asking == nil
  end
end
