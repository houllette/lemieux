defmodule Lemieux.CLI.TUIPromptTest do
  # `lmx --prompt TEXT` (and `lmx tui --prompt TEXT`): the terminal UI opened
  # with a first message, which is how a launcher hands an agent a prompt and
  # keeps the session interactive. `Lemieux.TUI.InitialPromptTest` covers
  # when the screen sends it; this covers what lmx accepts and hands over.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.Help
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.TUI

  defp run(argv) do
    stderr =
      capture_io(:stderr, fn ->
        send(self(), {:status, CLI.run(argv, tui_runner: &TUI.main/2)})
      end)

    assert_received {:status, status}
    {status, stderr}
  end

  defp opening(options),
    do: TUI.opening_app(options, [], size: {80, 24}, title: fn _text -> :ok end)

  test "is the terminal UI's flag, kept as typed" do
    assert {:ok, options} =
             Options.parse(["--config", "none", "--prompt", "fix the bug"], command: :tui)

    assert options.given[:prompt] == "fix the bug"
    assert options.argv == []

    assert {:ok, dashed} =
             Options.parse(["--config", "none", "--prompt=-v please"], command: :tui)

    assert dashed.given[:prompt] == "-v please"
  end

  # `lmx run` takes its prompt as an argument; a `--prompt` it ignored would
  # be answered as if the person had asked nothing, or something else.
  test "lmx run names it as not its own rather than ignoring it" do
    assert {:error, message} =
             Options.parse(["--config", "none", "--prompt", "x"], command: :run)

    assert message == "--prompt does not apply to lmx run"

    {status, stderr} = run(["run", "--config", "none", "--prompt", "x", "hello"])
    assert status == {:error, 2}
    assert stderr =~ "--prompt does not apply to lmx run"
  end

  test "an empty prompt is refused before anything opens" do
    for text <- ["", "   "] do
      {status, stderr} = run(["--config", "none", "--prompt", text])

      assert status == {:error, 1}
      assert stderr =~ "--prompt is empty"
    end

    {status, stderr} = run(["tui", "--config", "none", "--prompt"])
    assert status == {:error, 1}
    assert stderr =~ "missing value for --prompt"
  end

  test "reaches the opening screen as its first staged message" do
    assert {:ok, options} =
             Options.parse(["--config", "none", "--prompt", "fix the bug"], command: :tui)

    app = opening(options)
    assert app[:prompt] == "fix the bug"

    {:ok, screen} = Lemieux.TUI.start_link(app ++ [test_mode: {80, 24}, name: nil])

    try do
      assert :sys.get_state(screen).user_state.history.queued == ["fix the bug"]
    after
      GenServer.stop(screen)
    end
  end

  test "lmx help options names it" do
    assert {:ok, options} = Help.topic("options")
    assert options =~ "--prompt TEXT    Terminal UI only"
  end

  test "without it the screen opens with nothing staged" do
    assert {:ok, options} = Options.parse(["--config", "none"], command: :tui)

    assert opening(options)[:prompt] == nil
  end
end
