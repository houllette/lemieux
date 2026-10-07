defmodule Lemieux.HooksTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Hooks.Config
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Touch do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl Lemieux.Tool
    def name, do: "touch"
    @impl Lemieux.Tool
    def description, do: "Reports the path it was given."
    @impl Lemieux.Tool
    def schema, do: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}

    @impl Lemieux.Tool
    def run(%{"path" => path}, _context), do: {:ok, "touched #{path}"}
    def run(_args, _context), do: {:error, "touch needs a path"}
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_hooks_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir), tmp_dir: tmp_dir}
  end

  defp run(context, hooks, arguments \\ %{"path" => "a.txt"}) do
    call = %{id: "t1", name: "touch", arguments: arguments}
    provider = Scripted.new([[{:tool_call, call}, {:done, :tool_calls}], [{:done, :stop}]])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        subscriber: self(),
        tools: [Touch],
        hooks: hooks
      )

    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, _, {:finished, :stop}}, 10_000

    [_first, %Request{entries: entries}] = Scripted.requests(provider)

    Enum.find(entries, &(&1.type == :tool_result))
  end

  test "deny becomes a tool result the model sees, with the reason", context do
    # The bug this exists to make impossible: a denial that the model is not
    # told about. It carries on as though the call had succeeded, and every
    # conclusion after that point is built on something that never happened.
    hooks = [before_tool_call: fn _call, _ctx -> {:deny, "not in this directory"} end]

    assert %Entry{payload: payload} = run(context, hooks)

    assert payload["error"] == true
    assert payload["output"] =~ "denied"
    assert payload["output"] =~ "not in this directory"
    assert payload["call_id"] == "t1"
  end

  test "rewrite replaces the arguments before execution", context do
    hooks = [before_tool_call: fn _call, _ctx -> {:rewrite, %{"path" => "safe.txt"}} end]

    assert %Entry{payload: payload} = run(context, hooks)

    assert payload["output"] == "touched safe.txt"
    # And the transcript records what actually ran, not what was asked for.
    assert payload["arguments"] == %{"path" => "safe.txt"}
  end

  test "allow runs the call untouched", context do
    hooks = [before_tool_call: fn _call, _ctx -> :allow end]

    assert %Entry{payload: %{"output" => "touched a.txt"}} = run(context, hooks)
  end

  test "after_tool_call observes the result", context do
    parent = self()

    hooks = [
      after_tool_call: fn call, result, _ctx -> send(parent, {:observed, call.name, result}) end
    ]

    run(context, hooks)

    assert_received {:observed, "touch", {:ok, "touched a.txt"}}
  end

  test "after_tool_call sees a failure too", context do
    parent = self()
    hooks = [after_tool_call: fn _call, result, _ctx -> send(parent, {:observed, result}) end]

    run(context, hooks, %{})

    assert_received {:observed, {:error, _reason}}
  end

  test "hooks receive the tool context, including the session", context do
    parent = self()

    hooks = [
      before_tool_call: fn _call, ctx ->
        send(parent, {:ctx, ctx})
        :allow
      end
    ]

    run(context, hooks)

    assert_received {:ctx, %{session_id: _id, call_id: "t1", cwd: _cwd}}
  end

  test "several hooks run in order, and a rewrite is threaded into the next", context do
    hooks = [
      before_tool_call: fn call, _ctx ->
        {:rewrite, Map.put(call.arguments, "path", call.arguments["path"] <> ".one")}
      end,
      before_tool_call: fn call, _ctx ->
        {:rewrite, Map.put(call.arguments, "path", call.arguments["path"] <> ".two")}
      end
    ]

    assert %Entry{payload: %{"output" => "touched a.txt.one.two"}} = run(context, hooks)
  end

  test "the first deny wins and the hooks after it do not run", context do
    parent = self()

    hooks = [
      before_tool_call: fn _call, _ctx -> {:deny, "first"} end,
      before_tool_call: fn _call, _ctx ->
        send(parent, :second_ran)
        :allow
      end
    ]

    assert %Entry{payload: %{"output" => output}} = run(context, hooks)

    assert output =~ "first"
    refute_received :second_ran
  end

  @tag :capture_log
  test "a hook that raises fails its own call and leaves the session standing", context do
    hooks = [before_tool_call: fn _call, _ctx -> raise "the hook exploded" end]

    assert %Entry{payload: payload} = run(context, hooks)

    assert payload["error"] == true
    assert payload["output"] =~ "the hook exploded"
  end

  test "no hooks at all means everything runs", context do
    assert %Entry{payload: %{"output" => "touched a.txt"}} = run(context, [])
  end

  describe "command hooks" do
    test "a preToolUse command receives JSON and may deny the call", context do
      path = Path.join(context.tmp_dir, "hooks.json")

      File.write!(
        path,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "preToolUse" => [
              %{
                "matcher" => "touch",
                "hooks" => [
                  %{
                    "type" => "command",
                    "command" =>
                      "input=$(cat); " <>
                        ~s(echo "$input" | grep -q '"tool_name":"touch"' || exit 1; ) <>
                        "echo 'blocked by the repository hook' >&2; exit 2"
                  }
                ]
              }
            ]
          }
        })
      )

      assert {:ok, hooks} = Config.read(path)
      assert %Entry{payload: payload} = run(context, hooks)
      assert payload["error"] == true
      assert payload["output"] =~ "blocked by the repository hook"
    end

    test "a preToolUse command may rewrite tool input", context do
      path = Path.join(context.tmp_dir, "hooks.json")

      File.write!(
        path,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "preToolUse" => [
              %{
                "hooks" => [
                  %{
                    "type" => "command",
                    "command" => "printf '%s' '{\"updated_input\":{\"path\":\"safe.txt\"}}'"
                  }
                ]
              }
            ]
          }
        })
      )

      assert {:ok, hooks} = Config.read(path)
      assert %Entry{payload: %{"output" => "touched safe.txt"}} = run(context, hooks)
    end

    test "a postToolUse command observes the result", context do
      observed = Path.join(context.tmp_dir, "observed.json")
      config = Path.join(context.tmp_dir, "hooks.json")

      File.write!(
        config,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "postToolUse" => [
              %{
                "command" => "cat > #{LemieuxTest.Shell.quoted(observed)}",
                "timeout" => 10_000
              }
            ]
          }
        })
      )

      assert {:ok, hooks} = Config.read(config)
      run(context, hooks)

      assert %{
               "hook_event_name" => "postToolUse",
               "tool_name" => "touch",
               "tool_result" => %{"output" => "touched a.txt", "error" => false}
             } = observed |> File.read!() |> JSON.decode!()
    end

    test "an invalid matcher rejects the config instead of silently disabling a gate", context do
      path = Path.join(context.tmp_dir, "hooks.json")

      File.write!(
        path,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "preToolUse" => [%{"matcher" => "[", "command" => "exit 2"}]
          }
        })
      )

      assert {:error, reason} = Config.read(path)
      assert reason =~ "valid regular expression"
    end

    test "attention command hooks are accepted as observation hooks", context do
      path = Path.join(context.tmp_dir, "hooks.json")

      File.write!(
        path,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "attention" => [%{"matcher" => "waiting|working", "command" => "exit 0"}]
          }
        })
      )

      assert {:ok, [attention: %Lemieux.Hooks.Command{}]} = Config.read(path)
    end
  end

  describe "agent lifecycle hooks" do
    test "sessionStart runs once with the source and session context", context do
      parent = self()

      hooks = [
        session_start: fn payload, hook_context ->
          send(parent, {:started, payload, hook_context})
        end
      ]

      run(context, hooks)

      assert_receive {:started, %{source: :startup}, %{session_id: _id, cwd: _cwd}}
      refute_receive {:started, _, _}
    end

    test "userPromptSubmitted may rewrite the prompt before it is persisted", context do
      hooks = [user_prompt: fn _prompt, _hook_context -> {:rewrite, "rewritten"} end]
      provider = Scripted.new([[{:done, :stop}]])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          hooks: hooks
        )

      assert :ok = Session.prompt(session, "original")
      assert_receive {:lemieux, _, {:finished, :stop}}
      assert [%Request{entries: [_config, user]}] = Scripted.requests(provider)
      assert user.payload == %{"text" => "rewritten"}
    end

    test "userPromptSubmitted may deny a prompt without writing it", context do
      hooks = [user_prompt: fn _prompt, _hook_context -> {:deny, "not now"} end]
      provider = Scripted.new([])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          hooks: hooks
        )

      assert Session.prompt(session, "original") == {:error, {:hook_denied, "not now"}}
      assert [%Entry{type: :session}] = Session.snapshot(session).entries
      assert Scripted.requests(provider) == []
    end

    test "a slow prompt hook does not stop the session answering snapshots", context do
      parent = self()

      hooks = [
        user_prompt: fn prompt, _hook_context ->
          send(parent, {:prompt_hook, self()})

          receive do
            :release -> {:rewrite, prompt}
          end
        end
      ]

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: Scripted.new([[{:done, :stop}]]),
          store: context.store,
          model: "test:model",
          subscriber: self(),
          hooks: hooks
        )

      prompt = Task.async(fn -> Session.prompt(session, "work") end)
      assert_receive {:prompt_hook, hook_task}
      assert %{status: :busy, entries: [%Entry{type: :session}]} = Session.snapshot(session)

      send(hook_task, :release)
      assert Task.await(prompt) == :ok
      assert_receive {:lemieux, _, {:finished, :stop}}
    end

    test "agentStop may send feedback and keep the agent working", context do
      parent = self()

      hooks = [
        stop: fn _reason, hook_context ->
          send(parent, {:stop_hook, hook_context.stop_hook_active, hook_context.aside})

          if hook_context.stop_hook_active,
            do: :allow,
            else: {:deny, "verify the work before stopping"}
        end
      ]

      provider = Scripted.new([[{:done, :stop}], [{:done, :stop}]])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          hooks: hooks
        )

      assert :ok = Session.prompt(session, "work")
      assert_receive {:lemieux, _, {:finished, :stop}}
      assert_received {:stop_hook, false, nil}
      assert_received {:stop_hook, true, nil}

      # Recorded as the harness speaking, so nothing reading the transcript
      # later takes the hook's words for the person's next prompt.
      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      feedback = List.last(entries)

      assert feedback.payload == %{
               "text" => "verify the work before stopping",
               "stop_hook" => true
             }

      assert Lemieux.Transcript.stop_hook?(feedback)
      [prompt] = Enum.filter(entries, &(&1.type == :user and &1 != feedback))
      refute Lemieux.Transcript.stop_hook?(prompt)
    end

    test "errorOccurred observes provider errors", context do
      parent = self()
      hooks = [error: fn reason, _hook_context -> send(parent, {:hook_error, reason}) end]
      provider = Scripted.new([[{:error, :closed}]])

      # A closed connection is transient, and the session would retry it; this
      # is about the hook seeing the error, not about the retry policy.
      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          hooks: hooks,
          provider_retry: false
        )

      assert :ok = Session.prompt(session, "work")
      assert_receive {:lemieux, _, {:finished, :error}}
      assert_receive {:hook_error, :closed}
    end

    test "sessionEnd runs when the host terminates the session", context do
      parent = self()
      hooks = [session_end: fn reason, _hook_context -> send(parent, {:ended, reason}) end]

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: Scripted.new([]),
          store: context.store,
          model: "test:model",
          hooks: hooks
        )

      assert :ok =
               DynamicSupervisor.terminate_child(
                 Lemieux.Supervisor.session_supervisor(context.runtime),
                 session
               )

      assert_receive {:ended, :shutdown}
    end
  end
end
