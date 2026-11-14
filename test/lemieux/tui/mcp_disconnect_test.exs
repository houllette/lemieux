defmodule Lemieux.TUI.MCPDisconnectTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import Lemieux.TUI.TestSupport
  alias Lemieux.MCP.Transport.Stdio

  @moduletag :tmp_dir

  test "delayed SSH-like disconnect diagnostics stay off the editor across reconnects", %{
    tmp_dir: dir
  } do
    file = Path.join(dir, "ssh fixture.py")

    File.write!(file, """
    import json, os, socket, stat, sys
    for line in sys.stdin:
        request = json.loads(line)
        if request['method'] == 'disconnect':
            os.write(2, b'\\x1b[2JOperation timed out\\r\\nConnection reset by peer\\nclient_loop: send disconnect: Broken pipe\\n')
            diagnostic = socket.socket(fileno=2)
            diagnostic.shutdown(socket.SHUT_WR)
            diagnostic.recv(1)
            diagnostic.detach()
            os.close(2)
        elif request['method'] == 'exit':
            sys.exit(255)
        print(json.dumps({'id': request['id'], 'result': stat.S_ISSOCK(os.fstat(2).st_mode) if request['method'] == 'ping' else 'drained'}), flush=True)
    """)

    {:ok, config} =
      Stdio.configure(%{"name" => "ssh-fixture", "command" => "python3", "args" => [file]},
        cwd: dir
      )

    log =
      capture_log([level: :debug], fn ->
        for _connection <- 1..2 do
          {:ok, transport} = Stdio.connect(config)
          capture = transport.diagnostics
          reader = :sys.get_state(capture).reader
          # Inspect the actual subprocess descriptor: stderr is the capture socket,
          # rather than the terminal or JSON-RPC stdout, even for later diagnostics.
          assert {:ok, %{"result" => true}, transport} =
                   Stdio.call(transport, %{"id" => 1, "method" => "ping"}, 5_000)

          editor = tui() |> type("preserve this draft") |> press("left")
          cursor = ExRatatui.textarea_cursor(editor.input)

          assert {:ok, %{"result" => "drained"}, transport} =
                   Stdio.call(transport, %{"id" => 2, "method" => "disconnect"}, 5_000)

          assert :sys.get_state(capture).remaining < 16_384

          assert {:error, reason, transport} =
                   Stdio.call(transport, %{"id" => 3, "method" => "exit"}, 5_000)

          assert reason =~ "exited with status 255"

          editor =
            info(editor, {:mcp_server, %{name: "ssh-fixture", status: :failed, reason: reason}})

          assert typed(editor) == "preserve this draft"
          assert ExRatatui.textarea_cursor(editor.input) == cursor
          assert screen(editor) =~ "preserve this draft"
          refute screen(editor) =~ "client_loop"
          assert typed(type(editor, "!")) == "preserve this draf!t"
          assert :ok = Stdio.close(transport)
          refute Process.alive?(capture)
          refute Process.alive?(reader)
        end
      end)

    assert length(Regex.scan(~r/Connection reset by peer/, log)) == 2
    assert log =~ "client_loop: send disconnect: Broken pipe"
    refute log =~ "\e"
  end
end
