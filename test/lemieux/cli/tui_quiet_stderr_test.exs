defmodule Lemieux.CLI.TUIQuietStderrTest do
  # With `LMX_LOG_LEVEL` set, `lmx` also prints its log lines on standard
  # error (`Lemieux.CLI.Logs`), which in the terminal UI is the screen: they
  # drew over the frame. While the screen is up they go to the log file
  # alone, unless standard error was redirected away from the terminal
  # (`Lemieux.CLI.TUI.quiet_stderr/2`).
  #
  # The VM's log handlers are global, so these run alone, outside log
  # capture, and put back the handlers they found (`Lemieux.ProviderPoolTest`
  # says why).
  use ExUnit.Case, async: false

  require Logger

  alias Lemieux.CLI.Logs
  alias Lemieux.CLI.TUI

  @moduletag :tmp_dir
  @moduletag capture_log: false

  setup do
    level = Logger.level()
    handlers = :logger.get_handler_config()

    on_exit(fn ->
      Logger.configure(level: level)
      for handler <- [:lmx_file, :lmx_stderr], do: :logger.remove_handler(handler)

      for %{id: id} = config <- handlers do
        _ = :logger.remove_handler(id)
        :ok = :logger.add_handler(id, config.module, config)
      end
    end)
  end

  defp level(handler) do
    {:ok, %{level: level}} = :logger.get_handler_config(handler)
    level
  end

  test "standard error is muted while the screen is up, and the file still records",
       %{tmp_dir: dir} do
    :ok = Logs.install(dir: dir, stderr?: true)
    Logger.configure(level: :error)
    before = level(:lmx_stderr)
    refute before == :none

    during =
      TUI.quiet_stderr(
        fn ->
          Logger.error("quiet-stderr-marker")
          {level(:lmx_stderr), level(:lmx_file)}
        end,
        true
      )

    assert {:none, file_level} = during
    refute file_level == :none
    assert level(:lmx_stderr) == before

    :ok = Logs.flush()
    assert File.read!(Path.join([dir, "logs", "lmx.log"])) =~ "quiet-stderr-marker"
  end

  test "its level comes back however the screen ends", %{tmp_dir: dir} do
    :ok = Logs.install(dir: dir, stderr?: true)
    before = level(:lmx_stderr)

    assert_raise RuntimeError, fn ->
      TUI.quiet_stderr(fn -> raise "the screen crashed" end, true)
    end

    assert level(:lmx_stderr) == before
  end

  # `LMX_LOG_LEVEL=debug lmx 2> lmx-debug.log`: nothing is drawn over the
  # frame, and the lines go where they were sent.
  test "standard error redirected away from the terminal keeps them", %{tmp_dir: dir} do
    :ok = Logs.install(dir: dir, stderr?: true)
    before = level(:lmx_stderr)

    assert TUI.quiet_stderr(fn -> level(:lmx_stderr) end, false) == before
  end

  # No `LMX_LOG_LEVEL`, no standard-error handler: nothing to mute.
  test "without the handler it runs the screen as it is", %{tmp_dir: dir} do
    :ok = Logs.install(dir: dir, stderr?: false)

    assert TUI.quiet_stderr(fn -> :screen end, true) == :screen
    assert {:error, _not_found} = :logger.get_handler_config(:lmx_stderr)
  end
end
