defmodule Lemieux.CLI.ACPTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.Server
  alias Lemieux.CLI.Options
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp connect(dir, script, version \\ 1, flags \\ [], questions? \\ true, capabilities \\ %{}) do
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
      "clientCapabilities" =>
        Map.put(capabilities, "_meta", %{"lemieux" => %{"question" => questions?}})
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
    assert_receive {:wire, %{"id" => 3, "error" => %{"code" => -32_603}}}
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

  for version <- [1, 2] do
    test "v#{version} exposes and validates standard configuration options", %{tmp_dir: dir} do
      version = unquote(version)
      {server, provider, _store} = connect(dir, [[{:delay, 60_000}]], version)
      request(server, 2, "session/new", %{"cwd" => dir, "mcpServers" => []})

      assert_receive {:wire,
                      %{"id" => 2, "result" => %{"sessionId" => id, "configOptions" => options}}}

      key = if version == 1, do: "id", else: "configId"
      model = Enum.find(options, &(&1[key] == "model"))
      assert model["category"] == "model"
      assert Enum.any?(model["options"], &(&1["value"] == model["currentValue"]))

      params = %{"sessionId" => id, "configId" => "model", "value" => model["currentValue"]}
      params = if version == 2, do: Map.put(params, "type", "id"), else: params
      request(server, 7, "session/set_config_option", params)
      assert_receive {:wire, %{"id" => 7, "result" => %{"configOptions" => ^options}}}

      request(server, 8, "session/set_config_option", %{params | "value" => "test:not-offered"})
      assert_receive {:wire, %{"id" => 8, "error" => %{"code" => -32_602}}}
      assert Scripted.requests(provider) == []

      prompt(server, id)

      assert_receive {:wire, %{"params" => %{"update" => %{"sessionUpdate" => update}}}}
                     when update in ["user_message_chunk", "state_update"]

      request(server, 9, "session/set_config_option", params)
      assert_receive {:wire, %{"id" => 9, "error" => %{"code" => -32_602}}}
      request(server, 10, "session/cancel", %{"sessionId" => id})
      assert_receive {:wire, %{"id" => 10, "result" => %{}}}
    end
  end

  test "editor reads and writes carry real tool ids and preserve unsaved text", %{tmp_dir: dir} do
    path = Path.join(dir, "file.txt")
    File.write!(path, "disk")

    {server, _provider, store} =
      connect(
        dir,
        [
          Scripted.tool_call("read", "read", %{"path" => "file.txt"}),
          Scripted.tool_call("write", "write", %{"path" => "file.txt", "content" => "changed"}),
          Scripted.complete("done")
        ],
        1,
        ["--permission-mode", "full_auto"],
        false,
        %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}
      )

    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "toolCallId" => "read",
                          "kind" => "read",
                          "locations" => [%{"path" => ^path}]
                        }
                      }
                    }}

    for _read <- 1..3 do
      assert_receive {:wire,
                      %{
                        "id" => rpc_id,
                        "method" => "fs/read_text_file",
                        "params" => %{"sessionId" => ^id, "path" => ^path}
                      }}

      Server.receive_message(server, %{
        "jsonrpc" => "2.0",
        "id" => rpc_id,
        "result" => %{"content" => "unsaved"}
      })
    end

    assert_receive {:wire,
                    %{
                      "id" => rpc_id,
                      "method" => "fs/write_text_file",
                      "params" => %{"path" => ^path, "content" => "changed"}
                    }}

    Server.receive_message(server, %{"jsonrpc" => "2.0", "id" => rpc_id, "result" => %{}})

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "toolCallId" => "write",
                          "content" => [
                            %{"type" => "diff", "oldText" => "unsaved", "newText" => "changed"}
                          ]
                        }
                      }
                    }}

    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    assert File.read!(path) == "disk"

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "toolCallId" => "write",
                          "status" => "completed",
                          "content" => [
                            %{"type" => "diff", "oldText" => "unsaved", "newText" => "changed"},
                            %{"type" => "content"}
                          ]
                        }
                      }
                    }}

    assert {:ok, entries} = Store.read(store, id)
    assert Enum.any?(entries, &(&1.type == :tool_result and &1.payload["output"] =~ "unsaved"))
    assert :sys.get_state(server).pending == %{}
  end

  test "cancelling a pending editor read discards late replies", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "file.txt"), "original")

    {server, provider, _store} =
      connect(dir, [Scripted.tool_call("read", "read", %{"path" => "file.txt"})], 1, [], false, %{
        "fs" => %{"readTextFile" => true}
      })

    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => rpc_id, "method" => "fs/read_text_file"}}
    request(server, 4, "session/cancel", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "cancelled"}}}

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => rpc_id,
      "result" => %{"content" => "late"}
    })

    assert :sys.get_state(server).pending == %{}
    assert length(Scripted.requests(provider)) == 1
  end

  test "standard form elicitation answers a native questionnaire", %{tmp_dir: dir} do
    {server, _provider, store} =
      connect(
        dir,
        [
          Scripted.tool_call("question", "ask_user", %{
            "questions" => [
              %{
                "id" => "choice",
                "question" => "Which?",
                "type" => "single_choice",
                "options" => [%{"id" => "a", "label" => "A"}, %{"id" => "b", "label" => "B"}]
              }
            ]
          }),
          Scripted.complete("answered")
        ],
        1,
        [],
        false,
        %{"elicitation" => %{"form" => %{}}}
      )

    id = open(server, dir)
    prompt(server, id)

    assert_receive {:wire,
                    %{
                      "id" => rpc_id,
                      "method" => "elicitation/create",
                      "params" => %{
                        "sessionId" => ^id,
                        "mode" => "form",
                        "requestedSchema" => %{"required" => ["choice"]}
                      }
                    }}

    Server.receive_message(server, %{
      "jsonrpc" => "2.0",
      "id" => rpc_id,
      "result" => %{"action" => "accept", "content" => %{"choice" => "2"}}
    })

    assert_receive {:wire, %{"id" => 3, "result" => %{"stopReason" => "end_turn"}}}
    assert {:ok, entries} = Store.read(store, id)
    result = Enum.find(entries, &(&1.type == :tool_result))

    assert result.payload["structured_content"]["answers"] == [
             %{
               "question_id" => "choice",
               "status" => "answered",
               "kind" => "selection",
               "selected" => ["b"]
             }
           ]
  end

  test "load and resume reuse an idle session and close is idempotent", %{tmp_dir: dir} do
    {server, provider, _store} = connect(dir, [Scripted.complete("retained")])
    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => 3, "result" => %{}}}
    pid = :sys.get_state(server).sessions[id].pid

    for {method, rpc_id} <- [{"session/load", 4}, {"session/resume", 5}] do
      request(server, rpc_id, method, %{"sessionId" => id, "cwd" => dir, "mcpServers" => []})
      assert_receive {:wire, %{"id" => ^rpc_id, "result" => %{"sessionId" => ^id}}}
      assert :sys.get_state(server).sessions[id].pid == pid
    end

    for rpc_id <- 6..7 do
      request(server, rpc_id, "session/close", %{"sessionId" => id})
      assert_receive {:wire, %{"id" => ^rpc_id, "result" => %{}}}
    end

    request(server, 8, "session/prompt", %{
      "sessionId" => id,
      "prompt" => [%{"type" => "text", "text" => "hello"}]
    })

    assert_receive {:wire,
                    %{"id" => 8, "error" => %{"code" => -32_002, "data" => %{"sessionId" => ^id}}}}

    assert length(Scripted.requests(provider)) == 1
  end

  test "v2 holds busy prompts and cancels them without inserting another message", %{tmp_dir: dir} do
    owner = self()

    {server, provider, store} =
      connect(
        dir,
        [
          fn _request ->
            send(owner, :acp_provider_started)
            [{:delay, 60_000}]
          end
        ],
        2
      )

    id = open(server, dir)
    prompt(server, id)
    assert_receive {:wire, %{"id" => 3, "result" => %{"messageId" => _}}}
    assert_receive :acp_provider_started

    request(server, 4, "session/prompt", %{
      "sessionId" => id,
      "prompt" => [%{"type" => "text", "text" => "queued"}]
    })

    assert [{4, "queued"}] = :sys.get_state(server).sessions[id].queued
    request(server, 5, "session/cancel", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 4, "error" => %{"code" => -32_800}}}
    assert {:ok, entries} = Store.read(store, id)
    assert Enum.count(entries, &(&1.type == :user)) == 1
    assert length(Scripted.requests(provider)) == 1
  end

  test "invalid workspace filters and duplicate MCP names fail before execution", %{tmp_dir: dir} do
    {server, provider, _store} = connect(dir, [])
    request(server, 4, "session/list", %{"cwd" => "relative"})
    assert_receive {:wire, %{"id" => 4, "error" => %{"code" => -32_602}}}
    mcp = %{"name" => "duplicate", "command" => "must-not-start", "args" => [], "env" => []}
    request(server, 5, "session/new", %{"cwd" => dir, "mcpServers" => [mcp, mcp]})
    assert_receive {:wire, %{"id" => 5, "error" => %{"code" => -32_602}}}
    assert :sys.get_state(server).sessions == %{}
    assert Scripted.requests(provider) == []
  end

  test "v2 inserts a held prompt only after the current turn completes", %{tmp_dir: dir} do
    owner = self()

    first = fn _request ->
      send(owner, {:held_acp_request, self()})

      receive do
        :release -> Scripted.complete("first")
      after
        60_000 -> Scripted.error(:fixture_expired)
      end
    end

    # The interactive host also makes its one session-label request after
    # two exchanges. Give that auxiliary request its own scripted response.
    {server, provider, store} =
      connect(
        dir,
        [first, Scripted.complete("second"), Scripted.complete("Queued ACP session")],
        2
      )

    id = open(server, dir)
    prompt(server, id)
    assert_receive {:held_acp_request, worker}
    assert_receive {:wire, %{"id" => 3, "result" => %{"messageId" => first_id}}}

    request(server, 4, "session/prompt", %{
      "sessionId" => id,
      "prompt" => [%{"type" => "text", "text" => "next"}]
    })

    assert [{4, "next"}] = :sys.get_state(server).sessions[id].queued
    send(worker, :release)
    assert_receive {:wire, %{"params" => %{"update" => %{"state" => "idle"}}}}
    assert_receive {:wire, %{"id" => 4, "result" => %{"messageId" => second_id}}}
    assert first_id != second_id

    assert_receive {:wire,
                    %{
                      "params" => %{
                        "update" => %{
                          "sessionUpdate" => "agent_message",
                          "content" => [%{"text" => "second"}]
                        }
                      }
                    }}

    assert_receive {:wire, %{"params" => %{"update" => %{"state" => "idle"}}}}
    assert {:ok, entries} = Store.read(store, id)
    assert Enum.map(Enum.filter(entries, &(&1.type == :user)), & &1.id) == [first_id, second_id]
    assert [_, _, summary] = Scripted.requests(provider)
    assert summary.tools == []
  end

  test "closed session reconstruction retains its native tool catalog", %{tmp_dir: dir} do
    {server, provider, _store} = connect(dir, [])
    id = open(server, dir)
    before = Lemieux.Session.info(:sys.get_state(server).sessions[id].pid).tools
    assert "read" in before
    assert "write" in before
    request(server, 4, "session/close", %{"sessionId" => id})
    assert_receive {:wire, %{"id" => 4, "result" => %{}}}
    request(server, 5, "session/load", %{"sessionId" => id, "cwd" => dir, "mcpServers" => []})
    assert_receive {:wire, %{"id" => 5, "result" => %{"sessionId" => ^id}}}
    assert Lemieux.Session.info(:sys.get_state(server).sessions[id].pid).tools == before
    assert Scripted.requests(provider) == []
  end

  test "a rejected repeated v2 initialization preserves the initialized connection", %{
    tmp_dir: dir
  } do
    {server, _provider, _store} = connect(dir, [], 2)
    request(server, 2, "initialize", %{"protocolVersion" => 2})
    assert_receive {:wire, %{"id" => 2, "result" => %{"protocolVersion" => 2}}}
    request(server, 3, "initialize", %{"protocolVersion" => "invalid"})
    assert_receive {:wire, %{"id" => 3, "error" => %{"code" => -32_602}}}
    request(server, 4, "unknown", %{})
    assert_receive {:wire, %{"id" => 4, "error" => %{"code" => -32_601}}}
    assert :sys.get_state(server).version == 2
  end
end
