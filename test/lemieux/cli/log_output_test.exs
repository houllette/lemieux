defmodule Lemieux.CLI.LogOutputTest do
  @moduledoc """
  What reaches the real file descriptors when something logs.

  An in-process test cannot see it: a log handler writes from its own
  process to the VM's standard output, past `capture_io/1`. So this runs a
  second VM on this build's code, the way the release runs: `configure/0`,
  then a command. Before `Lemieux.CLI.Logs`, an unreachable provider put
  `req_llm`'s `[error] Finch streaming transport failed …` line on standard
  output — in front of `lmx run`'s JSON, and over the terminal UI's frame,
  which is the same descriptor.

  The terminal UI's own check is this one: its frame is that VM's standard
  output, and log handlers belong to the VM, not to a command. Driving the
  real screen would need a pseudo-terminal per platform and a race against
  the frame rate for nothing this does not already show — that the failure
  was logged, and reached neither descriptor.
  """

  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # Port 9 is discard: nothing listens on loopback, so the connection is
  # refused at once and nothing is sent anywhere.
  @script """
  Application.put_env(:req_llm, :load_dotenv, false)
  {:ok, _} = Application.ensure_all_started(:lemieux)
  :ok = Lemieux.CLI.configure()
  require Logger
  Logger.error("lmx-log-probe: a line the screen must never show")

  status =
    case Lemieux.CLI.run(
           ["run", "--output-format", "stream-json", "--model", "ollama:fake",
            "--base-url", "http://127.0.0.1:9/v1", "hi"],
           provider_retry: [base_delay_ms: 1]
         ) do
      :ok -> 0
      {:error, status} -> status
    end

  System.halt(status)
  """

  test "an unreachable provider leaves stream-json parseable and the terminal clean", %{
    tmp_dir: dir
  } do
    elixir = System.find_executable("elixir") || flunk("no elixir executable on the path")
    stderr_file = Path.join(dir, "stderr")

    {stdout, status} =
      System.cmd(
        "sh",
        ["-c", ~s(exec "$0" "$@" 2>"$LMX_TEST_STDERR"), elixir, "-e", @script],
        env:
          [
            {"ERL_LIBS", Path.join(Mix.Project.build_path(), "lib")},
            {"HOME", dir},
            {"LMX_HOME", dir},
            {"LMX_CONFIG", "none"},
            {"LMX_PROJECT_MCP", "0"},
            {"LMX_TEST_STDERR", stderr_file}
          ] ++
            Enum.map(
              ~w(LMX_LOG_LEVEL LMX_SESSIONS_DIR LMX_MODEL LMX_ROUTER LMX_BASE_URL LMX_IXWAY_URL
                 LMX_WEB_SEARCH LMX_WEB_FETCH LMX_EXTENSIONS_DIR LMX_CREDENTIALS),
              &{&1, nil}
            ),
        cd: dir
      )

    stderr = File.read!(stderr_file)

    assert status == 1, "stdout:\n#{stdout}\nstderr:\n#{stderr}"

    events = stdout |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

    assert %{"type" => "result", "exit_status" => 1, "error" => %{"message" => message}} =
             List.last(events)

    assert message =~ "could not reach ollama at http://127.0.0.1:9 (connection refused)"

    for {name, bytes} <- [stdout: stdout, stderr: stderr] do
      refute bytes =~ "[error]", "#{name} carried a log line:\n#{bytes}"
      refute bytes =~ "lmx-log-probe", "#{name} carried a log line:\n#{bytes}"
    end

    log = File.read!(Path.join([dir, "logs", "lmx.log"]))
    assert log =~ "[error] lmx-log-probe: a line the screen must never show"
    # The connection failure itself was logged — to the file, and nowhere else.
    assert log =~ ":econnrefused"
    assert Bitwise.band(File.stat!(Path.join(dir, "logs")).mode, 0o777) == 0o700
  end
end
