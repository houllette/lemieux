defmodule Lemieux.CLI.ACPTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.Server
  alias Lemieux.CLI.Options
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp connect(dir, script, version \\ 1, flags \\ [], questions? \\ true) do
    runtime = :"acp_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    provider = Scripted.new(script)
    store = JSONL.new(Path.join(dir, "sessions"))

    assert {:ok, options} =
             Options.parse(["--config", "none", "--no-sandbox", "--no-delegate"] ++ flags,
               command: :acp
             )

    owner = self()

    server =
      start_supervised!(
        {Server,
         options: options,
         host: [provider: provider, store: store, supervisor: runtime],
         emit: &send(owner, {:wire, &1})}
      )

    request(server, 1, "initialize", %{
      "protocolVersion" => version,
      "clientCapabilities" => %{"_meta" => %{"lemieux" => %{"question" => questions?}}}
    })

    assert_receive {:wire, %{"id" => 1, "result" => %{"protocolVersion" => ^version}}}
    {server, provider, store}
  end

  defp request(server, id, method, params),
    do:
      Server.receive_message(server, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

  defp open(server, dir) do
    request(server, 2, "session/new", %{"cwd" => dir, "mcpServers" => []})
    assert_receive {:wire, %{"id" => 2, "result" => %{"sessionId" => id}}}
    id
  end

  defp prompt(server, id),
    do:
      request(server, 3, "session/prompt", %{
        "sessionId" => id,
        "prompt" => [%{"type" => "text", "text" => "hello"}]
      })

  test "v1 streams text, finishes once, and lists the durable session", %{tmp_dir: dir} do
    {server, provider, store} =
      connect(dir, [Scripted.complete("hello world", fragments: ["hello ", "world"])])

    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{
                      "method" => "session/update",
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "agent_message_chunk",
                          "content" => %{"text" => "hello "}
                        }
                      }
                    }}

    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    assert length(Scripted.requests(provider)) == 1
    assert {:ok, entries} = Store.read(store, id)

    assert Enum.any?(
             entries,
             &(&1.type == :assistant and
                 &1.payload["content"] == [%{"type" => "text", "text" => "hello world"}])
           )

    request(server, 4, "session/list", %{})

    assert_receive {:wire,
                    %{
                      "id" => 4,
                      "result" => %{"sessions" => [%{"sessionId" => ^id, "cwd" => ^dir}]}
                    }}

    request(server, 5, "session/close", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 5, "result" => %{}}}
    request(server, 6, "session/load", %{"sessionId" => id, "cwd" => dir, "mcpServers" => []})

    assert_receive {:wire,
                    %{
                      "method" => "session/update",
                      "params" => %{"update" => %{"content" => %{"text" => "hello world"}}}
                    }}

    assert_receive {:wire, %{"id" => 6, "result" => %{"sessionId" => ^id}}}
    assert length(Scripted.requests(provider)) == 1
  end

  test "v2 accepts the persisted message id before completing work", %{tmp_dir: dir} do
    {server, _provider, store} = connect(dir, [[{:delay, 60_000}]], 2)
    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => 3, "result" => %{"messageId" => message_id}}}

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "user_message",
                          "messageId" => ^message_id
                        }
                      }
                    }}

    assert {:ok, entries} = Store.read(store, id)
    assert Enum.any?(entries, &(&1.id == message_id and &1.type == :user))
    request(server, 4, "session/cancel", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 4, "result" => %{}}}

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "state_update",
                          "state" => "idle",
                          "stopReason" => "cancelled"
                        }
                      }
                    }}
  end

  test "only a correlated approval can authorize a real command", %{tmp_dir: dir} do
    {server, _provider, _store} =
      connect(dir, [
        Scripted.tool_call("command", "bash", %{"command" => "printf approved > marker"}),
        Scripted.complete("done")
      ])

    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{
                      "id" => permission_id,
                      "method" => "session/request_permission",
                      "params" => %{"toolCall" => %{"toolCallId" => "command"}}
                    }}

    refute File.exists?(Path.join(dir, "marker"))

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => "wrong",
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}
    })

    assert :sys.get_state(server).pending[permission_id]
    refute File.exists?(Path.join(dir, "marker"))

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => permission_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}
    })

    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    assert File.read!(Path.join(dir, "marker")) == "approved"
    assert :sys.get_state(server).pending == %{}
  end

  test "cancellation releases parked approvals and late replies cannot execute", %{tmp_dir: dir} do
    {server, _provider, _store} =
      connect(dir, [Scripted.tool_call("command", "bash", %{"command" => "touch marker"})])

    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => permission_id, "method" => "session/request_permission"}}
    request(server, 4, "session/cancel", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "cancelled"}}}

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => permission_id,
      "result" => %{"outcome" => %{"outcome" => "selected", "optionId" => "allow"}}
    })

    assert :sys.get_state(server).pending == %{}
    refute File.exists?(Path.join(dir, "marker"))
  end

  test "connection closure cancels work and releases its transcript lock", %{tmp_dir: dir} do
    {server, _provider, store} = connect(dir, [[{:delay, 60_000}]])
    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{"params" => %{"update" => %{"sessionUpdate" => "user_message_chunk"}}}}

    pid = :sys.get_state(server).sessions[id].pid
    ref = Process.monitor(pid)
    GenServer.stop(server)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:ok, entries} = Store.read(store, id)
    assert Enum.any?(entries, &(&1.type == :cancelled))
    assert {:ok, lock} = Store.lock(store, id)
    assert :ok = Store.unlock(store, id, lock)
  end

  test "questions travel through a correlated client request", %{tmp_dir: dir} do
    {server, provider, _store} =
      connect(dir, [
        Scripted.tool_call("question", "ask_user", %{
          "question" => "Which?",
          "options" => [%{"label" => "A"}, %{"label" => "B"}]
        }),
        Scripted.complete("answered")
      ])

    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{
                      "id" => question_id,
                      "method" => "_lemieux/question",
                      "params" => %{"question" => %{"question" => "Which?"}}
                    }}

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => question_id,
      "result" => %{"answer" => "B"}
    })

    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    assert length(Scripted.requests(provider)) == 2
    assert :sys.get_state(server).pending == %{}
  end

  test "stdio contains only complete JSON-RPC frames", %{tmp_dir: dir} do
    input =
      JSON.encode!(%{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => 2}
      }) <> "\n"

    output =
      ExUnit.CaptureIO.capture_io(input, fn ->
        assert :ok = Lemieux.CLI.run(["acp", "--config", "none", "--sessions-dir", dir])
      end)

    assert [%{"id" => 1, "result" => %{"protocolVersion" => 2}}] =
             output |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  for {questions?, expected} <- [{false, "unavailable"}, {true, "cancelled"}] do
    test "questionnaire records #{expected} without inventing an answer", %{tmp_dir: dir} do
      {server, provider, store} =
        connect(
          dir,
          [
            Scripted.tool_call("question", "ask_user", %{
              "questions" => [%{"id" => "decision", "question" => "Proceed?", "type" => "text"}]
            }),
            Scripted.complete("continued")
          ],
          1,
          [],
          unquote(questions?)
        )

      id = open(server, dir)
      prompt(server, id)

      if unquote(questions?) do
        assert_receive {:wire, %{"id" => question_id, "method" => "_lemieux/question"}}

        Server.receive_message(server, %{
          "jsonrpc" => "2.0",
          "id" => question_id,
          "error" => %{"code" => -32_600, "message" => "cancelled"}
        })
      end

      assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
      assert length(Scripted.requests(provider)) == 2
      assert {:ok, entries} = Store.read(store, id)
      result = Enum.find(entries, &(&1.type == :tool_result))

      assert result.payload["structured_content"] == %{
               "version" => 1,
               "status" => "incomplete",
               "answers" => [%{"question_id" => "decision", "status" => unquote(expected)}]
             }

      refute_receive {:wire, %{"method" => "_lemieux/question"}}, 20
    end
  end

  test "initialization validates versions and notifications never create sessions", %{
    tmp_dir: dir
  } do
    assert {:ok, options} = Options.parse(["--config", "none"], command: :acp)
    owner = self()

    server =
      start_supervised!({Server, options: options, host: [], emit: &send(owner, {:wire, &1})})

    request(server, 1, "initialize", %{})
    assert_receive {:wire, %{"id" => 1, "error" => %{"code" => -32_602}}}
    request(server, 2, "initialize", %{"protocolVersion" => 42})
    assert_receive {:wire, %{"id" => 2, "result" => %{"protocolVersion" => 2}}}

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "method" => "session/new",
      "params" => %{"cwd" => dir}
    })

    assert :sys.get_state(server).sessions == %{}
    refute_receive {:wire, _unexpected}, 20
  end

  test "fork and configuration controls use native boundaries", %{tmp_dir: dir} do
    {server, provider, store} = connect(dir, [Scripted.complete("original")])
    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    request(server, 8, "_lemieux/fork", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 8, "result" => %{"sessionId" => forked}}}
    assert forked != id
    assert {:ok, entries} = Store.read(store, forked)
    assert Enum.any?(entries, &(&1.type == :fork))

    request(server, 9, "_lemieux/configure", %{
      "sessionId" => forked,
      "model" => "test:replacement"
    })

    assert_receive {:wire, %{"id" => 9, "result" => %{"model" => "test:replacement"}}}

    request(server, 10, "_lemieux/configure", %{
      "sessionId" => forked,
      "permissionMode" => "full_auto"
    })

    assert_receive {:wire, %{"id" => 10, "error" => %{"code" => -32_602}}}
    assert length(Scripted.requests(provider)) == 1
  end

  test "provider failure is a protocol failure and never a successful turn", %{tmp_dir: dir} do
    {server, provider, store} = connect(dir, [[{:error, :fixture_failure}]])
    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => 3, "error" => %{"code" => -32_000}}}
    assert {:ok, entries} = Store.read(store, id)
    assert Enum.any?(entries, &(&1.type == :error))
    assert length(Scripted.requests(provider)) == 1
    refute_receive {:wire, %{"id" => 3, "result" => _success}}, 20
  end

  test "malformed and unsupported requests do not start a provider", %{tmp_dir: dir} do
    {server, provider, _store} = connect(dir, [])
    Server.receive_line(server, "broken")
    assert_receive {:wire, %{"error" => %{"code" => -32_700}}}
    request(server, 2, "session/new", %{"cwd" => "relative"})
    assert_receive {:wire, %{"id" => 2, "error" => %{"code" => -32_602}}}
    request(server, 7, "unknown", %{})
    assert_receive {:wire, %{"id" => 7, "error" => %{"code" => -32_601}}}
    id = open(server, dir)

    request(server, 8, "session/prompt", %{
      "sessionId" => id,
      "prompt" => [%{"type" => "image", "data" => "x"}]
    })

    assert_receive {:wire, %{"id" => 8, "error" => %{"code" => -32_602}}}
    assert Scripted.requests(provider) == []
  end
end
