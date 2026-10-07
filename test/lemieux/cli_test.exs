defmodule Lemieux.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  # These drive run/1 rather than main/1 on purpose: main/1 calls
  # System.halt/1, which would take the test VM down instead of failing a
  # test. See the CLI's @moduledoc.
  describe "run/1" do
    test "--version prints the binary name and version" do
      assert capture_io(fn -> CLI.run(["--version"]) end) == "lmx #{Lemieux.version()}\n"
    end

    test "-v is an alias for --version" do
      assert capture_io(fn -> CLI.run(["-v"]) end) ==
               capture_io(fn -> CLI.run(["--version"]) end)
    end

    # The whole manual used to be the first screen: 172 lines that opened
    # with the research commands. The short help names the everyday
    # commands and options, and every flag is still one topic away.
    test "--help prints the short usage; every flag is a topic away" do
      output = capture_io(fn -> CLI.run(["--help"]) end)

      assert output =~ "lmx — an open-source terminal coding agent, built on Lemieux\n"
      assert output =~ "Usage:"
      assert output =~ "lmx [options]                 Open the full-screen agent"
      assert output =~ "--base-url"
      assert output =~ "$LMX_BASE_URL"
      assert output =~ "--version"
      refute output =~ "feedback draft-case"
      refute output =~ "--no-delegate"
      refute output =~ "minimal"

      options = capture_io(fn -> CLI.run(["help", "options"]) end)
      assert options =~ "--no-delegate"
      assert options =~ "--web-fetch"
    end

    # Reported from a real session: `mix lmx.tui --help` reached the option
    # parser and came back "unrecognised option --help". A help flag must
    # never be refused, whichever command it follows.
    test "every command answers a help flag rather than refusing it" do
      for argv <- [
            ["-h"],
            ["tui", "--help"],
            ["tui", "-h"],
            ["run", "--help"],
            ["feedback", "-h"],
            ["corpus", "--help"],
            ["tui", "--help", "--model", "openai:gpt-5.6"]
          ] do
        assert capture_io(fn -> CLI.run(argv) end) =~ "Usage:", "#{inspect(argv)} refused help"
      end
    end

    test "a value that happens to read like a help flag is still a value" do
      caller = self()
      runner = fn argv, _opts -> send(caller, {:tui, argv}) end

      assert CLI.run(["tui", "--system", "-h"], tui_runner: runner) ==
               {:tui, ["--system", "-h"]}
    end

    test "no arguments open the TUI" do
      caller = self()
      runner = fn argv, _opts -> send(caller, {:tui, argv}) end

      assert CLI.run([], tui_runner: runner) == {:tui, []}
      assert_received {:tui, []}
    end

    test "options without a command belong to the default TUI" do
      caller = self()
      runner = fn argv, _opts -> send(caller, {:tui, argv}) end

      assert CLI.run(["--model", "test:model"], tui_runner: runner) ==
               {:tui, ["--model", "test:model"]}

      assert_received {:tui, ["--model", "test:model"]}
    end

    test "unrecognised arguments fail with a non-zero status, and stay off stdout" do
      stdout =
        capture_io(fn ->
          capture_io(:stderr, fn -> send(self(), {:result, CLI.run(["--nope"])}) end)
        end)

      assert_received {:result, {:error, 1}}
      # Errors belong on stderr: anything on stdout would corrupt the output
      # of a command being piped somewhere.
      assert stdout == ""
    end

    test "an unrecognised option names the offending flag" do
      stderr = capture_io(:stderr, fn -> CLI.run(["--nope", "wat"]) end)

      assert stderr =~ "--nope"
    end

    # A word that is not a command is a different mistake from a bad flag, and
    # gets the usage text because the useful answer is the list of commands.
    test "an unrecognised command names it, and shows what there is" do
      stderr = capture_io(:stderr, fn -> CLI.run(["wat"]) end)

      assert stderr =~ "unrecognised arguments: wat"
      assert stderr =~ "Usage:"
    end
  end

  describe "run" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      %{
        store: JSONL.new(tmp_dir),
        supervisor: :"lemieux_cli_test_#{System.unique_integer([:positive])}"
      }
    end

    # The working directory is the test's own, so the workspace `lmx run` now
    # loads is this test's files rather than the repository's; and standard
    # input counts as a terminal unless a test says otherwise, so nothing
    # reads the real one.
    defp lmx(argv, context, script, extra \\ []) do
      opts =
        Keyword.merge(
          [
            provider: Scripted.new(script),
            store: context.store,
            supervisor: context.supervisor,
            cwd: context.tmp_dir,
            stdin_terminal?: true
          ],
          extra
        )

      # stderr is captured too, and separately: `lmx run` puts the session id
      # there, and a test that let it through would pass while the id was on
      # stdout corrupting the answer.
      stdout =
        capture_io(fn ->
          capture_io(:stderr, fn -> send(self(), {:status, CLI.run(argv, opts)}) end)
          |> then(&send(self(), {:stderr, &1}))
        end)

      assert_received {:status, status}
      assert_received {:stderr, stderr}

      %{status: status, stdout: stdout, stderr: stderr}
    end

    test "streams the reply to stdout and exits :ok", context do
      result =
        lmx(["run", "say hi"], context, [
          [{:text_delta, "he"}, {:text_delta, "llo"}, {:done, :stop}]
        ])

      assert result.status == :ok
      assert result.stdout == "hello\n"
    end

    # A limit that stopped the work is status 4, which a script can tell
    # apart from a failure: raising the limit is the fix, not retrying.
    test "a request blocked by unknown pricing fails instead of reporting empty success",
         context do
      provider = Scripted.new([])

      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(["run", "work"],
                     provider: provider,
                     store: context.store,
                     supervisor: context.supervisor,
                     cwd: context.tmp_dir,
                     max_cost_usd: 1.0
                   ) == {:error, 4}
          end)
        end)

      assert output =~ "did not complete"
      assert Scripted.requests(provider) == []
    end

    test "truncated model output is picked up once, then retained, and exits with failure",
         context do
      provider =
        Scripted.new([
          Scripted.complete("partial", finish_reason: :length),
          Scripted.complete("still partial", finish_reason: :length)
        ])

      result = lmx(["run", "work"], context, [], provider: provider)

      # The first cut-off is sent back (`Lemieux.Extensions.Continuation`);
      # the second, with nothing done in between, ends the run as it is.
      assert length(Scripted.requests(provider)) == 2
      assert result.status == {:error, 1}
      assert result.stdout == "still partial\n"
      assert result.stderr =~ "did not complete"
      assert result.stderr =~ "cut off at the model's output limit"
    end

    test "joins a multi-word prompt rather than dropping the tail", context do
      lmx(["run", "say", "hi", "please"], context, [[{:done, :stop}]])

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert {:ok, [_config, user | _]} = Store.read(context.store, session)
      assert user.payload == %{"text" => "say hi please"}
    end

    test "persists the transcript where a later command can find it", context do
      lmx(["run", "say hi"], context, [[{:text_delta, "hello"}, {:done, :stop}]])

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert {:ok, entries} = Store.read(context.store, session)
      assert %Lemieux.Entry{} = user = Enum.find(entries, &(&1.type == :user))
      assert %Lemieux.Entry{} = assistant = Enum.find(entries, &(&1.type == :assistant))
      assert user.type == :user
      assert assistant.payload["content"] == [%{"type" => "text", "text" => "hello"}]
    end

    test "names the session on stderr, where it cannot corrupt the answer", context do
      result = lmx(["run", "say hi"], context, [[{:text_delta, "hello"}, {:done, :stop}]])

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert result.stderr =~ "session #{session}"
      refute result.stdout =~ session
    end

    test "names each tool call on stderr, so a long run is not silent", context do
      call = %{id: "t1", name: "bash", arguments: %{"command" => "ls -la"}}

      result =
        lmx(["run", "look around"], context, [
          [{:tool_call, call}, {:done, :tool_calls}],
          [{:text_delta, "there are files"}, {:done, :stop}]
        ])

      assert result.stderr =~ "bash ls -la"
      assert result.stdout == "there are files\n"
    end

    test "with no prompt fails on stderr with the usage status", context do
      result = lmx(["run"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "needs a prompt"
      assert result.stdout == ""
    end

    test "rejects an unknown option rather than treating it as the prompt", context do
      result = lmx(["run", "--nope", "hi"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "unrecognised option --nope"
    end

    test "names a missing flag value as missing, not unrecognised", context do
      result = lmx(["run", "hi", "--output-format"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "missing value for --output-format"
    end

    test "--bare refuses the workspace flags it opted out of", context do
      result = lmx(["run", "--bare", "--skill-dir", "/tmp/skills", "hi"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "full TUI workspace experience"
      assert result.stdout == ""
    end

    test "a missing key reported by the provider exits with the credentials status", context do
      result = lmx(["run", "hi"], context, [[{:error, {:missing_api_key, :anthropic, "SET_ME"}}]])

      assert result.status == {:error, 3}
      assert result.stderr =~ "no API key for anthropic"
      assert result.stderr =~ "ANTHROPIC_API_KEY"
    end

    # A 500 is retried before it is reported, so the script fails three
    # times over — the attempts the policy allows plus the first — and the
    # delay is made negligible so the test measures the rendering, not the
    # backoff.
    test "renders typed provider failures at the CLI boundary", context do
      result =
        lmx(
          ["run", "hi"],
          context,
          List.duplicate(Scripted.http_error(500, reason: "provider unavailable"), 3),
          provider_retry: [base_delay_ms: 1]
        )

      assert result.status == {:error, 1}
      assert result.stderr =~ "provider unavailable"
      refute result.stderr =~ "%ReqLLM.Error"
    end

    test "keeps a partial answer that was interrupted", context do
      result = lmx(["run", "hi"], context, [[{:text_delta, "half a th"}, {:error, :closed}]])

      assert result.status == {:error, 1}
      assert result.stdout == "half a th\n"
    end

    test "--model overrides the default", context do
      provider = Scripted.new([[{:done, :stop}]])

      opts = [provider: provider, store: context.store, supervisor: context.supervisor]

      capture_io(fn ->
        capture_io(:stderr, fn -> CLI.run(["run", "-m", "openai:gpt-5", "hi"], opts) end)
      end)

      assert [%{model: "openai:gpt-5"}] = Scripted.requests(provider)
    end

    test "run uses --system verbatim without TUI workspace discovery", context do
      provider = Scripted.new([[{:done, :stop}]])
      opts = [provider: provider, store: context.store, supervisor: context.supervisor]

      capture_io(fn ->
        capture_io(:stderr, fn -> CLI.run(["run", "--system", "be terse", "hi"], opts) end)
      end)

      assert [%{system: "be terse"}] = Scripted.requests(provider)
    end

    test "--hooks runs command hooks from the named file", context do
      config = Path.join(context.store |> elem(1) |> Map.fetch!(:dir), "hooks.json")

      File.write!(
        config,
        JSON.encode!(%{
          "version" => 1,
          "hooks" => %{
            "preToolUse" => [
              %{"matcher" => "bash", "command" => "echo 'not in CI' >&2; exit 2"}
            ]
          }
        })
      )

      call = %{id: "t1", name: "bash", arguments: %{"command" => "echo should-not-run"}}

      lmx(["run", "--hooks", config, "work"], context, [
        [{:tool_call, call}, {:done, :tool_calls}],
        [{:done, :stop}]
      ])

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert {:ok, entries} = Store.read(context.store, session)
      result = Enum.find(entries, &(&1.type == :tool_result))
      assert result.payload["error"] == true
      assert result.payload["output"] =~ "not in CI"
    end

    # Reported from a real run: the narration before each tool call used to
    # stream to stdout too, so `> answer.md` held "I'll read the
    # README.Here's…" instead of the answer.
    test "text mode writes only the final answer to stdout", context do
      call = %{id: "t1", name: "bash", arguments: %{"command" => "echo hi"}}

      result =
        lmx(["run", "look around"], context, [
          [{:text_delta, "Let me look first."}, {:tool_call, call}, {:done, :tool_calls}],
          [{:text_delta, "It says hi."}, {:done, :stop}]
        ])

      assert result.status == :ok
      assert result.stdout == "It says hi.\n"
      refute result.stderr =~ "Let me look first."
      assert result.stderr =~ "bash echo hi"
    end

    test "--output-format json writes one result object", context do
      result =
        lmx(["run", "--output-format", "json", "hi"], context, [
          [{:text_delta, "hello"}, {:done, :stop}]
        ])

      assert result.status == :ok
      assert {:ok, [session]} = Store.list_sessions(context.store)

      assert %{
               "type" => "result",
               "session_id" => ^session,
               "text" => "hello",
               "stop_reason" => "stop",
               "error" => nil,
               "exit_status" => 0,
               "usage" => usage
             } = JSON.decode!(result.stdout)

      assert is_map(usage)
    end

    test "--output-format json reports a failure in the same object", context do
      result =
        lmx(["run", "--output-format", "json", "hi"], context, [
          [{:error, {:missing_api_key, :anthropic, "SET_ME"}}]
        ])

      assert result.status == {:error, 3}

      assert %{"exit_status" => 3, "error" => %{"category" => "auth", "message" => message}} =
               JSON.decode!(result.stdout)

      assert message =~ "ANTHROPIC_API_KEY"
    end

    test "--output-format stream-json writes one event per line, ending with the result",
         context do
      call = %{id: "t1", name: "bash", arguments: %{"command" => "echo hi"}}

      result =
        lmx(["run", "--output-format", "stream-json", "look around"], context, [
          [{:text_delta, "Let me look."}, {:tool_call, call}, {:done, :tool_calls}],
          [{:text_delta, "It says hi."}, {:done, :stop}]
        ])

      assert result.status == :ok
      events = result.stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      types = Enum.map(events, & &1["type"])

      assert hd(types) == "session"
      assert List.last(types) == "result"
      assert "tool_call" in types

      assert %{"name" => "bash", "error" => false, "output" => output} =
               Enum.find(events, &(&1["type"] == "tool_result"))

      assert output =~ "hi"
      assert %{"text" => "It says hi.", "exit_status" => 0} = List.last(events)

      # Standard error is captured globally, so other async tests may write
      # to it; what this run must not put there is its own announcement.
      assert %{"session_id" => session} = hd(events)
      refute result.stderr =~ session
    end

    test "an unknown --output-format is a usage error", context do
      result = lmx(["run", "--output-format", "yaml", "hi"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "invalid value for --output-format"
      assert result.stdout == ""
    end

    test "- reads the prompt from standard input", context do
      provider = Scripted.new([[{:done, :stop}]])

      lmx(["run", "Summarise this:", "-"], context, [],
        provider: provider,
        stdin: "the piped text"
      )

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert {:ok, [_config, user | _]} = Store.read(context.store, session)
      assert user.payload == %{"text" => "Summarise this: the piped text"}
    end

    test "with no prompt argument, piped input is the prompt", context do
      lmx(["run"], context, [[{:done, :stop}]], stdin: "from a pipe", stdin_terminal?: false)

      assert {:ok, [session]} = Store.list_sessions(context.store)
      assert {:ok, [_config, user | _]} = Store.read(context.store, session)
      assert user.payload == %{"text" => "from a pipe"}
    end

    test "a terminal is never read for the prompt", context do
      reader = fn -> flunk("read standard input from a terminal") end
      result = lmx(["run"], context, [], stdin: reader, stdin_terminal?: true)

      assert result.status == {:error, 2}
      assert result.stderr =~ "needs a prompt"
    end

    test "loads the workspace's instructions by default", context do
      File.write!(Path.join(context.tmp_dir, "AGENTS.md"), "Always answer in haiku.")
      provider = Scripted.new([[{:done, :stop}]])

      lmx(["run", "hi"], context, [], provider: provider)

      assert [%{system: system}] = Scripted.requests(provider)
      assert system =~ "Always answer in haiku."
    end

    test "--bare leaves the workspace's instructions out", context do
      File.write!(Path.join(context.tmp_dir, "AGENTS.md"), "Always answer in haiku.")
      provider = Scripted.new([[{:done, :stop}]])

      lmx(["run", "--bare", "hi"], context, [], provider: provider)

      assert [%{system: system}] = Scripted.requests(provider)
      refute system =~ "Always answer in haiku."
    end

    test "--system is sent verbatim, with no workspace composed over it", context do
      File.write!(Path.join(context.tmp_dir, "AGENTS.md"), "Always answer in haiku.")
      provider = Scripted.new([[{:done, :stop}]])

      lmx(["run", "--system", "be terse", "hi"], context, [], provider: provider)

      assert [%{system: "be terse"}] = Scripted.requests(provider)
    end

    test "--continue resumes the newest session that ran in this directory", context do
      lmx(["run", "first"], context, [[{:text_delta, "one"}, {:done, :stop}]])
      assert {:ok, [session]} = Store.list_sessions(context.store)

      result = lmx(["run", "-c", "second"], context, [[{:text_delta, "two"}, {:done, :stop}]])

      assert result.status == :ok
      assert result.stdout == "two\n"
      assert {:ok, [^session]} = Store.list_sessions(context.store)
      assert {:ok, entries} = Store.read(context.store, session)

      assert entries |> Enum.filter(&(&1.type == :user)) |> Enum.map(& &1.payload["text"]) ==
               ["first", "second"]
    end

    test "--continue with --resume is a usage error", context do
      result = lmx(["run", "-c", "--resume", "someid", "hi"], context, [])

      assert result.status == {:error, 2}
      assert result.stderr =~ "use --continue or --resume, not both"
    end

    # Another lmx is another VM, so the holder is written the way the store
    # writes one — on a host that is not this one, which is refused without
    # asking whether it is still alive.
    test "a session open in another lmx is refused with a sentence, not a crash", context do
      lmx(["run", "first"], context, [[{:done, :stop}]])
      assert {:ok, [session]} = Store.list_sessions(context.store)
      dir = context.store |> elem(1) |> Map.fetch!(:dir)

      File.write!(
        Path.join(dir, session <> ".lock"),
        JSON.encode!(%{
          "token" => "held-elsewhere",
          "host" => "another-host.invalid",
          "os_pid" => "4242",
          "node" => "nonode@another",
          "process" => "<0.1.0>",
          "since" => "2026-09-29T08:00:00Z"
        })
      )

      result = lmx(["run", "--resume", session, "again"], context, [])

      assert result.status == {:error, 1}
      assert result.stderr =~ "open in another lmx"
      assert result.stderr =~ "pid 4242"
      assert result.stdout == ""
    end

    # The preflight runs only when lmx resolves the provider itself; a host
    # that supplies one (as the other tests do) answers for its credentials.
    test "a model with no key stops before a session starts, with the credentials status",
         context do
      output =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert CLI.run(["run", "--model", "anthropic:claude-sonnet-4-5", "hi"],
                     store: context.store,
                     supervisor: context.supervisor,
                     cwd: context.tmp_dir,
                     env: %{}
                   ) == {:error, 3}
          end)
        end)

      assert output =~ "no API key for anthropic"
      assert output =~ "ANTHROPIC_API_KEY"
      assert Store.list_sessions(context.store) == {:ok, []}
    end
  end
end
