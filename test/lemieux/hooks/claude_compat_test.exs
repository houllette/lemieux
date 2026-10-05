defmodule Lemieux.Hooks.ClaudeCompatTest do
  @moduledoc """
  Claude Code hooks as Claude Code's documentation writes them: exec form,
  `${CLAUDE_PROJECT_DIR}` paths, plugin variables and `SessionStart`
  context. Each of these failed open before: the hook did not run, or ran
  as something else, and the action it existed to stop went ahead.
  """
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Plugin
  alias Lemieux.Hooks
  alias Lemieux.Hooks.Command
  alias Lemieux.Hooks.Config
  alias Lemieux.Hooks.SessionContext
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  @deny ~s({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"policy said no"}})

  defp script(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp claude(hooks), do: Config.load(%{"hooks" => hooks})

  defp pre_tool(hook), do: claude(%{"PreToolUse" => [%{"matcher" => "Write", "hooks" => [hook]}]})

  defp write_call(content),
    do: %{id: "call-1", name: "write", arguments: %{"path" => "notes.txt", "content" => content}}

  describe "exec form" do
    test "passes the input on stdin and never runs it as a script", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "substitution-ran")
      seen = Path.join(tmp_dir, "seen.json")
      guard = script(Path.join(tmp_dir, "guard.sh"), "cat > \"$1\"\necho '#{@deny}'\n")

      # The shape that once fed the input JSON to `sh` as its script.
      assert {:ok, %{hooks: hooks, warnings: []}} =
               pre_tool(%{"type" => "command", "command" => "sh", "args" => [guard, seen]})

      assert [{:before_tool_call, %Command{args: [^guard, ^seen]}}] = hooks

      call = write_call("$(touch #{marker})")
      context = %{cwd: tmp_dir, session_id: "s-1"}

      assert {:deny, "policy said no"} = Hooks.before_tool_call(hooks, call, context)
      refute File.exists?(marker), "a $() in the tool input ran as shell"

      input = seen |> File.read!() |> JSON.decode!()
      assert input["tool_name"] == "Write"
      assert input["tool_input"]["content"] == "$(touch #{marker})"
    end

    test "passes each argument exactly as written", %{tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "argv.txt")

      echo =
        script(
          Path.join(tmp_dir, "argv.sh"),
          "for a in \"$@\"; do echo \"[$a]\"; done > \"#{out}\"\n"
        )

      assert {:ok, %{hooks: [{:before_tool_call, command}]}} =
               pre_tool(%{
                 "command" => echo,
                 "args" => ["it's", "$HOME", "`date`", "two words", "*"]
               })

      assert {:ok, %{}} = Command.run(command, %{}, %{cwd: tmp_dir})
      assert File.read!(out) == "[it's]\n[$HOME]\n[`date`]\n[two words]\n[*]\n"
    end

    test "substitutes the project directory into the program and arguments", %{tmp_dir: tmp_dir} do
      script(Path.join(tmp_dir, ".claude/hooks/record.sh"), "echo ran > \"$1\"\n")

      assert {:ok, %{hooks: [{:before_tool_call, command}]}} =
               pre_tool(%{
                 "command" => "${CLAUDE_PROJECT_DIR}/.claude/hooks/record.sh",
                 "args" => ["${CLAUDE_PROJECT_DIR}/ran.txt"]
               })

      assert {:ok, %{}} = Command.run(command, %{}, %{cwd: tmp_dir})
      assert File.read!(Path.join(tmp_dir, "ran.txt")) == "ran\n"
    end

    test "a program that cannot be found is a warning naming the hook", %{tmp_dir: tmp_dir} do
      assert {:ok, %{hooks: [{:before_tool_call, command}]}} =
               pre_tool(%{"command" => "lmx-no-such-program", "args" => []})

      assert {:warning, warning} = Command.run(command, %{}, %{cwd: tmp_dir})
      assert warning =~ "exited with status 127"
    end

    test "arguments must be strings, and a program with words in it is warned about" do
      assert {:error, reason} = pre_tool(%{"command" => "node", "args" => ["a", 1]})
      assert reason =~ "hook args must be a list of strings"

      assert {:ok, %{hooks: [_hook], warnings: [warning]}} =
               pre_tool(%{"command" => "node script.js", "args" => ["--fix"]})

      assert warning =~ "exec-form hook \"node script.js\" names no program"
    end
  end

  describe "what a Claude Code hook is told" do
    test "a project hook written with ${CLAUDE_PROJECT_DIR} runs and blocks", %{tmp_dir: tmp_dir} do
      script(
        Path.join(tmp_dir, ".claude/hooks/block-write.sh"),
        "echo 'writes are reviewed first' >&2\nexit 2\n"
      )

      # Claude Code's own shell-form example. Without the variable this
      # became /.claude/hooks/block-write.sh, failed to start, and did not
      # block.
      assert {:ok, %{hooks: hooks}} =
               pre_tool(%{
                 "type" => "command",
                 "command" => "\"${CLAUDE_PROJECT_DIR}\"/.claude/hooks/block-write.sh"
               })

      assert {:deny, "writes are reviewed first"} =
               Hooks.before_tool_call(hooks, write_call("x"), %{cwd: tmp_dir, session_id: "s"})
    end

    test "a plugin's hooks get its root, its data directory and the project", %{
      tmp_dir: tmp_dir
    } do
      plugin = Path.join(tmp_dir, "plugins/env-plugin")
      dump = Path.join(tmp_dir, "env.txt")

      script(
        Path.join(plugin, "hooks/dump.sh"),
        "printf 'ROOT=%s\\nDATA=%s\\nPROJECT=%s\\n' \"$CLAUDE_PLUGIN_ROOT\" " <>
          "\"$CLAUDE_PLUGIN_DATA\" \"$CLAUDE_PROJECT_DIR\" > \"#{dump}\"\n"
      )

      File.write!(
        Path.join(plugin, "hooks/hooks.json"),
        JSON.encode!(%{
          "hooks" => %{
            "Stop" => [
              %{
                "hooks" => [
                  %{
                    "type" => "command",
                    "command" => "sh \"${CLAUDE_PLUGIN_ROOT}/hooks/dump.sh\""
                  }
                ]
              }
            ]
          }
        })
      )

      data_root = Path.join(tmp_dir, "plugin-data")
      project = Path.join(tmp_dir, "project")
      File.mkdir_p!(project)

      assert {:ok, loaded} = Plugin.read(plugin, data_root: data_root, id: "env-plugin@team")
      assert [{:stop, command}] = loaded.hooks
      data = Path.join(data_root, "env-plugin-team")
      refute File.exists?(data), "reading a plugin creates nothing"

      assert {:ok, %{}} = Command.run(command, %{}, %{cwd: project})

      assert File.read!(dump) ==
               "ROOT=#{Path.expand(plugin)}\nDATA=#{data}\nPROJECT=#{project}\n"

      assert File.dir?(data), "the data directory exists once a hook is told about it"
      assert Bitwise.band(File.stat!(data).mode, 0o777) == 0o700
    end

    test "a plugin found without personal files keeps its data out of the person's", %{
      tmp_dir: tmp_dir
    } do
      plugin = Path.join(tmp_dir, "plugins/kit")

      File.mkdir_p!(Path.join(plugin, "hooks"))

      File.write!(
        Path.join(plugin, "hooks/hooks.json"),
        JSON.encode!(%{"hooks" => %{"Stop" => [%{"hooks" => [%{"command" => "true"}]}]}})
      )

      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      personal_dir = Path.join(tmp_dir, "personal")

      data_of = fn opts ->
        assert {:ok, workspace} =
                 Discovery.discover(
                   repo,
                   [
                     plugin_dirs: [plugin],
                     personal_dir: personal_dir,
                     claude_personal_dir: Path.join(personal_dir, "claude"),
                     codex_personal_dir: Path.join(personal_dir, "codex"),
                     agents_personal_dir: Path.join(personal_dir, "agents"),
                     home: tmp_dir
                   ] ++ opts
                 )

        assert [{:stop, %Command{env: %{"CLAUDE_PLUGIN_DATA" => data}}}] = workspace.hooks
        data
      end

      assert data_of.(personal?: true) == Path.join(personal_dir, "plugin-data/kit")

      # `--config none`: nothing personal is read, and nothing is kept there.
      hermetic = data_of.(personal?: false)
      refute String.starts_with?(hermetic, personal_dir)
      assert String.starts_with?(hermetic, System.tmp_dir!())
      refute data_of.(personal?: false) == hermetic, "each run gets its own"
      refute File.exists?(hermetic), "nothing is created until a hook or server starts"
    end

    test "a plugin's stdio servers get its root and data directory too", %{tmp_dir: tmp_dir} do
      plugin = Path.join(tmp_dir, "plugins/servers")

      File.mkdir_p!(plugin)

      File.write!(
        Path.join(plugin, ".mcp.json"),
        JSON.encode!(%{
          "mcpServers" => %{
            "local" => %{
              "command" => "${CLAUDE_PLUGIN_ROOT}/bin/server",
              "args" => ["--cache", "${CLAUDE_PLUGIN_DATA}/cache"],
              "env" => %{"CLAUDE_PLUGIN_DATA" => "/kept/as/written"}
            },
            "remote" => %{"url" => "https://example.com/mcp"}
          }
        })
      )

      data_root = Path.join(tmp_dir, "plugin-data")
      assert {:ok, loaded} = Plugin.read(plugin, data_root: data_root)
      by_name = Map.new(loaded.mcp_servers, &{&1["name"], &1})

      local = by_name["plugin_servers_local"]
      root = Path.expand(plugin)
      data = Path.join(data_root, "servers")

      assert local["command"] == Path.join(root, "bin/server")
      assert local["args"] == ["--cache", Path.join(data, "cache")]

      assert local["env"] == %{
               "CLAUDE_PLUGIN_ROOT" => root,
               "CLAUDE_PLUGIN_DATA" => "/kept/as/written"
             }

      refute Map.has_key?(by_name["plugin_servers_remote"], "env")
    end

    test "a Lemieux-dialect hook is not given Claude's variables", %{tmp_dir: tmp_dir} do
      command = %Command{command: "true", dialect: :lemieux}
      claude = %Command{command: "true", dialect: :claude}

      refute Enum.any?(Command.environment(command, %{cwd: tmp_dir}), fn {name, _value} ->
               name == ~c"CLAUDE_PROJECT_DIR"
             end)

      assert {~c"CLAUDE_PROJECT_DIR", to_charlist(tmp_dir)} in Command.environment(claude, %{
               cwd: tmp_dir
             })
    end
  end

  describe "SessionStart context" do
    setup do
      runtime = :"lemieux_claude_compat_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      %{runtime: runtime}
    end

    defp session(ctx, hooks, provider, opts \\ []) do
      {:ok, session} =
        Lemieux.start_session(
          [
            supervisor: ctx.runtime,
            provider: provider,
            store: JSONL.new(Path.join(ctx.tmp_dir, "sessions")),
            model: "test:model",
            subscriber: self(),
            cwd: ctx.tmp_dir,
            hooks: hooks
          ] ++ opts
        )

      session
    end

    defp prompt!(session, text) do
      :ok = Session.prompt(session, text)
      assert_receive {:lemieux, _, {:finished, :stop}}, 10_000
    end

    defp user_texts(provider) do
      for %Request{entries: entries} <- Scripted.requests(provider),
          entry <- entries,
          entry.type == :user,
          uniq: true,
          do: entry.payload["text"]
    end

    test "what the hooks print reaches the model with the first prompt only", ctx do
      assert {:ok, %{hooks: hooks}} =
               claude(%{
                 "SessionStart" => [
                   %{
                     "hooks" => [
                       %{
                         "type" => "command",
                         "command" => "echo 'Explain your choices as you go.'"
                       },
                       %{
                         "type" => "command",
                         "command" =>
                           ~s(echo '{"hookSpecificOutput":{"hookEventName":"SessionStart",) <>
                             ~s("additionalContext":"The build is make check."}}')
                       }
                     ]
                   }
                 ]
               })

      provider = Scripted.new([[{:done, :stop}], [{:done, :stop}]])
      session = session(ctx, hooks, provider)

      prompt!(session, "first question")
      prompt!(session, "second question")

      assert [first, "second question"] = user_texts(provider)

      assert first ==
               "<session-start-hook-context>\nExplain your choices as you go.\n\n" <>
                 "The build is make check.\n</session-start-hook-context>\n\nfirst question"
    end

    test "a hook that prints nothing leaves the prompt as it was", ctx do
      assert {:ok, %{hooks: hooks}} =
               claude(%{"SessionStart" => [%{"hooks" => [%{"command" => "true"}]}]})

      provider = Scripted.new([[{:done, :stop}]])
      prompt!(session(ctx, hooks, provider), "only question")
      assert user_texts(provider) == ["only question"]
    end

    test "a Lemieux-dialect sessionStart command still only observes", ctx do
      assert {:ok, %{hooks: hooks}} =
               Config.load(%{
                 "version" => 1,
                 "hooks" => %{"sessionStart" => [%{"command" => "echo '{\"note\":\"ignored\"}'"}]}
               })

      refute Hooks.registered?(hooks, :user_prompt)
      provider = Scripted.new([[{:done, :stop}]])
      prompt!(session(ctx, hooks, provider), "only question")
      assert user_texts(provider) == ["only question"]

      # Nothing waits for an observer, so it can still be running here, and
      # the runtime stopping under it at the end of the test killed it before
      # it removed its private directory: one lemieux-hook-* directory left
      # in the system's temporary directory by every run.
      for observer <- Task.Supervisor.children(Lemieux.Supervisor.task_supervisor(ctx.runtime)) do
        ref = Process.monitor(observer)
        assert_receive {:DOWN, ^ref, :process, ^observer, _reason}
      end
    end

    test "is held by a background process a host's shutdown does not wait on", ctx do
      assert {:ok, %{hooks: hooks}} =
               claude(%{"SessionStart" => [%{"hooks" => [%{"command" => "echo context"}]}]})

      provider = Scripted.new([[{:done, :stop}]])
      session = session(ctx, hooks, provider)
      prompt!(session, "only question")

      # Listed in the sessions registry, the holder was a "session" that
      # never answered `GenServer.stop/3`: quitting waited minutes.
      assert [{_id, ^session}] = Lemieux.sessions(ctx.runtime)

      assert [{holder, _value}] =
               Registry.lookup(
                 Lemieux.Supervisor.background_registry(ctx.runtime),
                 {SessionContext, session}
               )

      holder_ref = Process.monitor(holder)
      {microseconds, :ok} = :timer.tc(fn -> Runtime.stop_sessions(ctx.runtime) end)

      assert microseconds < 5_000_000
      assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, 5_000
    end

    test "is not run or given to the session of a delegated subagent", ctx do
      ran = Path.join(ctx.tmp_dir, "ran")

      assert {:ok, %{hooks: hooks}} =
               claude(%{
                 "SessionStart" => [
                   %{"hooks" => [%{"command" => ~s(touch "#{ran}"; echo 'Parent context.')}]}
                 ]
               })

      provider = Scripted.new([[{:done, :stop}]])

      # What `Lemieux.Subagent.Group` passes a child: its root's id, which is
      # not the child's own.
      session = session(ctx, hooks, provider, root_session_id: "01ROOTSESSIONOFTHETREE00000")
      prompt!(session, "delegated task")

      assert user_texts(provider) == ["delegated task"]
      refute File.exists?(ran)
    end

    test "a host calling session_start by hand gets its hooks run and nothing held", %{
      tmp_dir: tmp_dir
    } do
      ran = Path.join(tmp_dir, "ran")

      assert {:ok, %{hooks: hooks}} =
               claude(%{
                 "SessionStart" => [%{"hooks" => [%{"command" => "touch #{ran}; echo context"}]}]
               })

      assert :ok = Hooks.session_start(hooks, :startup, %{cwd: tmp_dir, session_id: "s"})
      assert File.exists?(ran)
    end
  end

  describe "a hook that runs too long" do
    test "is stopped with what it started", %{tmp_dir: tmp_dir} do
      pid_file = Path.join(tmp_dir, "child.pid")

      command = %Command{
        command: "sleep 30 & echo $! > \"#{pid_file}\"; sleep 30",
        timeout: 500
      }

      assert {:warning, warning} = Command.run(command, %{}, %{cwd: tmp_dir})
      assert warning =~ "timed out after 500ms"

      child = pid_file |> File.read!() |> String.trim()
      assert gone?(child, 50), "the hook's background child #{child} outlived its timeout"
    end

    test "is signalled without a kill executable, through the shell's builtin" do
      shell_only = fn
        "sh" -> "/bin/sh"
        _other -> nil
      end

      assert Command.signal_command({:unix, :linux}, {:group, 4242}, shell_only) ==
               {"/bin/sh", ["-c", "kill -s KILL -- -4242"]}

      assert Command.signal_command({:unix, :linux}, {:process, 4242}, fn
               "kill" -> "/usr/bin/kill"
               _other -> nil
             end) == {"/usr/bin/kill", ["-KILL", "--", "4242"]}

      assert Command.signal_command({:unix, :darwin}, {:group, 1}, fn _ -> nil end) == nil
    end

    test "is stopped as a tree on Windows" do
      find = fn
        "taskkill" -> "C:/Windows/System32/taskkill.exe"
        _other -> nil
      end

      assert Command.signal_command({:win32, :nt}, {:group, 77}, find) == nil

      assert Command.signal_command({:win32, :nt}, {:process, 77}, find) ==
               {"C:/Windows/System32/taskkill.exe", ["/F", "/T", "/PID", "77"]}
    end

    defp gone?(_pid, 0), do: false

    defp gone?(pid, attempts) do
      case System.cmd("sh", ["-c", "kill -0 #{pid} 2>/dev/null"]) do
        {_output, 0} ->
          Process.sleep(50)
          gone?(pid, attempts - 1)

        {_output, _status} ->
          true
      end
    end
  end

  # The shell itself is chosen by Lemieux.Environment.Local.find_bash/0, the
  # same function the bash tool uses; its rules (bash then sh, Git for
  # Windows' bash, never WSL's launcher) are tested in
  # test/lemieux/environment/find_bash_test.exs.
end
