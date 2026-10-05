# A status line a host might write, so the test below can watch one arrive
# in a running screen rather than in a keyword list.
defmodule Lemieux.CLI.TUITest.HostStatus do
  @moduledoc false
  @behaviour Lemieux.TUI.Status

  alias ExRatatui.Widgets.Paragraph

  @impl Lemieux.TUI.Status
  def render(status, area), do: [{%Paragraph{text: "host line · #{status.label}"}, area}]
end

defmodule Lemieux.CLI.TUITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI
  alias Lemieux.CLI.TUITest.HostStatus
  alias Lemieux.Extensions.Workspace
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Harness
  alias Lemieux.TUI.Theme

  describe "update_notice/2" do
    @tag :tmp_dir
    test "an upgrade since the last start is news, linking that release's changelog", %{
      tmp_dir: dir
    } do
      assert TUI.update_notice(dir, "0.1.0") == nil
      assert TUI.update_notice(dir, "0.1.0") == nil

      notice = TUI.update_notice(dir, "0.2.0")
      assert notice =~ "Lemieux was updated to v0.2.0 since you last used it"

      assert notice =~
               "[full changelog](https://github.com/houllette/lemieux/blob/v0.2.0/CHANGELOG.md)"

      assert TUI.update_notice(dir, "0.2.0") == nil
    end

    test "is never news where nothing is remembered" do
      assert TUI.update_notice(nil, "0.2.0") == nil
    end
  end

  describe "available/0" do
    test "says yes here, which is the check that the dependency actually resolved" do
      assert TUI.available() == :ok
    end
  end

  describe "available/1" do
    test "refuses a priv directory that is not a directory" do
      assert {:error, message} = TUI.available(~c"/nonexistent/lmx/ex_ratatui/priv")

      assert message =~ "native library"
      assert message =~ "OTP release"
      refute message =~ "escript"
    end

    test "and a priv directory it could not find at all" do
      assert {:error, message} = TUI.available({:error, :bad_name})

      assert message =~ "ex_ratatui"
      assert message =~ "Embedded hosts"
    end

    test "accepts a real directory" do
      assert TUI.available(System.tmp_dir!()) == :ok
    end
  end

  describe "lmx tui" do
    test "an unrecognised option is named rather than opening anything" do
      output = capture_io(:stderr, fn -> assert TUI.main(["--nope"]) == {:error, 1} end)

      assert output =~ "unrecognised option --nope"
    end
  end

  # Opening a real screen needs a terminal, so what the screen is *started
  # with* is asserted instead. It is the half that broke: `--mouse` reached
  # the parsed options and was then dropped on the way to the app, which from
  # the outside is indistinguishable from the flag never having existed.
  describe "app_options/3" do
    @tag :tmp_dir
    test "forwards personal provider preferences to the model picker", %{tmp_dir: dir} do
      path = Path.join(dir, "config.json")
      File.write!(path, ~s({"providers":{"openai":{"model":"openai:gpt-6-sol"}}}))

      assert {:ok, options} = Options.parse(["--config", path])
      app = TUI.app_options(options, [], harness: Harness.new())
      assert app[:preferred_models] == %{"openai" => "openai:gpt-6-sol"}
    end

    test "the screen captures the mouse, and hands it back when asked" do
      assert {:ok, default} = Options.parse([])
      assert TUI.app_options(default, [], harness: Harness.new())[:mouse_capture] == true

      assert {:ok, handed_back} = Options.parse(["--no-mouse"])
      assert TUI.app_options(handed_back, [], harness: Harness.new())[:mouse_capture] == false
    end

    # The screen's own opinions — the status line, the theme and the palettes
    # beyond the shipped three, the renderers, the slash commands, the key
    # map — arrive on the harness, and the harness arrives whole. Each used
    # to be copied out here into an option of its own, and that list was
    # where the screen and the session drifted apart: a field the harness
    # grew and this list did not reached the session and never the screen.
    # `Lemieux.TUI.new/1` reads them from `:harness` itself now.
    @copied ~w(theme themes keys layout renderers commands processing status_line followups
               skills notices)a

    test "the harness is forwarded whole, and no field of it is copied out beside it" do
      assert {:ok, options} = Options.parse([])
      sepia = Theme.dark() |> Theme.to_map() |> Map.put("name", "sepia")

      harness =
        Harness.new(
          status_line: MyHost.Status,
          followups: MyHost.Followups,
          theme: "sepia",
          themes: %{"sepia" => sepia},
          keys: %{"ctrl-j" => "submit"},
          processing: ["thinking", "working"],
          renderers: %{"bash" => MyHost.BashReceipt},
          commands: [MyHost.Deploy]
        )

      app = TUI.app_options(options, [], harness: harness)

      assert app[:harness] == harness

      for field <- @copied do
        refute Keyword.has_key?(app, field), "#{field} is still copied out of the harness"
      end
    end

    # The whole road, once: a field set on the harness, through the options
    # this host builds, into the state of a screen that is running. `test_mode`
    # draws to a buffer, so no terminal is needed; no `start:` means no session,
    # which is all the difference between this and `lmx`.
    test "a harness field reaches the running screen through the options this host builds" do
      assert {:ok, options} = Options.parse([])

      app =
        TUI.app_options(options, [],
          harness: Harness.new(status_line: HostStatus, processing: ["Deking"]),
          size: {80, 24},
          title: fn _text -> :ok end
        )

      {:ok, screen} = Lemieux.TUI.start_link(app ++ [test_mode: {80, 24}, name: nil])

      try do
        state = :sys.get_state(screen).user_state
        assert state.status.line == HostStatus
        assert state.status.words == ["Deking"]
      after
        GenServer.stop(screen)
      end
    end

    test "the ledger follows the sessions directory the flag chose" do
      assert {:ok, options} = Options.parse(["--sessions-dir", "/tmp/elsewhere"])
      app = TUI.app_options(options, [], harness: Harness.new())

      assert app[:sessions_dir] == "/tmp/elsewhere"
      assert app[:feedback_store] == nil

      ledger = TUI.app_options(options, [feedback_dir: "/tmp/ledger"], harness: Harness.new())
      assert ledger[:feedback_dir] == "/tmp/ledger"
    end

    # These used to go to standard error from a command that then takes the
    # whole screen, so the person read them on the way out. They arrive
    # through the workspace extension, like the skills it offers, on the
    # harness the screen is handed.
    test "what the workspace scan noticed is handed to the screen, not to stderr" do
      assert {:ok, options} = Options.parse([])

      workspace = %Discovery{
        root: "/tmp/repo",
        diagnostics: [".mcp.json: not started automatically"]
      }

      assert {:ok, harness} = Harness.assemble(Harness.new(), [{Workspace, workspace: workspace}])
      app = TUI.app_options(options, [], harness: harness)

      assert app[:harness].notices == [".mcp.json: not started automatically"]
      assert app[:harness].skills == []
      refute Keyword.has_key?(app, :notices)
    end

    # The harness is not optional. A screen opened without one would draw the
    # shipped defaults over a session shaped by something else, and nothing
    # would say so.
    test "a screen cannot be opened without the harness it is drawn from" do
      assert {:ok, options} = Options.parse([])

      assert_raise KeyError, fn -> TUI.app_options(options, [], []) end
      assert_raise MatchError, fn -> TUI.app_options(options, [], harness: %{theme: "light"}) end
    end

    test "what only a running host can compute is passed through untouched" do
      assert {:ok, options} = Options.parse([])
      start = fn -> {:error, :not_started} end
      title = fn _text -> :ok end

      app =
        TUI.app_options(options, [welcome: "hello"],
          harness: Harness.new(),
          start: start,
          size: {80, 24},
          title: title
        )

      assert app[:start] == start
      assert app[:size] == {80, 24}
      assert app[:title] == title
      assert app[:welcome] == "hello"
    end

    # The screen writes no escape sequence unless a host hands it a writer,
    # so a missing one leaves the terminal whatever title it had. This is the
    # host that owns a local terminal, and this is it asking.
    test "the local host's writer sets the title of its own terminal" do
      written = capture_io(fn -> assert TUI.title().("lmx | holden-gretzky") == :ok end)

      assert written == "\e]0;lmx | holden-gretzky\a"
    end
  end
end
