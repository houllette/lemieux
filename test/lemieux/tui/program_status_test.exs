defmodule Lemieux.TUI.ProgramStatusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Lemieux.TUI.TestSupport

  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.TUI
  alias Lemieux.TUI.Screen

  defp reporting(opts \\ []) do
    owner = self()
    opts = Keyword.merge([test_mode: {80, 24}, id: "status-test", model: "test:model"], opts)

    TUI.new(
      Keyword.put(opts, :program_status, fn status ->
        send(owner, {:status, status})
        :ok
      end)
    )
    |> sized()
  end

  defp metadata_reporting(opts \\ []) do
    owner = self()

    TUI.new(
      Keyword.merge(
        [
          test_mode: {80, 24},
          id: "status-test",
          model: "test:model",
          program_status: fn status, metadata -> send(owner, {:report, status, metadata}) end
        ],
        opts
      )
    )
    |> sized()
  end

  test "session title metadata is opt-in and follows the displayed name without changing status" do
    default = metadata_reporting() |> info({:finished, :stop})
    assert_received {:report, :done, []}
    assert default.terminal.last_program_status == :done

    state = metadata_reporting(program_status_title: true)
    name = Screen.name(state)
    state = put_in(state.conversation.busy?, true) |> info({:text_delta, "working"})
    assert_received {:report, :working, [title: ^name]}
    renamed = %{state | appearance: %{state.appearance | name: "Review: 日本"}}
    assert {:noreply, renamed} = TUI.handle_info(:unrelated, renamed)
    assert_received {:report, :working, [title: "Review: 日本"]}
    assert {:noreply, renamed} = TUI.handle_info(:unrelated, renamed)
    refute_received {:report, _, _}
    renamed = info(renamed, {:finished, :stop})
    assert_received {:report, :done, [title: "Review: 日本"]}
    TUI.terminate(:normal, renamed)
    assert_received {:report, :clear, []}
  end

  test "name commands publish the caption and default restores the session's derived label" do
    state = metadata_reporting(program_status_title: true)
    name = Screen.name(state)
    state = command(state, "/name Review build")
    assert_received {:report, :idle, [title: ^name]}
    assert_received {:report, :idle, [title: "Review build"]}
    state = command(state, "/name default")
    assert_received {:report, :idle, [title: ^name]}
    assert Screen.name(state) == name
  end

  test "one-argument host callbacks keep receiving states without metadata-only repeats" do
    state = reporting(program_status_title: true)
    state = put_in(state.conversation.busy?, true) |> info({:text_delta, "work"})
    assert_received {:status, :working}
    renamed = %{state | appearance: %{state.appearance | name: "Caption"}}
    assert {:noreply, _} = TUI.handle_info(:unrelated, renamed)
    refute_received {:status, _}
  end

  test "switching sessions replaces the metadata label without retaining a caption" do
    state = metadata_reporting(program_status_title: true)
    state = %{state | appearance: %{state.appearance | name: "Old caption"}}
    state = info(state, {:finished, :stop})
    assert_received {:report, :done, [title: "Old caption"]}
    next = %{state | id: "other-session", appearance: %{state.appearance | name: nil}}
    name = Screen.name(next)
    assert {:noreply, next} = TUI.ProgramStatus.transition({:noreply, next}, state, :switched)
    assert_received {:report, :idle, [title: ^name]}
    assert next.terminal.last_program_status_title == name
  end

  test "mount reports idle and ticks and redraws do not repeat reports" do
    owner = self()

    assert {:ok, state} =
             TUI.mount(test_mode: {80, 24}, program_status: fn s -> send(owner, {:status, s}) end)

    assert_received {:status, :idle}
    state = info(state, {:text_delta, ""})
    TUI.render(state, %ExRatatui.Frame{width: 80, height: 24})
    refute_received {:status, _}
  end

  test "work, permission, question, completion and acknowledgement follow session state" do
    state = reporting() |> put_in([Access.key!(:conversation), Access.key!(:busy?)], true)
    state = info(state, {:text_delta, "working"})
    assert_received {:status, :working}
    state = info(state, {:tool_approval, %{id: "a", name: "bash", arguments: %{}}})
    assert_received {:status, {:blocked, :permission}}
    state = info(state, {:tool_approval, %{id: "b", name: "write", arguments: %{}}})
    state = info(state, {:approval_result, "a", :ok})
    refute_received {:status, :working}
    state = info(state, {:approval_result, "b", :ok})
    assert_received {:status, :working}
    state = info(state, {:question, %{call_id: "q", question: "Which one?", options: []}})
    assert_received {:status, {:blocked, :question}}

    state =
      info(
        state,
        {:entry,
         %{
           type: :approval,
           payload: %{"kind" => "question", "call_id" => "q", "status" => "answered"}
         }}
      )

    assert_received {:status, :working}
    state = info(state, {:finished, :stop})
    assert_received {:status, :done}
    state = info(state, {:usage, %{}})
    assert state.terminal.last_program_status == :done
    refute_received {:status, _}
    press(state, "x")
    assert_received {:status, :idle}
  end

  test "cancellation reports idle, failure reports error, and retries report working" do
    state = reporting() |> info({:finished, :cancelled})
    assert_received {:status, :idle}
    state = info(state, {:finished, :max_turns})
    assert_received {:status, :error}
    state = put_in(state.conversation.busy?, true)
    info(state, {:text_delta, "retry"})
    assert_received {:status, :working}
  end

  test "foreign session events cannot change completion state" do
    state = reporting() |> info({:finished, :stop})
    assert_received {:status, :done}
    assert {:noreply, _} = TUI.handle_info({:lemieux, "other", {:finished, :max_turns}}, state)
    refute_received {:status, _}
  end

  test "normal shutdown clears status and an abnormal shutdown leaves error" do
    state = reporting()
    TUI.terminate(:normal, state)
    assert_received {:status, :clear}
    TUI.terminate(:unexpected, state)
    assert_received {:status, :error}
  end

  test "headless screens emit nothing and notification settings do not mute status" do
    assert capture_io(fn ->
             assert {:ok, state} = TUI.mount(test_mode: {80, 24})
             info(state, {:finished, :stop})
             TUI.terminate(:normal, state)
           end) == ""

    reporting(notifications: false) |> info({:finished, :stop})
    assert_received {:status, :done}
  end

  test "session failure, startup failure and credential setup report their actual states" do
    state = reporting()
    failed = put_in(state.resume.startup_status, :failed)
    assert {:noreply, _} = TUI.handle_info(:unrelated, failed)
    assert_received {:status, :error}
    stopped = put_in(state.resume.down, :unexpected)
    assert {:noreply, _} = TUI.handle_info(:unrelated, stopped)
    assert_received {:status, :error}
    setup = %{failed | modal: %{kind: :first_run}}
    assert {:noreply, _} = TUI.handle_info(:unrelated, setup)
    assert_received {:status, {:blocked, :auth}}
  end

  test "changing sessions clears the old completion and preserves callback options" do
    state = reporting() |> info({:finished, :stop})
    assert_received {:status, :done}
    next = %{state | id: "new-session"}

    assert {:noreply, next, render?: false} =
             TUI.ProgramStatus.transition({:noreply, next, render?: false}, state, :switched)

    assert next.terminal.last_program_status == :idle
    assert_received {:status, :idle}
  end

  @tag :tmp_dir
  test "attaching to a parked session reports its pending approval immediately", %{tmp_dir: tmp} do
    owner = self()
    runtime = :"osc7501_restore_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        provider:
          Scripted.new([
            [
              {:tool_call, %{id: "echo-1", name: "echo", arguments: %{"say" => "hello"}}},
              {:done, :tool_calls}
            ]
          ]),
        store: JSONL.new(tmp),
        model: "test:model",
        subscriber: self(),
        tools: [Lemieux.TUITest.Echo],
        hooks: [before_tool_call: fn _, _ -> :pending end]
      )

    :ok = Lemieux.Session.prompt(session, "go")
    assert_receive {:lemieux, _, {:tool_approval, _}}

    assert {:ok, state} =
             TUI.mount(
               test_mode: {80, 24},
               start: fn -> {:ok, session} end,
               program_status: fn status -> send(owner, {:status, status}) end
             )

    assert_received {:status, {:blocked, :permission}}
    assert length(state.conversation.approvals) == 1
    Lemieux.Session.cancel(session)
    assert_receive {:lemieux, _, {:finished, :cancelled}}
    TUI.terminate(:normal, state)
    Lemieux.CLI.Runtime.stop_session(session)
  end

  @tag :tmp_dir
  test "the real runtime reports a scripted turn and clears when closed", %{tmp_dir: tmp} do
    owner = self()
    runtime = :"osc7501_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    start = fn ->
      Lemieux.start_session(
        supervisor: runtime,
        provider: Scripted.new([[{:text_delta, "done"}, {:done, :stop}]]),
        store: JSONL.new(tmp),
        model: "test:model",
        subscriber: self()
      )
    end

    {:ok, app} =
      TUI.start_link(
        name: nil,
        test_mode: {80, 24},
        start: start,
        program_status: fn status -> send(owner, {:status, status}) end
      )

    assert_receive {:status, :idle}
    ExRatatui.Runtime.inject_event(app, key("g"))
    ExRatatui.Runtime.inject_event(app, key("o"))
    ExRatatui.Runtime.inject_event(app, key("enter"))
    assert_receive {:status, :working}
    assert_receive {:status, :done}
    %{user_state: state} = :sys.get_state(app)
    assert state.conversation.busy? == false
    GenServer.stop(app)
    assert_receive {:status, :clear}
    Lemieux.CLI.Runtime.stop_session(state.session)
  end
end
