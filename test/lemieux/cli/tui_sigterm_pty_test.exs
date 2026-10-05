defmodule Lemieux.CLI.TUISigtermPtyTest do
  # A real VM on a pseudo-terminal: `mix lmx`, the source terminal UI, sent
  # SIGTERM once its screen is up (test/fixtures/tui_sigterm.py). Its trap
  # (`Lemieux.CLI.TUI`) used to stop the screen with `:shutdown`, an exit
  # signal that took the command linked to the screen with it: Elixir's
  # script runner printed `** (EXIT from #PID<…>) shutdown` under the
  # restored screen and the VM exited 1.
  #
  # The child is hermetic as far as it can be: `--config none`, a home
  # directory of its own (its transcript and crash directory go there), no
  # provider keys (the suite removed them from this VM's environment, which
  # it inherits), so it opens on the provider panel and asks no model
  # anything. It does ask a local Ollama which models it serves, as every
  # start does.
  use ExUnit.Case, async: true

  @moduletag :tmp_dir
  @fixture Path.expand("../../fixtures/tui_sigterm.py", __DIR__)
  @marker "Choose a model provider"

  if match?({:win32, _}, :os.type()),
    do: @moduletag(skip: "pseudo-terminals are a Unix facility")

  # Runs `command` on a pseudo-terminal until its screen draws the provider
  # panel, then sends it SIGTERM: the fixture's report, and every byte the
  # terminal received.
  defp on_a_terminal(dir, command, env \\ []) do
    {json, 0} =
      System.cmd("python3", [@fixture, "180", @marker | command],
        env: hermetic(dir) ++ env,
        cd: File.cwd!()
      )

    result = JSON.decode!(json)
    {result, Base.decode64!(result["output"])}
  end

  # Mix keeps its archives, Hex among them, outside the home directory this
  # moves, wherever this VM found them: `Mix.Utils.mix_home/0` follows
  # `MIX_HOME`, then `MIX_XDG`, then `~/.mix`, and with only `HOME` moved, a
  # Mix home that follows XDG was looked for under the new one. Hex's own
  # home is left to follow the new one: loading a compiled, locked project
  # needs nothing from its cache, nor from its configuration, which holds
  # the contributor's hex.pm credentials.
  defp hermetic(dir) do
    [
      {"HOME", dir},
      {"MIX_HOME", Mix.Utils.mix_home()},
      {"HEX_HOME", nil},
      # The build this suite runs from, rather than a dev build to compile.
      {"MIX_ENV", "test"},
      {"LMX_CONFIG", "none"},
      {"LMX_PROJECT_MCP", "0"},
      {"TERM", "xterm-256color"}
    ]
  end

  defp tail(output),
    do:
      inspect(binary_part(output, max(byte_size(output) - 1200, 0), min(byte_size(output), 1200)))

  defp mix, do: System.find_executable("mix") || flunk("mix is not on PATH")

  @tag timeout: 240_000
  test "SIGTERM to a running source terminal UI restores the screen and exits at once",
       %{tmp_dir: dir} do
    {result, output} = on_a_terminal(dir, [mix(), "lmx"])

    assert result["opened"], "the terminal UI never drew its provider panel: #{tail(output)}"

    assert is_number(result["seconds"]),
           "the VM did not exit within 20 s of SIGTERM: #{tail(output)}"

    assert result["seconds"] < 10, "the VM took #{result["seconds"]} s to exit: #{tail(output)}"

    after_signal =
      binary_part(output, result["stopped_at"], byte_size(output) - result["stopped_at"])

    assert after_signal =~ "\e[?1049l", "the screen was not restored: #{tail(output)}"
    refute output =~ "** (EXIT", "the command died with the screen: #{tail(output)}"
    assert result["status"] == 0, "mix lmx exited #{result["status"]}: #{tail(output)}"
  end

  # `LMX_LOG_LEVEL` prints log lines on standard error, which is this
  # terminal, and they drew over the frame. A process here logs every tenth
  # of a second from before the screen opens until the VM stops: its lines
  # before the screen show it reaches the terminal, and while the screen is
  # up (from the panel being drawn to the screen being left) none may.
  @probe """
  require Logger
  probe = fn probe -> Logger.error("lmx-log-probe"); Process.sleep(100); probe.(probe) end
  spawn(fn -> probe.(probe) end)
  Mix.Task.run("lmx", [])
  """

  @tag timeout: 240_000
  test "with LMX_LOG_LEVEL set, no log line is drawn over the screen", %{tmp_dir: dir} do
    {result, output} =
      on_a_terminal(dir, [mix(), "run", "-e", @probe], [{"LMX_LOG_LEVEL", "debug"}])

    assert result["opened"], "the terminal UI never drew its provider panel: #{tail(output)}"
    {drawn, _length} = :binary.match(output, @marker)

    {left, _length} =
      :binary.match(output, "\e[?1049l", scope: {drawn, byte_size(output) - drawn}) ||
        flunk("the screen was not left: #{tail(output)}")

    screen = binary_part(output, drawn, left - drawn)

    assert binary_part(output, 0, drawn) =~ "[error] lmx-log-probe",
           "the probe never reached the terminal: #{tail(output)}"

    refute screen =~ "lmx-log-probe", "a log line was drawn over the screen: #{inspect(screen)}"
    refute screen =~ ~r/\[(debug|info|notice|warning|error)\]/, inspect(screen)
  end
end
