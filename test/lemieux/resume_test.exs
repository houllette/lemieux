defmodule Lemieux.ResumeTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_resume_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self()
        ] ++ opts
      )

    {session, provider}
  end

  defp resume(context, id, script, opts \\ []) do
    provider = Scripted.new(script)

    result =
      Lemieux.resume_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          resume: id
        ] ++ opts
      )

    {result, provider}
  end

  # Ends a session so its id is free to be resumed under: the registry holds
  # one process per id, which is the point.
  defp converse_and_stop(context, script, prompt, opts \\ []) do
    {session, _provider} = start_session(context, script, opts)
    id = Session.id(session)

    :ok = Session.prompt(session, prompt)
    assert_receive {:lemieux, ^id, {:finished, _}}

    :ok =
      DynamicSupervisor.terminate_child(
        Lemieux.Supervisor.session_supervisor(context.runtime),
        session
      )

    # The registry drops its entry when it sees the process die, which is one
    # message later than terminate_child returning. Resuming under the same id
    # would collide until it does.
    LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

    id
  end

  describe "resume_session/1" do
    test "the first request carries the conversation as it was left", context do
      id =
        converse_and_stop(context, [[{:text_delta, "the first answer"}, {:done, :stop}]], "hello")

      {{:ok, session}, provider} = resume(context, id, [[{:done, :stop}]])

      :ok = Session.prompt(session, "and now?")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [%Request{entries: entries}] = Scripted.requests(provider)

      # Everything that happened before, plus the new prompt: the model is
      # given the conversation, not a summary of it and not a provider's id.
      assert Enum.map(entries, & &1.type) == [:session, :user, :request, :assistant, :user]
      assert Enum.at(entries, 1).payload == %{"text" => "hello"}
      assert List.last(entries).payload == %{"text" => "and now?"}
    end

    test "a resumed session keeps its id and appends to the same transcript", context do
      id = converse_and_stop(context, [[{:text_delta, "one"}, {:done, :stop}]], "hello")

      {{:ok, session}, _provider} = resume(context, id, [[{:text_delta, "two"}, {:done, :stop}]])

      assert Session.id(session) == id

      :ok = Session.prompt(session, "again")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, id)

      assert Enum.map(entries, & &1.type) == [
               :session,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :run_evidence,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :run_evidence
             ]
    end

    test "safe generation parameters survive resume", context do
      id =
        converse_and_stop(
          context,
          [[{:done, :stop}]],
          "hello",
          params: [temperature: 0.25, max_tokens: 321, api_key: "do-not-record"]
        )

      {{:ok, session}, provider} = resume(context, id, [[{:done, :stop}]])
      :ok = Session.prompt(session, "again")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [%Request{params: params}] = Scripted.requests(provider)
      assert params[:temperature] == 0.25
      assert params[:max_tokens] == 321
      refute Keyword.has_key?(params, :api_key)
    end

    test "resuming a session that was never written says so", context do
      assert {{:error, :not_found}, _provider} = resume(context, "nope", [])
    end

    test "the transcript a resume reads is the one on disk, not one in memory", context do
      id = converse_and_stop(context, [[{:text_delta, "answer"}, {:done, :stop}]], "hello")

      # Nothing but the store connects the two: the first session's process is
      # gone by now.
      assert Lemieux.session(context.runtime, id) == :error

      {{:ok, session}, _provider} = resume(context, id, [[{:done, :stop}]])

      assert Enum.map(Session.snapshot(session).entries, & &1.type) == [
               :session,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :run_evidence
             ]
    end
  end

  describe "a forked session" do
    test "continues from the cut point, and leaves the original alone", context do
      id =
        converse_and_stop(
          context,
          [[{:text_delta, "the original answer"}, {:done, :stop}]],
          "hello"
        )

      assert {:ok, original} = Store.read(context.store, id)
      first_answer = Enum.find(original, &(&1.type == :assistant))
      assert {:ok, forked} = Transcript.fork(context.store, id, first_answer.id)

      {{:ok, session}, provider} = resume(context, forked, [[{:done, :stop}]])

      :ok = Session.prompt(session, "a different second question")
      assert_receive {:lemieux, ^forked, {:finished, :stop}}

      # The fork saw the first exchange's user turn and nothing after it. The
      # marker is in the transcript because it is part of the record; it is not
      # in the conversation, which the provider's own test covers.
      assert [%Request{entries: entries}] = Scripted.requests(provider)

      assert Enum.map(entries, & &1.type) == [
               :session,
               :user,
               :request,
               :assistant,
               :fork,
               :user
             ]

      # And the original still ends where it ended.
      assert Enum.map(original, & &1.type) == [
               :session,
               :user,
               :harness_snapshot,
               :request,
               :assistant,
               :run_evidence
             ]
    end
  end

  # The transcript is the durable contract, and `docs/transcript-compatibility.md`
  # is the promise: a reader rejects what it does not understand rather than
  # dropping it. These pin the two halves of that promise that a person
  # actually meets — a transcript from an older build still resumes, and one
  # from a build that is not this one fails as a sentence rather than as a
  # stacktrace.
  describe "a transcript written by a different build" do
    test "resumes when its schema version is one this build reads", context do
      # Written by hand rather than by a session, which is the point: this is
      # the on-disk shape as of schema version 1, and a change that stops it
      # resuming is a change that strands everybody's history.
      id = "01ANCIENTSESSION"

      write_lines(context, id, [
        ~s({"v":1,"id":"01A","parent_id":null,"seq":0,"type":"session",) <>
          ~s("payload":{"model":"test:model","system":null,"tools":[],) <>
          ~s("disabled_tools":[],"mcp_servers":[],"params":{},"reasoning_effort":null},) <>
          ~s("usage":null,"meta":{},"at":"2026-01-01T00:00:00Z"}),
        ~s({"v":1,"id":"01B","parent_id":"01A","seq":1,"type":"user",) <>
          ~s("payload":{"text":"from an older lmx"},"usage":null,"meta":{},) <>
          ~s("at":"2026-01-01T00:00:01Z"})
      ])

      {{:ok, session}, provider} = resume(context, id, [[{:done, :stop}]])

      :ok = Session.prompt(session, "and now?")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [%Request{entries: entries}] = Scripted.requests(provider)
      texts = for entry <- entries, entry.type == :user, do: entry.payload["text"]
      assert texts == ["from an older lmx", "and now?"]
    end

    # Not a hypothetical: one machine on a newer `lmx`, the sessions directory
    # shared or synced, and the older build asked to resume. It must say which
    # build to go back to, and it must leave the file exactly as it found it.
    test "is refused with a readable reason, not a crash", context do
      id = "01FROMTHEFUTURE"

      write_lines(context, id, [
        ~s({"v":99,"id":"01A","parent_id":null,"seq":0,"type":"user",) <>
          ~s("payload":{"text":"hi"},"usage":null,"meta":{},) <>
          ~s("at":"2026-01-01T00:00:00Z"})
      ])

      assert {:error, {:unreadable, ^id, reason}} =
               Store.read(context.store, id)

      assert reason =~ "99"

      assert {{:error, {:unreadable, ^id, _reason}}, _provider} =
               resume(context, id, [[{:done, :stop}]])

      said = Lemieux.Conversation.describe({:unreadable, id, reason})
      assert said =~ "different version"
      assert said =~ "intact"
    end

    test "an entry type this build does not know is refused rather than skipped", context do
      id = "01UNKNOWNTYPE"

      write_lines(context, id, [
        ~s({"v":1,"id":"01A","parent_id":null,"seq":0,"type":"telepathy",) <>
          ~s("payload":{},"usage":null,"meta":{},"at":"2026-01-01T00:00:00Z"})
      ])

      assert {:error, {:unreadable, ^id, reason}} = Store.read(context.store, id)
      assert reason =~ "telepathy"
    end
  end

  defp write_lines(context, id, lines) do
    {JSONL, %{dir: dir}} = context.store

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, id <> ".jsonl"), Enum.map(lines, &[&1, ?\n]))
  end
end
