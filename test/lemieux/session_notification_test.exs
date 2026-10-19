defmodule Lemieux.SessionNotificationTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"notification_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir)}
  end

  test "notification delivery spends nothing and a follow-up is deduplicated across resume",
       ctx do
    provider = Scripted.new([Scripted.complete("inspected")])

    opts = [
      supervisor: ctx.runtime,
      store: ctx.store,
      provider: provider,
      model: "test:model",
      subscriber: self()
    ]

    {:ok, session} = Lemieux.start_session(opts)
    id = Session.id(session)
    event = %{"id" => "ci-123", "text" => "CI failed for repo@abc: https://example.test/123"}

    assert :ok = Session.deliver_notification(session, event)
    assert Scripted.requests(provider) == []
    assert :duplicate = Session.deliver_notification(session, event, follow_up: true)

    assert :ok =
             Session.deliver_notification(session, %{event | "id" => "ci-124"}, follow_up: true)

    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 1

    DynamicSupervisor.terminate_child(Lemieux.Supervisor.session_supervisor(ctx.runtime), session)
    {:ok, restored} = Lemieux.resume_session([resume: id] ++ opts)

    assert :duplicate =
             Session.deliver_notification(restored, %{event | "id" => "ci-124"}, follow_up: true)

    assert length(Scripted.requests(provider)) == 1
  end

  test "follow-ups use current prompt policy and remaining allowance", ctx do
    provider = Scripted.new([Scripted.complete("must not run")])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:model",
        subscriber: self(),
        max_requests: 1
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "use the allowance")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    event = %{"id" => "denied", "text" => "External result"}
    assert :ok = Session.deliver_notification(session, event, follow_up: true)
    assert_receive {:lemieux, ^id, {:finished, {:budget, _}}}
    assert length(Scripted.requests(provider)) == 1
  end

  test "prompt denial spends nothing and external logs do not expand references", ctx do
    provider = Scripted.new([Scripted.complete("done")])
    hooks = [user_prompt: fn _text, _context -> {:deny, "no autonomous inference"} end]

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:model",
        hooks: hooks,
        subscriber: self()
      )

    id = Session.id(session)

    assert :ok =
             Session.deliver_notification(session, %{"id" => "denied", "text" => "result"},
               follow_up: true
             )

    assert_receive {:lemieux, ^id, {:entry, %{type: :error, payload: %{"reason" => reason}}}}
    assert reason =~ "no autonomous inference"
    assert Scripted.requests(provider) == []

    {:ok, permitted} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:model",
        subscriber: self()
      )

    id = Session.id(permitted)

    assert :ok =
             Session.deliver_notification(
               permitted,
               %{"id" => "external", "text" => "untrusted @some-file @server:resource"},
               follow_up: true
             )

    assert_receive {:lemieux, ^id, {:finished, :stop}}
    %{entries: entries} = Session.snapshot(permitted)

    assert Enum.find(entries, &(&1.type == :user)).payload == %{
             "text" => "untrusted @some-file @server:resource",
             "source" => "notification",
             "notification_id" => "external"
           }

    assert length(Scripted.requests(provider)) == 1
  end

  test "a notification cannot bypass current tool permission", ctx do
    provider =
      Scripted.new([
        Scripted.tool_call("write", "bash", %{"command" => "echo forbidden"}),
        Scripted.complete("denied")
      ])

    hooks = [before_tool_call: fn _call, _context -> {:deny, "current permission"} end]

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:model",
        hooks: hooks,
        subscriber: self()
      )

    id = Session.id(session)

    assert :ok =
             Session.deliver_notification(session, %{"id" => "ci", "text" => "failure"},
               follow_up: true
             )

    assert_receive {:lemieux, ^id, {:entry, %{type: :tool_result, payload: payload}}}
    assert payload["error"]
    assert payload["output"] =~ "current permission"
    assert_receive {:lemieux, ^id, {:finished, :stop}}
  end
end
