# A session whose stop can be held open, so a test can see what is doing
# the stopping while it happens. Compiled before the async test module, as
# `Lemieux.TUI.KeysTest.Vi` is.
defmodule Lemieux.TUI.TerminalCompatTest.HeldSession do
  @moduledoc false
  use GenServer

  @impl GenServer
  def init(test), do: {:ok, test}

  # Held until the test says so, or until the test is gone. It used to give
  # up after two seconds, so a test the machine was slow to schedule could
  # look for the stopper after it had already finished.
  @impl GenServer
  def terminate(_reason, test) do
    send(test, {:stopping, self()})
    test_ref = Process.monitor(test)

    receive do
      :go_on -> :ok
      {:DOWN, ^test_ref, :process, ^test, _reason} -> :ok
    end
  end
end

defmodule Lemieux.TUI.TerminalCompatTest do
  @moduledoc """
  What the screen does differently depending on the terminal it is in: line
  endings in a paste, AltGr on Windows, a pale background, a terminal
  without 24-bit colour, a missing `sh`, keys that macOS terminals never
  send, and being told to stop.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Lemieux.TUI.TestSupport

  alias ExRatatui.Event.Paste
  alias ExRatatui.Frame
  alias ExRatatui.Style
  alias Lemieux.TUI
  alias Lemieux.TUI.ExternalEditor
  alias Lemieux.TUI.Keys
  alias Lemieux.TUI.Lifecycle
  alias Lemieux.TUI.Screen
  alias Lemieux.TUI.Signals
  alias Lemieux.TUI.Theme

  @frame %Frame{width: 80, height: 24}

  describe "input" do
    test "a paste keeps its lines whatever line ending the terminal used" do
      for content <- ["one\ntwo\nthree", "one\rtwo\rthree", "one\r\ntwo\r\nthree"] do
        state = tui()
        assert {:noreply, state} = TUI.handle_event(%Paste{content: content}, state)
        assert typed(state) == "one\ntwo\nthree"
      end
    end

    test "characters typed with AltGr, which Windows reports as Ctrl+Alt, are inserted" do
      for char <- ["@", "{", "[", "|", "~", "\\", "€", "ł"] do
        assert typed(press(tui(), char, ["ctrl", "alt"])) == char
      end
    end

    test "Ctrl+Alt with an ASCII letter is still not text" do
      assert typed(press(tui(), "q", ["ctrl", "alt"])) == ""
    end
  end

  describe "taking back a steer" do
    defp working do
      session = fake_session(snapshot("01SESSION"))
      state = tui(session: session) |> sized()
      %{state | conversation: %{state.conversation | busy?: true}}
    end

    defp steered(state, text) do
      state = state |> type(text) |> press("enter")
      assert_receive {:steered, ^text}
      state
    end

    defp pending?(state), do: Enum.any?(state.lines, &match?({:steer, :pending, _text}, &1))

    test "the waiting steer says how to take it back, and a second one points at /unsteer" do
      pending = steered(working(), "do this first")

      assert screen(pending) =~ "/unsteer takes it back"

      blocked = pending |> type("another steer") |> press("enter")
      assert status_row(blocked) =~ "one steer is already waiting · /unsteer takes it back"
      refute status_row(blocked) =~ "Cmd+Z"
    end

    test "/unsteer revokes it, removes its row, and the next steer is sent" do
      pending = steered(working(), "do this first")
      assert pending?(pending)

      revoked = command(pending, "/unsteer")

      refute pending?(revoked)
      assert screen(revoked) =~ "steer revoked before the next model request"

      sent = steered(revoked, "do this instead")
      assert Enum.any?(sent.lines, &(&1 == {:steer, :pending, "do this instead"}))
    end

    test "/unsteer with nothing waiting says so" do
      assert screen(command(working(), "/unsteer")) =~ "no steer is waiting"
      assert screen(command(tui(), "/unsteer")) =~ "no steer is waiting"
    end

    test "Alt+Z, which an Option key set to send Alt delivers, revokes it as Cmd+Z does" do
      revoked = steered(working(), "do this first") |> press("z", ["alt"])

      refute pending?(revoked)
      assert status_row(revoked) =~ "steer revoked"
    end

    test "Alt+Z with nothing waiting is the editor's, and Ctrl+Alt+Z never revokes" do
      assert typed(press(tui(), "z", ["alt"])) == ""
      assert pending?(steered(working(), "keep me") |> press("z", ["ctrl", "alt"]))
    end

    # Alt+Z is the key map's `:revoke_steer`, so a config file can move it.
    test "Alt+Z is a binding like any other: it can be taken, and the action moved" do
      keys = Keys.from_map!(%{"alt-z" => "toggle_notifications", "alt-r" => "revoke_steer"})

      idle = tui(keys: keys)
      refute press(idle, "z", ["alt"]).terminal.notifications? == idle.terminal.notifications?

      state = tui(session: fake_session(snapshot("01SESSION")), keys: keys) |> sized()
      state = steered(%{state | conversation: %{state.conversation | busy?: true}}, "first")
      assert pending?(press(state, "z", ["alt"]))
      refute pending?(press(state, "r", ["alt"]))
    end

    # The session can stop with a steer still drawn as waiting, and its
    # `:DOWN` can arrive after the key that asks.
    test "a session that stopped takes its steer with it, and /unsteer does not crash" do
      {gone, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^gone, :normal}

      raced = tui(session: gone, lines: [{:steer, :pending, "do this first"}])
      unsteered = command(raced, "/unsteer")
      refute pending?(unsteered)
      assert screen(unsteered) =~ "the session stopped before the steer was sent"

      down = Lifecycle.session_down(raced, :killed)
      refute pending?(down)
      assert Enum.member?(down.lines, {:steer, :not_sent, "do this first"})
      refute screen(down) =~ "/unsteer takes it back"
    end

    test "/help lists it" do
      helped = command(tui(), "/help")

      assert Enum.any?(helped.lines, fn
               {:lmx, text} when is_binary(text) -> text =~ "/unsteer"
               _row -> false
             end)
    end
  end

  describe "where the agent works" do
    test "the header names the working directory after the version" do
      state = tui(cwd: Path.join(System.user_home(), "code/project"))

      assert screen(state) =~ "#{app_label()} · ~/code/project · "
    end

    test "a screen with no working directory yet leaves it out" do
      assert screen(tui()) =~ "#{app_label()} · #{Screen.name(tui())} · "
    end

    # A directory name may hold escape sequences, and this one is written
    # into the terminal's title.
    test "a control character in the directory is drawn as ?, in the header and the title" do
      cwd = Path.join(System.user_home(), "code/x\u009b31mred\e]0;owned")
      session = fake_session(%{snapshot("02TITLED") | cwd: cwd})

      assert {:ok, state} =
               TUI.mount(test_mode: {80, 24}, start: fn -> {:ok, session} end, title: titling())

      assert Screen.place(state) == "~/code/x?31mred?]0;owned"
      assert screen(state) =~ " · ~/code/x?31mred?]0;owned · "
      assert_receive {:titled, title}
      refute title =~ ~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u
      assert title =~ "~/code/x?31mred?]0;owned"
    end

    test "a long path is shortened, keeping the directory a project is known by" do
      home = "/home/ada"

      assert Screen.directory("/home/ada", home, 32) == "~"
      assert Screen.directory("/home/ada/code/lmx", home, 32) == "~/code/lmx"
      assert Screen.directory("/srv/code/lmx", home, 32) == "/srv/code/lmx"
      # Not a home-directory prefix, only a shared start.
      assert Screen.directory("/home/adam/lmx", home, 32) == "/home/adam/lmx"

      assert Screen.directory("/home/ada/Documents/work/.config/project", home, 20) ==
               "~/D/w/.c/project"

      assert Screen.directory("/home/ada/" <> String.duplicate("a/", 20) <> "project", home, 20) ==
               "…/project"

      assert Screen.directory("/home/ada/code/lmx", nil, 32) == "/home/ada/code/lmx"
    end
  end

  describe "a pale background" do
    test "a screen nothing chose a theme for starts light when the terminal is light" do
      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, background: :light)
      assert Screen.theme(state).name == "light"

      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, background: :dark)
      assert Screen.theme(state).name == "dark"

      assert {:ok, state} = TUI.mount(test_mode: {80, 24})
      assert Screen.theme(state).name == "dark"
    end

    test "a theme somebody chose, or NO_COLOR, wins over the background" do
      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, background: :light, theme: "dark")
      assert Screen.theme(state).name == "dark"

      assert {:ok, state} =
               TUI.mount(test_mode: {80, 24}, background: :light, env: %{"NO_COLOR" => "1"})

      assert Screen.theme(state).name == "mono"
    end

    test "under a pale palette nothing is drawn dim, and dim text takes the muted colour" do
      light = tui(theme: "light", cwd: File.cwd!()) |> info({:text_delta, "an answer"})

      styles = styles(TUI.render(light, @frame))
      refute Enum.any?(styles, &(:dim in &1.modifiers))

      status = light |> TUI.render(@frame) |> status_style()
      assert status.fg == Theme.light().text.muted

      # The dark palette is drawn as it always was.
      assert %Style{fg: :white, modifiers: [:dim]} = tui() |> TUI.render(@frame) |> status_style()
    end
  end

  describe "the cursor" do
    defp cursor(state) do
      accent = Screen.accent(state)

      state
      |> TUI.render(@frame)
      |> styles()
      |> Enum.find(&(&1.bg == accent and &1.fg in [:black, :white]))
    end

    # Black on the light palette's blue read at 3.3:1, and on `/color blue`
    # at 2.2:1.
    test "is drawn in whichever of black and white reads on the accent" do
      assert %Style{fg: :white} = cursor(tui(theme: "light"))
      assert %Style{fg: :black} = cursor(tui())
      assert %Style{fg: :white} = cursor(command(tui(), "/color blue"))
    end
  end

  describe "a terminal without 24-bit colour" do
    defp highlighted(fields) do
      fields
      |> tui()
      |> info({:text_delta, "```elixir\ndef greet(name), do: \"Hello, \" <> name\n```\n"})
    end

    defp colours(widgets) do
      widgets |> styles() |> Enum.flat_map(&[&1.fg, &1.bg])
    end

    test "every RGB colour is drawn as its nearest palette colour" do
      truecolor = highlighted([]) |> TUI.render(@frame) |> colours()
      assert Enum.any?(truecolor, &match?({:rgb, _r, _g, _b}, &1))

      state = highlighted([])
      ansi256 = put_in(state.terminal, Map.put(state.terminal, :colours, :ansi256))
      drawn = ansi256 |> TUI.render(@frame) |> colours()

      refute Enum.any?(drawn, &match?({:rgb, _r, _g, _b}, &1))
      assert Enum.any?(drawn, &match?({:indexed, index} when index >= 16, &1))
    end

    test "a host may set the depth, and a headless screen is left at 24-bit" do
      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, colours: :ansi256)
      assert state.terminal.colours == :ansi256

      # A headless screen is nobody's terminal, so it is left at 24-bit.
      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, env: %{})
      assert state.terminal.colours == :truecolor
    end
  end

  describe "Ctrl-G without a shell" do
    test "says what is missing instead of raising" do
      assert {:error, reason} = ExternalEditor.edit("draft", sh: nil, os: {:unix, :linux})
      assert reason =~ "needs a POSIX `sh`"
    end

    test "a shell that cannot be started is the same sentence, not a crash" do
      missing = Path.join(System.tmp_dir!(), "no-such-dir-#{System.unique_integer()}/sh")

      assert {:error, reason} = ExternalEditor.edit("draft", sh: missing, tty: "/dev/null")
      assert reason =~ "needs a POSIX `sh`"
    end

    # Native Windows has no terminal device, so a shell would not help.
    test "on Windows it says Ctrl-G does not work there, rather than asking for sh" do
      sh = System.find_executable("sh")

      assert {:error, reason} = ExternalEditor.edit("draft", sh: sh, os: {:win32, :nt})
      assert reason =~ "does not work on Windows"
      refute reason =~ "`sh`"
    end

    test "the draft is written into a directory of its own, readable by its owner alone" do
      owner = self()

      runner = fn _editor, path, _mouse? ->
        send(owner, {:draft, path, File.stat!(Path.dirname(path)), File.stat!(path)})
        File.write!(path, "edited\n")
      end

      assert {:ok, "edited"} = ExternalEditor.edit("draft", runner: runner)
      assert_receive {:draft, path, dir, file}

      assert Bitwise.band(dir.mode, 0o777) == 0o700
      assert Bitwise.band(file.mode, 0o777) == 0o600
      assert Path.dirname(Path.dirname(path)) == System.tmp_dir!() |> Path.expand()
      refute File.exists?(Path.dirname(path))

      assert {:ok, "edited"} = ExternalEditor.edit("draft", runner: runner)
      assert_receive {:draft, again, _dir, _file}
      refute Path.dirname(again) == Path.dirname(path)
    end

    test "no terminal to hand over is said as such" do
      assert {:error, "this terminal could not be handed to an editor"} =
               ExternalEditor.edit("draft", sh: "/bin/sh", tty: nil)
    end

    test "the draft is left in the box and the reason flashed" do
      editor = fn text -> ExternalEditor.edit(text, sh: nil) end
      state = tui(editor: editor) |> type("keep this") |> press("g", ["ctrl"])

      # The frame after a handoff is the full repaint; the one after that is
      # the screen again.
      assert_receive :repaint_done
      assert {:noreply, state} = TUI.handle_info(:repaint_done, state)

      assert typed(state) == "keep this"
      assert status_row(state) =~ "needs a POSIX `sh`"
    end
  end

  describe "being told to stop" do
    test "SIGTERM leaves the screen the way Ctrl-C twice does" do
      state = tui(title: titling())

      assert {:stop, stopped} = TUI.handle_info({:terminal_signal, :sigterm}, state)
      assert_receive {:titled, ""}
      assert Lifecycle.terminate(:normal, stopped) == :ok
    end

    test "the handler waits for the screen to go, and not for one already gone" do
      screen =
        spawn(fn ->
          receive do
            {:terminal_signal, :sigterm} -> :ok
          end
        end)

      assert Signals.leave(screen, :sigterm) == :ok
      refute Process.alive?(screen)

      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, :normal}
      {micros, :ok} = :timer.tc(fn -> Signals.leave(dead, :sigterm) end)
      assert micros < 1_000_000
    end

    test "a headless screen sets no traps, even asked" do
      assert {:ok, state} = TUI.mount(test_mode: {80, 24}, trap_signals: true)
      assert state.terminal.signal_traps == []
    end
  end

  describe "switching sessions" do
    defp switched_from(previous, tasks) do
      fresh = fake_session(snapshot("02FRESH"))
      state = tui(session: previous, new_session: fn _subscriber -> {:ok, fresh} end)
      state = state |> put_in([Access.key!(:resume), :task_supervisor], tasks) |> command("/new")

      assert_receive {:new_result, result}
      assert {:noreply, switched} = TUI.handle_info({:new_result, result}, state)
      assert switched.session == fresh
      switched
    end

    # Every stopper has ended. Watched rather than polled: a second of
    # polling is what a loaded machine runs out of first.
    defp until_idle(tasks) do
      for stopper <- Task.Supervisor.children(tasks) do
        ref = Process.monitor(stopper)
        assert_receive {:DOWN, ^ref, :process, ^stopper, _reason}
      end

      :ok
    end

    # It used to be an unlinked `Task.start/1`: owned by nothing, and a
    # crash in it logged on its own.
    test "the session the screen stops showing is stopped under its task supervisor" do
      tasks = start_supervised!(Task.Supervisor)
      {:ok, previous} = GenServer.start(__MODULE__.HeldSession, self())

      switched_from(previous, tasks)

      assert_receive {:stopping, ^previous}
      assert [stopper] = Task.Supervisor.children(tasks)
      ref = Process.monitor(stopper)
      send(previous, :go_on)
      assert_receive {:DOWN, ^ref, :process, ^stopper, :normal}
      refute Process.alive?(previous)
    end

    # The session the screen stops showing may already be gone: it died, or
    # its runtime stopped it first. Stopping it used to crash the task and
    # log an error on every test run that switched sessions.
    test "stopping a previous session that is already gone logs nothing" do
      {gone, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^gone, :normal}
      tasks = start_supervised!(Task.Supervisor)

      log =
        capture_log(fn ->
          switched_from(gone, tasks)
          # Run to its end, crash report and all, before the log is read.
          until_idle(tasks)
        end)

      # The log is every process's, and other tests run beside this one: the
      # crash it used to log is the one naming this session.
      refute log =~ "GenServer.stop(#{inspect(gone)}"
    end
  end

  defp titling do
    owner = self()

    fn text ->
      send(owner, {:titled, text})
      :ok
    end
  end

  defp styles(term) when is_struct(term, Style), do: [term]
  defp styles(list) when is_list(list), do: Enum.flat_map(list, &styles/1)

  defp styles(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> styles()

  defp styles(map) when is_map(map),
    do: map |> Map.delete(:__struct__) |> Map.values() |> styles()

  defp styles(_other), do: []

  # The status row: the first paragraph without a block around it, as
  # `Lemieux.TUI.TestSupport.status_row/1` finds its text.
  defp status_style(widgets) do
    Enum.find_value(widgets, fn
      {%ExRatatui.Widgets.Paragraph{block: nil, style: style}, _rect} -> style
      _other -> nil
    end)
  end
end
