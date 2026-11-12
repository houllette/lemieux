defmodule Lemieux.MCP.StderrCaptureTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lemieux.MCP.Transport.Stdio
  @moduletag :tmp_dir

  test "default stderr is separate, sanitized, redacted and continuously bounded", %{tmp_dir: dir} do
    file = Path.join(dir, "server with spaces.py")

    File.write!(file, """
    import json, os, sys
    os.write(2, b'\\x1b[31mstartup warning\\x1b[0m\\n')
    os.write(2, b'Bearer private-value\\n')
    os.write(2, b'https://example.test/callback?code=private-code\\n')
    os.write(2, os.environ['TEST_TOKEN'].encode() + b'\\n')
    os.write(2, sys.argv[1].encode() + b'\\n')
    os.write(2, b'x' * 10000000 + b'\\n')
    for line in sys.stdin:
        request = json.loads(line)
        os.write(2, b'later warning\\n')
        print(json.dumps({'id': request['id'], 'result': 'ok'}), flush=True)
    """)

    {:ok, config} =
      Stdio.configure(
        %{
          "name" => "fixture",
          "command" => "python3",
          "args" => [file, "short-private-value"],
          "env" => %{"TEST_TOKEN" => "private-value"}
        },
        cwd: dir
      )

    log =
      capture_log([level: :debug], fn ->
        {:ok, state} = Stdio.connect(config)
        capture = state.diagnostics

        assert {:ok, %{"result" => "ok"}, state} =
                 Stdio.call(state, %{"id" => 1, "method" => "test"}, 5_000)

        info = :sys.get_state(capture)
        assert byte_size(info.buffer) <= 2_048
        assert info.remaining == 0
        refute inspect(info) =~ "private-value"
        assert :ok = Stdio.close(state)
        refute Process.alive?(capture)
        refute Process.alive?(info.reader)
        assert :ok = Stdio.close(state)
      end)

    assert log =~ "MCP fixture stderr: startup warning"
    assert log =~ "diagnostic withheld"
    refute log =~ "private-value"
    refute log =~ "private-code"
    refute log =~ "short-private-value"
    refute log =~ "\e"
  end

  test "capture follows an abruptly killed client", %{tmp_dir: dir} do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, config} = Stdio.configure(%{"command" => "cat"}, cwd: dir)
        {:ok, state} = Stdio.connect(config)
        send(parent, {:capture, state.diagnostics})

        receive do
          :hold -> :ok
        end
      end)

    assert_receive {:capture, capture}
    reader = :sys.get_state(capture).reader
    ref = Process.monitor(capture)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^capture, :normal}
    refute Process.alive?(reader)
  end
end
