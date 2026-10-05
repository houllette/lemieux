defmodule Lemieux.Hooks.ClaudeTest do
  @moduledoc """
  Hooks and settings written for Claude Code, run unchanged.

  Most of these drive `Lemieux.Hooks.before_tool_call/3` and friends directly
  with real command hooks, because what they pin is the translation between
  a script's JSON and a decision — the session around it is covered by
  `Lemieux.HooksTest`.
  """
  use ExUnit.Case, async: true

  alias Lemieux.Hooks
  alias Lemieux.Hooks.Claude
  alias Lemieux.Hooks.Command
  alias Lemieux.Hooks.Config
  alias Lemieux.Tool.Result

  @moduletag :tmp_dir

  defp context(tmp_dir, extra \\ %{}) do
    Map.merge(
      %{
        session_id: "01TESTSESSION",
        cwd: tmp_dir,
        call_id: "c1",
        environment: Lemieux.Environment.local()
      },
      extra
    )
  end

  defp descriptor(properties),
    do: %{"interface" => %{"input_schema" => %{"properties" => properties}}}

  defp command(script, attrs \\ []), do: struct!(%Command{command: script}, attrs)

  # Test names become directory names, and some of them have apostrophes in.
  defp sh_quote(path), do: "'" <> String.replace(path, "'", "'\\''") <> "'"

  describe "matchers" do
    test "a Claude tool name matches the Lemieux tool it names, whatever the case" do
      assert Command.matches_any?(command("true", matcher: "Bash"), ["bash"])
      assert Command.matches_any?(command("true", matcher: "BASH"), ["bash"])
      refute Command.matches_any?(command("true", matcher: "Bash"), ["read"])
    end

    test "alternatives match any alias the tool answers to" do
      hook = command("true", matcher: "Edit|Write")

      assert Command.matches_any?(hook, ["edit" | Claude.tool_aliases("edit")])
      assert Command.matches_any?(hook, ["write" | Claude.tool_aliases("write")])
      refute Command.matches_any?(hook, ["bash" | Claude.tool_aliases("bash")])
    end

    test "a regular expression is caseless and sees the mcp__ alias of a remote tool" do
      mcp = %{"origin" => %{"type" => "mcp"}}
      hook = command("true", matcher: "mcp__memory__.*")

      assert Command.matches_any?(hook, [
               "memory__create" | Claude.tool_aliases("memory__create", mcp)
             ])

      refute Command.matches_any?(hook, ["memory__create" | Claude.tool_aliases("memory__create")])

      assert Command.matches_any?(command("true", matcher: "^BA.H$"), ["bash"])
    end
  end

  describe "Claude Code settings files" do
    test "are read in Claude's dialect: seconds, and unknown events skipped with a warning",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "settings.json")

      File.write!(
        path,
        JSON.encode!(%{
          "permissions" => %{"allow" => ["Bash(ls)"]},
          "hooks" => %{
            "PreToolUse" => [
              %{
                "matcher" => "Bash",
                "hooks" => [
                  %{"type" => "command", "command" => "./check.sh", "timeout" => 30},
                  %{"type" => "prompt", "prompt" => "is this safe?"}
                ]
              }
            ],
            "PreCompact" => [%{"hooks" => [%{"type" => "command", "command" => "./x"}]}]
          }
        })
      )

      assert {:ok, %{hooks: hooks, warnings: warnings}} = Config.load(path)

      assert [
               before_tool_call: %Command{
                 command: "./check.sh",
                 matcher: "Bash",
                 timeout: 30_000,
                 dialect: :claude
               }
             ] = hooks

      assert Enum.any?(warnings, &(&1 =~ "PreCompact"))
      assert Enum.any?(warnings, &(&1 =~ "prompt"))
    end

    test "a versioned Lemieux file keeps milliseconds and still refuses unknown events",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "hooks.json")

      File.write!(
        path,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{"PreToolUse" => [%{"command" => "./check.sh", "timeout" => 30}]}
        })
      )

      assert {:ok, [before_tool_call: %Command{timeout: 30, dialect: :lemieux}]} =
               Config.read(path)

      File.write!(path, JSON.encode!(%{"version" => 1, "hooks" => %{"PreCompact" => []}}))
      assert {:error, message} = Config.read(path)
      assert message =~ "unknown hook event"
    end

    test "disableAllHooks loads nothing and says so" do
      assert {:ok, %{hooks: [], warnings: [warning]}} =
               Config.load(%{"disableAllHooks" => true, "hooks" => %{"Stop" => []}})

      assert warning =~ "disableAllHooks"
    end

    test "a bare events object from a configuration file loads in the dialect asked for" do
      events = %{"preToolUse" => [%{"matcher" => "bash", "command" => "./p.sh"}]}

      assert {:ok, %{hooks: [before_tool_call: %Command{dialect: :lemieux}]}} =
               Config.load(events)

      assert {:ok, %{hooks: [before_tool_call: %Command{dialect: :claude}]}} =
               Config.load(events, dialect: :claude)

      assert {:error, message} = Config.load(%{"notAnEvent" => []})
      assert message =~ "expected an object"
    end

    test "a credential policy is stamped on every command, and a bad one is refused" do
      events = %{"preToolUse" => [%{"command" => "./p.sh"}]}

      assert {:ok, %{hooks: [before_tool_call: %Command{credentials: {:scrub, ["GH_*"]}}]}} =
               Config.load(events, credentials: {:scrub, ["GH_*"]})

      assert {:error, _message} = Config.load(events, credentials: :sometimes)
    end
  end

  describe "pre-tool decisions" do
    test "Claude's nested permissionDecision deny is a denial, with its reason",
         %{tmp_dir: tmp_dir} do
      output =
        JSON.encode!(%{
          "hookSpecificOutput" => %{
            "hookEventName" => "PreToolUse",
            "permissionDecision" => "deny",
            "permissionDecisionReason" => "no pushing from agents"
          }
        })

      hook = command("printf '%s' '#{output}'", dialect: :claude)
      call = %{id: "c1", name: "bash", arguments: %{"command" => "git push"}}

      assert Hooks.before_tool_call([before_tool_call: hook], call, context(tmp_dir)) ==
               {:deny, "no pushing from agents"}
    end

    test "continue: false stops the call with the stop reason", %{tmp_dir: tmp_dir} do
      output = JSON.encode!(%{"continue" => false, "stopReason" => "halted by policy"})
      hook = command("printf '%s' '#{output}'", dialect: :claude)
      call = %{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

      assert {:deny, "halted by policy"} =
               Hooks.before_tool_call([before_tool_call: hook], call, context(tmp_dir))
    end

    test "an explicit allow tells the hooks after it who approved the call",
         %{tmp_dir: tmp_dir} do
      output = JSON.encode!(%{"hookSpecificOutput" => %{"permissionDecision" => "allow"}})
      parent = self()

      hooks = [
        before_tool_call: command("printf '%s' '#{output}'", name: "gate", dialect: :claude),
        before_tool_call: fn _call, context ->
          send(parent, {:approved_by, Map.get(context, :approved_by)})
          :allow
        end
      ]

      call = %{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
      assert {:ok, %{"command" => "ls"}} = Hooks.before_tool_call(hooks, call, context(tmp_dir))
      assert_received {:approved_by, "hook gate"}
    end

    test "an empty answer is no objection, not an approval", %{tmp_dir: tmp_dir} do
      parent = self()

      hooks = [
        before_tool_call: command("true"),
        before_tool_call: fn _call, context ->
          send(parent, {:approved_by, Map.get(context, :approved_by)})
          :allow
        end
      ]

      call = %{id: "c1", name: "bash", arguments: %{"command" => "ls"}}
      assert {:ok, _args} = Hooks.before_tool_call(hooks, call, context(tmp_dir))
      assert_received {:approved_by, nil}
    end

    test "updatedInput written with Claude's field names reaches the tool with its own",
         %{tmp_dir: tmp_dir} do
      output =
        JSON.encode!(%{
          "hookSpecificOutput" => %{
            "updatedInput" => %{"file_path" => "safe.txt", "content" => "x"}
          }
        })

      hook = command("printf '%s' '#{output}'", dialect: :claude)
      call = %{id: "c1", name: "write", arguments: %{"path" => "a.txt", "content" => "x"}}

      context =
        context(tmp_dir, %{tool_descriptor: descriptor(%{"path" => %{}, "content" => %{}})})

      assert Hooks.before_tool_call([before_tool_call: hook], call, context) ==
               {:ok, %{"path" => "safe.txt", "content" => "x"}}
    end

    test "a Claude-dialect script is shown Claude's event, tool and field names",
         %{tmp_dir: tmp_dir} do
      seen = Path.join(tmp_dir, "seen.json")
      hook = command("cat > " <> sh_quote(seen), dialect: :claude, matcher: "Edit")
      call = %{id: "c1", name: "edit", arguments: %{"path" => "a.ex", "old" => "x", "new" => "y"}}

      assert {:ok, _args} =
               Hooks.before_tool_call([before_tool_call: hook], call, context(tmp_dir))

      assert %{
               "hook_event_name" => "PreToolUse",
               "tool_name" => "Edit",
               "tool_input" => %{
                 "file_path" => "a.ex",
                 "path" => "a.ex",
                 "old_string" => "x",
                 "new_string" => "y"
               }
             } = seen |> File.read!() |> JSON.decode!()
    end

    test "a Lemieux-dialect script still sees Lemieux's names", %{tmp_dir: tmp_dir} do
      seen = Path.join(tmp_dir, "seen.json")
      hook = command("cat > " <> sh_quote(seen), matcher: "Edit")
      call = %{id: "c1", name: "edit", arguments: %{"path" => "a.ex"}}

      assert {:ok, _args} =
               Hooks.before_tool_call([before_tool_call: hook], call, context(tmp_dir))

      assert %{"hook_event_name" => "preToolUse", "tool_name" => "edit", "tool_input" => input} =
               seen |> File.read!() |> JSON.decode!()

      refute Map.has_key?(input, "file_path")
    end
  end

  describe "post-tool feedback" do
    test "a block, additional context and a function's feedback all reach the model",
         %{tmp_dir: tmp_dir} do
      context_output =
        JSON.encode!(%{"hookSpecificOutput" => %{"additionalContext" => "run mix format"}})

      hooks = [
        after_tool_call: command("echo 'lint failed: unused variable' >&2; exit 2"),
        after_tool_call: command("printf '%s' '#{context_output}'", dialect: :claude),
        after_tool_call: command(~s(printf '%s' '{"decision":"block","reason":"tests are red"}')),
        after_tool_call: fn _call, _result, _context -> {:feedback, "from Elixir"} end,
        after_tool_call: fn _call, _result, _context -> :ignored end
      ]

      call = %{id: "c1", name: "write", arguments: %{"path" => "a.ex"}}

      assert Hooks.after_tool_call_feedback(hooks, call, {:ok, "wrote a.ex"}, context(tmp_dir)) ==
               [
                 "lint failed: unused variable",
                 "run mix format",
                 "tests are red",
                 "from Elixir"
               ]

      assert Hooks.after_tool_call(hooks, call, {:ok, "wrote a.ex"}, context(tmp_dir)) == :ok
    end

    test "feedback follows the output under a marker, and no feedback changes nothing" do
      result = {:ok, Result.new("wrote a.ex")}

      assert Hooks.append_feedback(result, []) == result

      assert {:ok, %Result{model_text: "wrote a.ex\n\n[hook] tests are red"}} =
               Hooks.append_feedback(result, ["tests are red"])
    end

    test "a Claude-dialect post-tool script receives tool_response", %{tmp_dir: tmp_dir} do
      seen = Path.join(tmp_dir, "seen.json")
      hook = command("cat > " <> sh_quote(seen), dialect: :claude)
      call = %{id: "c1", name: "bash", arguments: %{"command" => "ls"}}

      Hooks.after_tool_call([after_tool_call: hook], call, {:error, "boom"}, context(tmp_dir))

      assert %{
               "hook_event_name" => "PostToolUse",
               "tool_name" => "Bash",
               "tool_response" => %{"output" => "boom", "error" => true}
             } = seen |> File.read!() |> JSON.decode!()
    end
  end

  describe "prompt hooks" do
    test "plain stdout from a Claude prompt hook is added as context", %{tmp_dir: tmp_dir} do
      hook = command("echo 'Current branch: main'", dialect: :claude)

      assert Hooks.user_prompt([user_prompt: hook], "fix it", context(tmp_dir)) ==
               {:ok, "fix it\n\nCurrent branch: main"}
    end

    test "plain stdout from a Lemieux prompt hook is still an invalid-JSON warning",
         %{tmp_dir: tmp_dir} do
      hook = command("echo 'Current branch: main'")

      ExUnit.CaptureLog.capture_log(fn ->
        assert Hooks.user_prompt([user_prompt: hook], "fix it", context(tmp_dir)) ==
                 {:ok, "fix it"}
      end)
    end
  end

  describe "unmatched/2" do
    test "names a matcher that matches no tool, and ignores what may appear later" do
      hooks = [
        before_tool_call: command("x", matcher: "Bash"),
        before_tool_call: command("x", matcher: "Notebook"),
        after_tool_call: command("x", matcher: "Edit|Deploy"),
        before_tool_call: command("x", matcher: "mcp__github__create_issue"),
        before_tool_call: command("x", matcher: "Note.*"),
        before_tool_call: command("x", name: "anything"),
        stop: command("x", matcher: "Notebook")
      ]

      assert [warning] = Hooks.unmatched(hooks, ["bash", "read", "edit"])
      assert warning =~ "preToolUse"
      assert warning =~ "Notebook"
    end
  end

  test "the hook's JSON input is written somewhere only its owner can read" do
    assert {:ok, directory} = Command.private_directory()

    try do
      assert %File.Stat{mode: mode} = File.stat!(directory)
      assert Bitwise.band(mode, 0o777) == 0o700
    after
      File.rm_rf!(directory)
    end
  end
end
