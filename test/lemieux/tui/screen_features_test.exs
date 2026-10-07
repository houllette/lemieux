defmodule Lemieux.TUI.ScreenFeaturesTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Entry
  alias Lemieux.Extensions.Permissions
  alias Lemieux.TUI
  alias Lemieux.TUI.Appearance
  alias Lemieux.TUI.Diff
  alias Lemieux.TUI.FileIndex
  alias Lemieux.TUI.History
  alias Lemieux.TUI.MCPForm
  alias Lemieux.TUI.MCPStatus
  alias Lemieux.TUI.Setup
  alias Lemieux.TUI.Theme
  alias Lemieux.TUI.ToolText

  describe "answers that commands send back" do
    test "a /diff result reaches the screen" do
      state = tui()

      assert {:noreply, shown} =
               TUI.handle_info({:diff_result, {:ok, "diff --git a/x b/x"}}, state)

      assert screen(shown) =~ "diff --git a/x b/x"
    end
  end

  describe "a unified diff" do
    test "numbers each side and keeps only the context around a change" do
      old = Enum.map(1..20, &"line #{&1}")
      new = List.replace_at(old, 9, "line ten")

      lines = Diff.unified(old, new, old_start: 100, new_start: 100, context: 2)

      assert {:delete, 109, nil, "line 10"} in lines
      assert {:add, nil, 109, "line ten"} in lines
      assert {:context, 107, 107, "line 8"} in lines
      refute Enum.any?(lines, &match?({:context, 101, _, _}, &1))
      assert [{:gap, 7} | _rest] = lines
      assert Diff.counts(lines) == {1, 1}
    end

    test "an edit is drawn as its change, numbered from the lines the tool returned" do
      output = "edited a.ex (1 occurrence replaced)\n\n11\tdef a do\n12\t  :new\n13\tend"
      arguments = %{"path" => "a.ex", "old" => "  :old", "new" => "  :new"}

      rows = ToolText.edit_rows("c1", arguments, Theme.mono(), output)

      assert [{:tool_heading, "c1", :edit, "Edited", "a.ex (+1 -1)"} | code] = rows
      numbered = for {:tool_code, "c1", change, number, _spans} <- code, do: {change, number}
      assert {:delete, 12} in numbered
      assert {:add, 12} in numbered
      assert {:context, 11} in numbered
    end

    test "an overwrite is never drawn as removing nothing" do
      rows =
        ToolText.write_rows(
          "w1",
          %{"path" => "a.ex", "content" => "a\nb"},
          Theme.mono(),
          "overwrote a.ex (3 bytes)"
        )

      assert [{:tool_heading, "w1", :write, "Overwrote", "a.ex (2 lines)"} | _code] = rows

      diffed = ToolText.diff_write_rows("w1", "a.ex", "a\nc", "a\nb", Theme.mono())
      assert [{:tool_heading, "w1", :write, "Overwrote", "a.ex (+1 -1)"} | _rest] = diffed
    end
  end

  describe "the pager" do
    test "opens on the last tool output in full and closes on q" do
      state = tui()
      assert state |> press("o", ["ctrl"]) |> Map.get(:modal) == nil

      output = Enum.map_join(1..30, "\n", &"row #{&1}")
      state = TUI.Pager.remember(state, "c1", "bash", output)
      paged = press(state, "o", ["ctrl"])

      assert %{kind: :pager} = paged.modal
      assert screen(paged) =~ "row 15"
      assert press(paged, "q").modal == nil
    end
  end

  describe "history" do
    @tag :tmp_dir
    test "is read from the history file and searched with ctrl-r", %{tmp_dir: dir} do
      file = Path.join(dir, "history.jsonl")
      File.write!(file, ~s({"text":"deploy the thing"}\n{"text":"run the tests"}\nnot json\n))

      loaded = History.loaded(file)
      assert loaded.global == ["run the tests", "deploy the thing"]

      state = tui() |> Map.put(:history, loaded) |> press("r", ["ctrl"]) |> type("depl")
      assert TUI.HistorySearch.matches(state) == ["deploy the thing"]

      taken = press(state, "enter")
      assert taken.modal == nil
      assert typed(taken) == "deploy the thing"
    end

    @tag :tmp_dir
    test "a sent input is appended to the file, privately", %{tmp_dir: dir} do
      file = Path.join(dir, "history.jsonl")
      assert :ok = History.append_global(file, "first\nline")
      assert File.read!(file) =~ ~s("text":"first\\nline")
      assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
    end
  end

  describe "writing a long input" do
    test "ctrl-j and a trailing backslash insert a newline instead of sending" do
      state = tui() |> type("one") |> press("j", ["ctrl"]) |> type("two\\") |> press("enter")
      assert typed(state) == "one\ntwo\n"
    end

    test "ctrl-g hands the text to the editor and takes back what was saved" do
      editor = fn text -> {:ok, text <> " edited"} end
      state = built(editor: editor) |> type("draft") |> press("g", ["ctrl"])

      assert typed(state) == "draft edited"
      assert state.terminal.repaint == 1
      assert_received :repaint_done
      assert {:noreply, drawn} = TUI.handle_info(:repaint_done, state)
      assert drawn.terminal.repaint == 0
    end

    test "ctrl-g says so when there is no local terminal to hand over" do
      state = built(editor: nil) |> type("draft") |> press("g", ["ctrl"])
      assert typed(state) == "draft"
      assert state.terminal.feedback.text =~ "local terminal"
    end
  end

  describe "pasting an image" do
    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>

    @tag :tmp_dir
    test "writes it under .lmx/pastes, ignored, and attaches it as a reference", %{tmp_dir: dir} do
      state = built(cwd: dir, paste_image: fn -> {:ok, @png} end) |> press("v", ["ctrl"])
      assert_receive {:image_pasted, {:ok, path} = result}

      assert {:noreply, attached} = TUI.handle_info({:image_pasted, result}, state)
      assert typed(attached) == "@#{path} "
      assert File.read!(Path.join(dir, path)) == @png
      assert File.read!(Path.join(dir, ".lmx/pastes/.gitignore")) == "*\n"
    end

    test "refuses what is not a PNG" do
      runner = fn "xclip", _args, _opts -> {"not an image", 0} end

      assert {:error, _reason} =
               TUI.ImagePaste.capture(
                 os: {:unix, :linux},
                 env: %{"DISPLAY" => ":0"},
                 runner: runner
               )
               |> then(fn
                 {:error, reason} -> {:error, reason}
                 other -> other
               end)
    end
  end

  describe "the fuzzy @ picker" do
    test "ranks a match in the file name above one spread across directories" do
      files = ["test/unit/renderer.ex", "lib/lemieux/turn.ex", "lib/tour/unit.ex"]
      assert ["lib/lemieux/turn.ex" | _rest] = FileIndex.match(files, "turn")
      assert FileIndex.match(files, "zzz") == []
    end

    @tag :tmp_dir
    test "offers matches from the index for what is typed after @", %{tmp_dir: dir} do
      state = tui(cwd: dir)

      state = %{
        state
        | references: %{
            state.references
            | index: %{files: ["lib/lemieux/composer.ex", "README.md"], at: state.clock.()}
          }
      }

      offered = state |> type("look at @compos") |> suggestions()
      assert offered.items == ["lib/lemieux/composer.ex"]
    end
  end

  describe "notifications" do
    test "a long turn's end notifies, and alt-n turns it off" do
      parent = self()

      notify = fn text ->
        send(parent, {:notified, text})
        :ok
      end

      state = built(notify: notify, clock: fn -> 60_000 end)

      state = %{
        state
        | conversation: %{state.conversation | busy?: true},
          turn: %{state.turn | started_at: 0}
      }

      _finished = info(state, {:finished, :stop})
      assert_received {:notified, "lmx: finished (60s)"}

      quiet = press(state, "n", ["alt"])
      refute quiet.terminal.notifications?
      _finished = info(quiet, {:finished, :stop})
      refute_received {:notified, _text}
    end
  end

  describe "NO_COLOR" do
    test "starts in the colourless theme unless a theme was chosen by name" do
      assert built(env: %{"NO_COLOR" => "1"}).appearance.theme.name == "mono"
      assert built(env: %{"NO_COLOR" => "1"}, theme: "light").appearance.theme.name == "light"
      assert built(env: %{}).appearance.theme == nil
    end

    # An inherited `NO_COLOR` looks exactly like a terminal without colour;
    # the screen says which it is, and where the variable came from (issue #4).
    test "the startup notice and /theme say it is in effect, and where to unset it" do
      mono = built(env: %{"NO_COLOR" => "1"}) |> Setup.notices(["something else"])

      assert notice_texts(mono) == [
               "something else",
               "NO_COLOR is set in the environment lmx started in, so the screen has no colour " <>
                 "(theme mono). Unset it where lmx is launched for colour."
             ]

      assert screen(Appearance.theme_status(mono)) =~ "theme: mono (NO_COLOR is set)"

      named = built(env: %{"NO_COLOR" => "1"}, theme: "light") |> Setup.notices(nil)

      assert notice_texts(named) == [
               "NO_COLOR is set in the environment lmx started in, so the terminal draws no " <>
                 "colour whatever the theme. Unset it where lmx is launched for colour."
             ]

      assert screen(Appearance.theme_status(named)) =~
               "theme: light (NO_COLOR is set, so no colour is drawn)"

      quiet = built(env: %{}) |> Setup.notices(nil)
      assert notice_box(quiet) == nil
      refute screen(Appearance.theme_status(quiet)) =~ "NO_COLOR"
    end
  end

  describe "permissions" do
    @tag :tmp_dir
    test "shift-tab steps the mode and the status line says which", %{tmp_dir: dir} do
      {:ok, handle} = Permissions.new(mode: :ask, store: Path.join(dir, "rules.json"))
      state = built(permissions: handle)

      assert status_text(state) =~ "⏵ ask"
      stepped = press(state, "back_tab")
      assert Permissions.mode(handle) == :accept_edits
      assert stepped.terminal.feedback.text =~ "accept edits"
    end

    @tag :tmp_dir
    test "a on the approval card remembers the suggestion and lets the call run", %{tmp_dir: dir} do
      {:ok, handle} = Permissions.new(mode: :ask, store: Path.join(dir, "rules.json"))
      session = fake_session(snapshot("01SESSION"))

      permission = %{
        "mode" => "ask",
        "reason" => "bash changes things",
        "suggestions" => [%{"label" => "Always allow `mix test …`", "rule" => "Bash(mix test:*)"}]
      }

      call = %{
        id: "c1",
        name: "bash",
        arguments: %{"command" => "mix test"},
        permission: permission
      }

      state = built(session: session, permissions: handle) |> info({:tool_approval, call})

      assert screen(state) =~ "a · Always allow `mix test …`"
      _allowed = state |> type("a") |> press("enter")

      assert_received {:resolved, "c1", :allow}
      assert "Bash(mix test:*)" in Permissions.remembered(handle)
    end

    test "the banner says every call runs unasked when permissions are off" do
      state = TUI.Policy.banner(built(permissions: nil, sandbox: nil))
      assert screen(state) =~ "full auto: tools run without asking"
      assert screen(state) =~ "not sandboxed"
      refute screen(TUI.Policy.banner(tui())) =~ "full auto"
    end
  end

  describe "what the session reports" do
    test "requests count against the cap on the status line" do
      state = built(request_cap: 20) |> info({:entry, Entry.new(:request, %{})})
      assert status_text(state) =~ "req 1/20"
    end

    test "an MCP server connecting, failing and connecting shows where a person looks" do
      state = info(tui(), {:mcp_server, %{name: "github", status: :connecting, tool_count: 0}})
      assert status_text(state) =~ "connecting github"

      failed =
        info(
          state,
          {:mcp_server, %{name: "github", status: :failed, error: "boom", tool_count: 0}}
        )

      assert screen(failed) =~ "github is unavailable: boom"

      ready =
        info(state, {:ready, %{mcp: [%{name: "github", status: :connected, tool_count: 3}]}})

      assert screen(ready) =~ "MCP connected: github (3 tools)"
      refute status_text(ready) =~ "connecting"
    end

    # The race behind a status line that said "connecting tidewave…" forever:
    # the server failed before the screen knew the session's id, so both
    # events were dropped and only the connecting snapshot remained.
    test "a server that settled before the screen knew its session is caught up" do
      failed = %{name: "tidewave", status: :failed, error: "connection refused", tool_count: 0}
      session = fake_session(snapshot("02MCPRACE"), mcp_statuses: [failed])
      state = connecting(tui(session: session), "tidewave")

      assert status_text(state) =~ "connecting tidewave"
      assert MCPStatus.watch(state) == state
      assert_receive {:mcp_settled, ^session, statuses}

      settled = MCPStatus.settled(state, session, statuses)
      refute status_text(settled) =~ "connecting"
      assert screen(settled) =~ "tidewave is unavailable: connection refused"
      assert screen(settled) =~ "/mcp reconnects it"
    end

    test "the same settling reported twice is announced once" do
      session = fake_session(snapshot("02MCPTWICE"))
      connected = [%{name: "github", status: :connected, tool_count: 3}]
      state = connecting(tui(session: session), "github")

      once = info(state, {:ready, %{mcp: connected}})
      twice = MCPStatus.settled(once, session, connected)

      assert twice |> screen() |> String.split("MCP connected") |> length() == 2
    end

    test "a settled answer for a session the screen has left is ignored" do
      state = connecting(tui(session: fake_session(snapshot("02MCPNOW"))), "tidewave")
      other = fake_session(snapshot("02MCPTHEN"))
      failed = %{name: "tidewave", status: :failed, error: "connection refused", tool_count: 0}

      assert MCPStatus.settled(state, other, [failed]) == state
    end

    test "a session already settled when adopted says what failed and connected at once" do
      state =
        tui()
        |> put_in([Access.key!(:session_view), :mcp_ready?], true)
        |> put_in([Access.key!(:session_view), :mcp], %{
          "tidewave" => %{name: "tidewave", status: :failed, error: "connection refused"},
          "github" => %{name: "github", status: :connected, tool_count: 2}
        })

      shown = MCPStatus.watch(state)
      assert screen(shown) =~ "tidewave is unavailable: connection refused"
      assert screen(shown) =~ "MCP connected: github (2 tools)"
    end

    test "the plan is drawn while a task is open" do
      plan = %{"tasks" => [%{"id" => "1", "title" => "write tests", "status" => "in_progress"}]}

      entry =
        Entry.new(:extension_state, %{
          "namespace" => "lemieux.plan",
          "revision" => 1,
          "value" => plan
        })

      state = info(sized(tui()), {:entry, entry})
      assert screen(state) =~ "plan 0/1"
      assert screen(state) =~ "write tests"
    end

    test "a broken-off answer is marked, not read as the answer" do
      entry =
        Entry.new(:assistant, %{
          "content" => [%{"type" => "text", "text" => "half"}],
          "partial" => true
        })

      assert screen(info(tui(), {:entry, entry})) =~ "interrupted"
    end

    test "a verify report is drawn in the harness's voice" do
      entry = Entry.new(:user, %{"text" => "[lmx verify] mix test failed"})
      state = info(tui(), {:entry, entry})
      assert Enum.any?(state.lines, &match?({:verify, "mix test failed"}, &1))

      marked = Entry.new(:user, %{"text" => "[lmx verify] mix test failed", "stop_hook" => true})
      state = info(tui(), {:entry, marked})
      assert Enum.any?(state.lines, &match?({:verify, "mix test failed"}, &1))
    end

    test "any stop hook's message is drawn in the harness's voice, without its tag" do
      entry =
        Entry.new(:user, %{
          "text" => "[lmx continue] You ended your turn, but your plan still has open tasks:",
          "stop_hook" => true
        })

      state = info(tui(), {:entry, entry})

      assert Enum.any?(
               state.lines,
               &match?({:hook, "You ended your turn, but your plan still has open tasks:"}, &1)
             )

      assert screen(state) =~ "↻ You ended your turn"

      # A command hook's words carry no tag, and are still not the person's.
      plain = Entry.new(:user, %{"text" => "run the linter first", "stop_hook" => true})

      assert Enum.any?(
               info(tui(), {:entry, plain}).lines,
               &(&1 == {:hook, "run the linter first"})
             )

      # What the person typed is drawn when it is submitted, never again here.
      typed = Entry.new(:user, %{"text" => "[lmx continue] my own words"})
      refute Enum.any?(info(tui(), {:entry, typed}).lines, &match?({:hook, _}, &1))
    end

    test "an unknown context window is said once" do
      event = {:context_window_unknown, %{model: "x:y", fallback: 128_000}}
      state = tui() |> info(event) |> info(event)

      assert Enum.count(
               state.lines,
               &match?({:notice, "nothing publishes x:y's context window" <> _}, &1)
             ) == 1
    end
  end

  describe "a session that stopped" do
    test "is said, and a prompt waits for it to come back rather than crashing" do
      session = spawn(fn -> receive do: (:never -> :ok) end)
      state = built(session: session)
      ref = Process.monitor(session)
      state = put_in(state.resume.monitor, ref)
      Process.exit(session, :kill)
      assert_receive {:DOWN, ^ref, :process, _pid, :killed} = down

      assert {:noreply, stopped} = TUI.handle_info(down, state)
      assert screen(stopped) =~ "the session stopped"

      waiting = stopped |> type("hello") |> press("enter")
      assert typed(waiting) == "hello"
      assert waiting.terminal.feedback.text =~ "resumes it"
    end
  end

  describe "the MCP add form" do
    test "keeps secrets out of the saved configuration" do
      server = %{
        "name" => "linear",
        "transport" => "http",
        "url" => "https://mcp.example",
        "headers" => %{"Authorization" => "Bearer abcdefghijklmnopqrstuvwxyz"}
      }

      {saved, withheld} = MCPForm.withheld(server)
      assert saved["headers"]["Authorization"] == "Bearer ${MCP_LINEAR_AUTHORIZATION}"
      assert withheld == [{"MCP_LINEAR_AUTHORIZATION", "abcdefghijklmnopqrstuvwxyz"}]

      {kept, []} =
        MCPForm.withheld(%{server | "headers" => %{"Authorization" => "Bearer ${TOKEN}"}})

      assert kept["headers"]["Authorization"] == "Bearer ${TOKEN}"
    end
  end

  describe "while the session starts" do
    test "typing is kept, Enter queues it, and /quit still leaves" do
      state = put_in(tui().resume.startup_status, :loading)

      queued = state |> type("hello") |> press("enter")
      assert queued.history.queued == ["hello"]
      assert typed(queued) == ""

      assert {:stop, _state} = TUI.handle_event(key("enter"), type(state, "/quit"))
    end

    test "after a failure, /model starts again with the new model" do
      parent = self()
      {:ok, tasks} = Task.Supervisor.start_link()

      start = fn _app, overrides ->
        send(parent, {:started_with, overrides})
        {:error, "still failing"}
      end

      state = built(start_async: start, task_supervisor: tasks)
      state = put_in(state.resume.startup_status, :failed)

      retried = state |> type("/model other:model") |> press("enter")
      assert retried.resume.startup_status == :loading
      assert_receive {:started_with, [model: "other:model"]}
    end
  end

  describe "a repository's MCP servers" do
    @tag :tmp_dir
    test "are asked about, and a no is remembered", %{tmp_dir: dir} do
      servers = [%{"name" => "tool", "transport" => "stdio", "command" => "run-it"}]

      pending = %{
        file: Path.join(dir, ".mcp.json"),
        workspace: dir,
        servers: servers,
        status: :untrusted,
        description: Lemieux.MCP.Trust.describe(servers)
      }

      state = TUI.Trust.checked(built(mcp_trust: %{store: dir, cwd: dir}), pending)
      assert %{kind: :trust} = state.modal
      assert screen(state) =~ "runs run-it"

      declined = press(state, "2")
      assert declined.modal == nil
      assert_receive {:mcp_trust_result, :denied, :ok, _file}
      assert Lemieux.MCP.Trust.status(dir, dir, servers) == :denied
    end

    # A decision is one digest over the servers asked about. Asked over the
    # whole file, the screen used to record a digest the extension, which
    # leaves out the servers the host's own configuration replaces, never
    # matched: held as "changed" on every start, and never asked about again.
    @tag :tmp_dir
    test "leave out the servers the host's own configuration replaces", %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))

      File.write!(
        Path.join(dir, ".mcp.json"),
        ~s({"mcpServers":{"shell":{"command":"local-server"},"docs":{"command":"docs-server"}}})
      )

      TUI.Trust.check(built(mcp_trust: %{store: dir, cwd: dir, except: ["shell"]}))

      assert_receive {:mcp_trust_check, %{servers: [%{"name" => "docs"}]}}
    end
  end

  describe "the first-run panel" do
    @tag :tmp_dir
    test "saves the key and uses the provider's model", %{tmp_dir: dir} do
      env = "LMX_FIRST_RUN_TEST_#{System.unique_integer([:positive])}"
      on_exit(fn -> System.delete_env(env) end)
      provider = %{id: "zz", label: "ZZ", env: env, model: "zz:model"}
      config = Path.join(dir, "config.json")

      state = TUI.FirstRun.open(built(first_run: %{providers: [provider], config_path: config}))
      assert screen(state) =~ "No model credentials were found"

      state = state |> press("down") |> press("enter") |> type("secret-key")
      refute screen(state) =~ "secret-key"
      state = press(state, "enter")

      assert state.modal == nil
      assert_receive {:first_run_saved, ^provider, {:ok, _saved?} = result}
      assert System.get_env(env) == "secret-key"
      assert {:noreply, said} = TUI.handle_info({:first_run_saved, provider, result}, state)

      # The notice names the config file by its absolute path, so where the
      # 80-column frame wraps depends on where the checkout is. A newline
      # between the two words failed this on every run in /workspaces/lemieux
      # and /home/alice/lemieux, and passed in CI's longer path.
      assert screen(said) =~ ~r/using\s+zz:model/
    end
  end

  describe "tool calls drawn as changes" do
    @tag :tmp_dir
    test "an overwrite's replaced contents come back from its checkpoint", %{tmp_dir: dir} do
      store = Path.join(dir, "checkpoints")
      File.write!(Path.join(dir, "a.txt"), "before\n")
      context = %{cwd: dir, session_id: "01CHECKPOINT", call_id: "c1"}

      assert {:ok, _turn} = Lemieux.Checkpoint.begin_turn(store, "01CHECKPOINT")
      assert :ok = Lemieux.Checkpoint.capture(store, context, "a.txt", tool: "write")

      assert TUI.WriteDiff.previous(store, "01CHECKPOINT", "c1") == {:ok, "before\n"}
      assert TUI.WriteDiff.previous(store, "01CHECKPOINT", "c2") == :none
    end

    test "a patch is drawn per file, from the tool's own parser" do
      patch = """
      *** Begin Patch
      *** Add File: new.ex
      +one
      *** Update File: old.ex
      @@ def a
      -  :old
      +  :new
      *** End Patch
      """

      call = %{id: "p1", name: "apply_patch", arguments: %{"input" => patch}}

      {:replace, rows} =
        ToolText.result(call, %{"error" => false, "output" => "Success."}, Theme.mono())

      headings = for {:tool_heading, "p1", _kind, verb, subject} <- rows, do: "#{verb} #{subject}"
      assert headings == ["Added new.ex (+1)", "Updated old.ex (+1 -1)"]
    end
  end

  # `TestSupport.tui/1` places the options it knows and writes the rest over
  # the struct; the host fields this file exercises are options `TUI.new/1`
  # reads, so they go straight to it.
  defp built(opts),
    do: TUI.new([id: "01SESSION", model: "test:model", test_mode: {80, 24}] ++ opts)

  # The notice box as one line of text per notice: the box wraps a long
  # sentence over several rows, so rows are joined back and the warning glyph
  # that opens each notice is where one ends and the next begins.
  defp notice_texts(state) do
    {%ExRatatui.Widgets.Paragraph{text: lines}, _rect} = notice_box(state)

    lines
    |> Enum.map_join(" ", fn line -> Enum.map_join(line.spans, & &1.content) end)
    |> String.split("⚠ ", trim: true)
    |> Enum.map(&(&1 |> String.split() |> Enum.join(" ")))
  end

  # A screen told that `name` is connecting, and nothing since.
  defp connecting(state, name) do
    state
    |> put_in([Access.key!(:session_view), :mcp_ready?], false)
    |> put_in([Access.key!(:session_view), :mcp], %{
      name => %{name: name, status: :connecting, tool_count: 0}
    })
  end

  defp status_text(state) do
    case status_row(state) do
      text when is_binary(text) ->
        text

      lines ->
        Enum.map_join(
          List.wrap(lines),
          " ",
          &Enum.map_join(&1.spans, fn span -> span.content end)
        )
    end
  end
end
