defmodule Lemieux.TUI.InitialPromptTest do
  # A host's `:prompt` — `lmx --prompt TEXT` — is the sitting's first
  # message: staged while the session starts, sent once it is up, and held
  # until the questions a sitting opens with are answered, so it reaches the
  # provider and the MCP servers the person chose rather than racing them.
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI
  alias Lemieux.TUI.History

  # A screen whose session starts when the test says so, with `ready`
  # as the options the host's preparation answers with.
  defp starting(ready, opts) do
    {:ok, tasks} = Task.Supervisor.start_link()
    session = fake_session(snapshot("02FIRSTPROMPT"))

    start = fn _app ->
      receive do
        :go -> {:ok, session, ready}
      end
    end

    {:ok, app} =
      TUI.start_link(
        [test_mode: {80, 24}, name: nil, start_async: start, task_supervisor: tasks] ++ opts
      )

    loading = :sys.get_state(app).user_state
    %{app: app, task: loading.resume.initial_task.pid, loading: loading}
  end

  defp up(%{app: app, task: task}) do
    send(task, :go)
    :ok = LemieuxTest.Sync.state(app, &(&1.user_state.id == "02FIRSTPROMPT"))
    :sys.get_state(app).user_state
  end

  defp inject(app, keys), do: Enum.each(keys, &ExRatatui.Runtime.inject_event(app, key(&1)))

  # The first of the two the session reported, which is the one it was
  # asked for first: both come from the one stand-in process, in order.
  defp first_of(a, b) do
    receive do
      {^a, _value} = message -> message
      {^b, _value} = message -> message
    end
  end

  test "is staged while the session starts, and sent, echoed, once it is up" do
    screen = starting([], prompt: "fix the failing test")

    assert screen.loading.history.queued == ["fix the failing test"]
    refute_receive {:prompted, _text}, 100

    ready = up(screen)

    assert_receive {:prompted, "fix the failing test"}
    state = :sys.get_state(screen.app).user_state
    assert state.history.queued == []
    assert ready.id == "02FIRSTPROMPT"
    # The Go Habs Go banner is still playing out over the ready screen
    # (`Lemieux.TUI.Lifecycle.start_habs/1`); the echo is underneath it.
    assert screen(%{state | overlay: nil}) =~ "fix the failing test"
    assert "fix the failing test" in state.history.entries
  end

  # Typing ahead used to be dropped as the session came up: hydrating the
  # session rebuilt the history, queue and all.
  test "what was typed while it started goes after it, in order" do
    screen = starting([], prompt: "first")

    inject(screen.app, ~w(t h e n enter))
    assert :sys.get_state(screen.app).user_state.history.queued == ["first", "then"]

    up(screen)
    assert_receive {:prompted, "first"}
    refute_receive {:prompted, "then"}, 100

    send(screen.app, {:lemieux, "02FIRSTPROMPT", {:finished, :stop}})
    assert_receive {:prompted, "then"}
  end

  test "waits for the provider setup, and goes to the model chosen there" do
    local = %{id: "local", label: "Local", model: "ollama:small", key?: false}
    screen = starting([first_run: %{providers: [local], config_path: nil}], prompt: "hello")

    state = up(screen)
    assert %{kind: :first_run} = state.modal
    refute_receive {:prompted, _text}, 100

    inject(screen.app, ~w(down enter))

    assert {:set_model, "ollama:small"} = first_of(:set_model, :prompted)
    assert_receive {:prompted, "hello"}
  end

  test "goes once the provider setup is skipped" do
    local = %{id: "local", label: "Local", model: "ollama:small", key?: false}
    screen = starting([first_run: %{providers: [local], config_path: nil}], prompt: "hello")

    up(screen)
    refute_receive {:prompted, _text}, 100

    inject(screen.app, ["esc"])
    assert_receive {:prompted, "hello"}
  end

  describe "a repository's MCP servers" do
    @describetag :tmp_dir

    defp repository(dir) do
      repo = Path.join(dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))

      File.write!(
        Path.join(repo, ".mcp.json"),
        ~s({"mcpServers":{"docs":{"command":"docs-server"}}})
      )

      %{store: Path.join(dir, "trust"), cwd: repo}
    end

    test "trusted, they start before it is sent", %{tmp_dir: dir} do
      screen = starting([mcp_trust: repository(dir)], prompt: "use the docs")

      up(screen)
      :ok = LemieuxTest.Sync.state(screen.app, &match?(%{kind: :trust}, &1.user_state.modal))
      refute_receive {:prompted, _text}, 100

      inject(screen.app, ["1"])

      assert {:added_mcp, [%{"name" => "docs"}]} = first_of(:added_mcp, :prompted)
      assert_receive {:prompted, "use the docs"}
    end

    test "put off with Not now, it is sent at once", %{tmp_dir: dir} do
      screen = starting([mcp_trust: repository(dir)], prompt: "use the docs")

      up(screen)
      :ok = LemieuxTest.Sync.state(screen.app, &match?(%{kind: :trust}, &1.user_state.modal))
      refute_receive {:prompted, _text}, 100

      inject(screen.app, ["3"])
      assert_receive {:prompted, "use the docs"}
      refute_received {:added_mcp, _servers}
    end

    test "with nothing to ask about, it waits only for the check", %{tmp_dir: dir} do
      empty = Path.join(dir, "empty")
      File.mkdir_p!(Path.join(empty, ".git"))
      screen = starting([mcp_trust: %{store: dir, cwd: empty}], prompt: "hello")

      up(screen)
      assert_receive {:prompted, "hello"}
    end
  end

  test "a screen whose host started the session first sends it once mounted" do
    session = fake_session(snapshot("02STARTEDFIRST"))

    {:ok, _app} =
      TUI.start_link(
        test_mode: {80, 24},
        name: nil,
        start: fn -> {:ok, session} end,
        prompt: "from the host"
      )

    assert_receive {:prompted, "from the host"}
  end

  test "answering a question nothing was held for sends nothing" do
    state = %{tui() | history: History.staged(tui().history, "staged")}

    assert History.answered(state, :trust) == state
    refute_received :continue_queued

    held = History.hold(state, :trust)
    assert History.held?(held.history)
    refute History.held?(History.answered(held, :trust).history)
    assert_received :continue_queued
  end
end
