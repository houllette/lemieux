defmodule Lemieux.CLI.TUISourceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.TUI
  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  # Never reached: every case here is refused before a screen would open.
  defp no_screen, do: [tui_runner: &TUI.main/2]

  defp refused(argv, opts) do
    stderr =
      capture_io(:stderr, fn ->
        send(self(), {:status, CLI.run(argv, Keyword.merge(no_screen(), opts))})
      end)

    assert_received {:status, status}
    {status, stderr}
  end

  describe "words the terminal UI does not take" do
    # `mix lmx.tui run "Summarize…"` opened an idle screen and dropped both
    # the command and the prompt.
    test "a command typed where the terminal UI was opened names the command meant" do
      {status, stderr} = refused(["tui", "run", "Summarize this repository"], program: "mix lmx")

      assert status == {:error, 1}
      assert stderr =~ ~s(unexpected argument "run")
      assert stderr =~ "did you mean `mix lmx run …`?"
    end

    # The whole line again, as `lmx run`, each argument quoted for the
    # shell: it is meant to be pasted.
    test "a prompt names the lmx run line that answers it, flags included" do
      {status, stderr} = refused(["--model", "test:model", "fix", "the", "bug"], [])

      assert status == {:error, 1}
      assert stderr =~ ~s(unexpected argument "fix")
      assert stderr =~ "lmx run --model test:model fix the bug\n"
      # Which of the words were a flag's value is the parser's to know, so
      # with flags among them the `--prompt` line is named by its shape.
      assert stderr =~ "only through --prompt: lmx [options] --prompt PROMPT;"
    end

    # A short directory, so the line is repeated rather than shaped.
    test "words alone are offered back as one --prompt, -C DIR with them" do
      {status, stderr} = refused(["tui", "fix", "the", "bug"], cwd: "/tmp")

      assert status == {:error, 1}

      assert stderr =~
               "the terminal UI takes a prompt only through --prompt: " <>
                 "lmx -C /tmp --prompt 'fix the bug';"
    end

    test "quotes what a shell would expand, rather than Elixir's way" do
      {_status, stderr} = refused(["--no-mouse", "why does $HOME `pwd` fail?"], [])

      # `--no-mouse` is the terminal UI's, and `lmx run` would refuse it.
      assert stderr =~ "without the terminal UI: lmx run 'why does $HOME `pwd` fail?'\n"
    end

    # Cut to fit, a pasted prompt ran cut.
    test "names a line too long to repeat instead of cutting it" do
      prompt = String.duplicate("explain the main entry points ", 4)
      {_status, stderr} = refused(["tui", prompt], program: "mix lmx")

      # The standard error capture is shared with other async tests, so only
      # this refusal's own line is read.
      [line] = stderr |> String.split("\n") |> Enum.filter(&(&1 =~ ~s(argument "explain the)))
      assert line =~ "without the terminal UI: mix lmx run [options] PROMPT"
      refute line =~ "run explain"
      refute line =~ "run 'explain"
    end
  end

  describe "start_screen/3" do
    defmodule NoTerminal do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl GenServer
      def init(_opts), do: {:stop, {:terminal_init_failed, "Device not configured (os error 6)"}}
    end

    test "the way out names the command a source checkout has" do
      assert {:error, message} = TUI.start_screen(NoTerminal, [], "mix lmx")

      assert message =~ "`mix lmx run PROMPT`"
      refute message =~ "`lmx run PROMPT`"
    end
  end

  describe "resume_hint/3" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      store = JSONL.new(Path.join(dir, "sessions"))
      %{store: store, project: Path.join(dir, "project")}
    end

    defp session(store, cwd) do
      id = Lemieux.ID.generate()

      :ok =
        Store.append(store, id, [
          Entry.new(:session, %{"model" => "test:model", "cwd" => cwd, "tools" => []}),
          Entry.new(:user, %{"text" => "what does this do?"}),
          Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "it reads"}]})
        ])

      id
    end

    test "names the session -c would resume, and the command that resumes it", context do
      File.mkdir_p!(context.project)
      id = session(context.store, context.project)

      hint = TUI.resume_hint(context.store, context.project, program: "mix lmx")

      assert hint =~ "session #{Shorthand.of(id)} is saved"
      assert hint =~ "`mix lmx -C #{context.project} -c` resumes it"
    end

    test "is the plain flag where lmx was started in the session's directory", context do
      session(context.store, File.cwd!())

      assert TUI.resume_hint(context.store, nil, []) =~ "`lmx -c` resumes it"
    end

    test "says nothing when nothing ran here", context do
      assert TUI.resume_hint(context.store, context.project, []) == nil
    end

    test "an idle screen offers its own player name rather than an older substantive session",
         context do
      old = session(context.store, context.project)
      current = Lemieux.ID.generate()

      :ok =
        Store.append(context.store, current, [Entry.new(:session, %{"cwd" => context.project})])

      hint =
        TUI.resume_hint(context.store, context.project,
          program: "mix lmx",
          closed_session: %{id: current, name: "the actual screen", cwd: context.project}
        )

      assert hint =~ "session the actual screen (#{Shorthand.of(current)}) is saved"
      assert hint =~ "--resume #{Shorthand.of(current)}` resumes it"
      refute hint =~ current
      refute hint =~ "session #{Shorthand.of(old)} is saved"
    end

    test "the exit command uses a short name that resolves to the saved session", context do
      id = "01M4HAEB2WS7WMVP8ATN4D3NCA"
      :ok = Store.append(context.store, id, [Entry.new(:session, %{"cwd" => File.cwd!()})])

      hint =
        TUI.resume_hint(context.store, nil,
          program: "mix lmx",
          closed_session: %{id: id, name: nil, cwd: File.cwd!()}
        )

      assert hint ==
               "session maxime-comtois is saved · `mix lmx --resume maxime-comtois` resumes it"

      assert Shorthand.resolve(context.store, "maxime-comtois") == {:ok, id}
    end

    test "quitting a failed startup never claims an unrelated session was just saved", context do
      session(context.store, context.project)
      assert TUI.resume_hint(context.store, context.project, closed_session: %{id: nil}) == nil

      assert TUI.resume_hint(context.store, context.project,
               closed_session: %{id: "missing", name: nil, cwd: context.project}
             ) == nil
    end

    test "quotes a directory the shell would split", context do
      project = Path.join(context.project, "it's here")
      File.mkdir_p!(project)
      session(context.store, project)

      assert TUI.resume_hint(context.store, project, []) =~
               "`lmx -C '#{context.project}/it'\\''s here' -c` resumes it"
    end
  end

  describe "crash_dump/2" do
    @describetag :tmp_dir

    test "with no state directory, leaves the crash dump where ERTS puts it" do
      assert TUI.crash_dump(nil, nil) == nil
    end

    test "an ERL_CRASH_DUMP somebody set is left alone", %{tmp_dir: dir} do
      assert TUI.crash_dump(dir, "/elsewhere/erl_crash.dump") == nil
      refute File.exists?(Path.join(dir, "crash"))
    end
  end
end
