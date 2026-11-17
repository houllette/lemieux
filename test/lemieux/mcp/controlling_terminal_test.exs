defmodule Lemieux.MCP.ControllingTerminalTest do
  use ExUnit.Case, async: true
  @moduletag :tmp_dir
  @tag timeout: :timer.minutes(3)
  if match?({:win32, _}, :os.type()), do: @moduletag(skip: "controlling terminals require Unix")

  test "late helpers cannot bypass stderr capture during real TUI close and reopen", %{
    tmp_dir: dir
  } do
    fixture = Path.expand("../../fixtures", __DIR__)

    {json, 0} =
      System.cmd(
        "python3",
        [
          Path.join(fixture, "run_pty.py"),
          System.find_executable("mix"),
          "run",
          "--no-start",
          Path.join(fixture, "mcp_tty.exs"),
          dir,
          Path.join(fixture, "mcp_tty_server.py")
        ],
        env: [
          {"MIX_ENV", "test"},
          {"ERL_FLAGS", "+S 2:2 +SDcpu 1 +SDio 1"},
          {"TERM", "xterm-256color"},
          {"LMX_HOME", dir},
          {"LMX_CONFIG", "none"},
          {"LMX_PROJECT_MCP", "0"}
        ]
      )

    result = JSON.decode!(json)
    output = Base.decode64!(result["output"])
    assert result["status"] == 0, String.slice(output, -2_000, 2_000)
    assert output =~ "\e[?1049h"
    refute output =~ "TTY_LEAK_MARKER"
    refute output =~ "SSH_DIAGNOSTIC_MARKER"
    log = File.read!(Path.join([dir, "logs", "lmx.log"]))
    assert length(Regex.scan(~r/SSH_DIAGNOSTIC_MARKER/, log)) == 2
    refute log =~ "\e"

    assert [
             %{"stderr_socket" => true, "tty_opened" => false},
             %{"stderr_socket" => true, "tty_opened" => false}
           ] ==
             dir |> Path.join("tty-results.json") |> File.read!() |> JSON.decode!()
  end
end
