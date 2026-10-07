defmodule Lemieux.IxwayTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.ProviderMux
  alias Lemieux.CLI.Runtime
  alias Lemieux.Ixway
  alias Lemieux.Provider
  alias Lemieux.Provider.Route
  alias Lemieux.Providers.ReqLLM, as: Adapter
  alias Lemieux.Request
  alias Lemieux.Store.JSONL

  test "gateway credentials and endpoints are private runtime state" do
    connection = Ixway.new(endpoint: "https://gateway.example/", api_key: "private-key")
    assert connection.endpoint == "https://gateway.example"
    refute inspect(connection) =~ "private-key"
    refute inspect(Ixway.provider(connection)) =~ "gateway.example"
  end

  test "rejects ambiguous endpoints and mixed transport policies" do
    for endpoint <- [
          "gateway.example",
          "https://key@gateway.example",
          "https://gateway.example/v1",
          "https://gateway.example?key=secret"
        ] do
      assert_raise ArgumentError, fn -> Ixway.new(endpoint: endpoint) end
    end

    assert_raise ArgumentError, fn ->
      Ixway.provider([endpoint: "https://gateway.example"], api_key: "vendor-key")
    end
  end

  test "uses only compatible gateway models and conservative limits" do
    provider = Ixway.provider(connection())
    assert Provider.available_models(provider) == ["ixway:team/coding"]

    assert Provider.model_metadata(provider) == %{
             "ixway:team/coding" => %{kind: nil, route: "Automatic"}
           }

    assert Provider.available_models(provider, provider: "anthropic") == []
    assert Provider.available_models(provider, scope: :anthropic) == []
    assert Provider.available_models(provider, scope: :ixway) == ["ixway:team/coding"]

    # The shape `Lemieux.Session` actually asks with. Reading it as a bare
    # list of names raised `String.Chars` on `{:chat, true}` while the TUI was
    # starting, so an Ixway-configured host could not open a session at all.
    assert Provider.available_models(provider, require: [chat: true]) == ["ixway:team/coding"]

    assert Provider.available_models(provider, require: [chat: true, tools: true]) == [
             "ixway:team/coding"
           ]

    # A capability the catalogue marks unsupported is excluded when it is
    # required, and not when it is merely named.
    unsupported =
      Ixway.provider(%{
        connection()
        | models: [
            Map.put(catalogue_entry(), "ixway_capabilities", %{
              "tools" => %{"status" => "unsupported"}
            })
          ]
      })

    assert Provider.available_models(unsupported, require: [chat: true, tools: true]) == []

    assert Provider.available_models(unsupported, require: [chat: true, tools: false]) == [
             "ixway:team/coding"
           ]

    assert Provider.context_window(provider, "ixway:team/coding") == 32_000
    assert Provider.context_window(provider, "openai:gpt-5") == nil
    assert Provider.estimate_cost(provider, Request.new("ixway:team/coding")) == nil
    assert Provider.validate_model(provider, "ixway:team/coding", []) == :ok

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Provider.validate_model(provider, "openai:gpt-5", [])
  end

  test "picker metadata distinguishes qualified routes from colons in model ids" do
    models = [
      %{
        "id" => "gpt-5.6-luna",
        "ixway_model_kind" => "concrete",
        "ixway_provider" => "openai_codex"
      },
      %{
        "id" => "openai_codex:gpt-5.6-luna",
        "ixway_model_kind" => "concrete",
        "ixway_provider" => "openai_codex"
      },
      %{"id" => "llama:8b", "ixway_model_kind" => "concrete", "ixway_provider" => "ollama"}
    ]

    assert Ixway.model_metadata(%{connection() | models: models}) == %{
             "ixway:gpt-5.6-luna" => %{kind: "concrete", route: "Automatic"},
             "ixway:openai_codex:gpt-5.6-luna" => %{kind: "concrete", route: "openai_codex"},
             "ixway:llama:8b" => %{kind: "concrete", route: "Automatic"}
           }
  end

  test "picker metadata carries an optional Ixway model release date" do
    entry = %{
      "id" => "gpt-6-luna",
      "ixway_model_kind" => "concrete",
      "ixway_provider" => "openai",
      "ixway_release_date" => "2026-09-22"
    }

    assert Ixway.model_metadata(%{connection() | models: [entry]}) == %{
             "ixway:gpt-6-luna" => %{
               kind: "concrete",
               route: "Automatic",
               release_date: "2026-09-22"
             }
           }
  end

  describe "reasoning effort" do
    test "offers the levels the catalogue publishes, in the order it publishes them" do
      provider = Ixway.provider(connection(%{"ixway_reasoning_effort" => ~w(none low high)}))

      # `default` is lemieux's own sentinel for sending no parameter at all,
      # and the gateway never publishes it. It leads, because "leave it to the
      # route" is the choice a session starts on.
      assert Provider.reasoning_efforts(provider, "ixway:team/coding") ==
               ["default", "none", "low", "high"]
    end

    # An older instance omits the key; a family that budgets tokens rather
    # than naming levels has none to publish. Neither is a reason to offer a
    # menu, and neither may look different from the other.
    test "an entry that publishes nothing offers no menu at all" do
      for absent <- [%{}, %{"ixway_reasoning_effort" => []}, %{"ixway_reasoning_effort" => nil}] do
        provider = Ixway.provider(connection(absent))

        assert Provider.reasoning_efforts(provider, "ixway:team/coding") == []
      end
    end

    test "a model the gateway does not serve offers no menu" do
      provider = Ixway.provider(connection(%{"ixway_reasoning_effort" => ~w(low high)}))

      assert Provider.reasoning_efforts(provider, "openai:gpt-5") == []
    end

    # The catalogue is a gateway's JSON, so its contents are data rather than
    # a promise about shape. A level that is not a usable name is dropped
    # instead of reaching a request as a parameter or a menu as a row.
    test "unusable entries in a published list are dropped rather than offered" do
      provider =
        Ixway.provider(connection(%{"ixway_reasoning_effort" => ["low", "", nil, 7, "high"]}))

      assert Provider.reasoning_efforts(provider, "ixway:team/coding") == [
               "default",
               "low",
               "high"
             ]
    end
  end

  test "selects the key default and never substitutes an unavailable default" do
    assert {:ok, "ixway:team/coding"} = Ixway.select_model(connection(), "ixway:@default")
    denied = %{connection() | client_policy: %{"default_profile" => %{"status" => "unavailable"}}}

    assert {:error, %Ixway.Error{reason: :model_choice_required}} =
             Ixway.select_model(denied, "ixway:@default")
  end

  test "discovery validates the public contract and authenticates only the catalogue" do
    parent = self()

    endpoint =
      discovery_server(fn request ->
        send(parent, {:discovery, request.path, request.headers})

        case request.path do
          "/.well-known/ixway" ->
            {200, %{"product" => "ixway", "ingress_dialects" => %{"openai_chat" => %{}}}}

          "/v1/models" ->
            {200, %{"data" => connection().models, "ixway_client" => connection().client_policy}}
        end
      end)

    assert {:ok, discovered} =
             Ixway.discover(Ixway.new(endpoint: endpoint, api_key: "fixture-key"))

    assert discovered.models == connection().models
    assert_receive {:discovery, "/.well-known/ixway", public}
    refute Map.has_key?(public, "authorization")
    assert_receive {:discovery, "/v1/models", authenticated}
    assert authenticated["authorization"] == "Bearer fixture-key"
    assert authenticated["user-agent"] == "Lemieux-Ixway/1"
  end

  test "Ixway is prepared through the generic route preparation" do
    connection = connection()

    assert {:ok, ^connection} = Ixway.ready(connection)
    assert {:ok, "ixway:team/coding"} = Ixway.default_model(connection)

    assert {:ok, {Ixway, ^connection}, "ixway:team/coding"} =
             Route.prepare({Ixway, connection}, "ixway:@default")

    assert {:error, %Ixway.Error{reason: :model_not_available}} =
             Route.prepare({Ixway, connection}, "ixway:missing")

    denied = %{connection | client_policy: %{"default_profile" => %{"status" => "unavailable"}}}

    assert {:error, %Ixway.Error{reason: :model_choice_required}} =
             Route.prepare({Ixway, denied}, "ixway:@default")

    assert Ixway.prepare(Ixway.provider(connection), "ixway:@default") ==
             Adapter.prepare(Ixway.provider(connection), "ixway:@default")
  end

  test "TUI prefetch retains a catalogue for model selection without another request" do
    parent = self()

    endpoint =
      discovery_server(fn request ->
        send(parent, {:prefetch_request, request.path})

        case request.path do
          "/.well-known/ixway" ->
            {200, %{"product" => "ixway", "ingress_dialects" => %{"openai_chat" => %{}}}}

          "/v1/models" ->
            {200, %{"data" => connection().models, "ixway_client" => connection().client_policy}}
        end
      end)

    provider =
      ProviderMux.new(
        [{"ixway", Ixway.provider(endpoint: endpoint, api_key: "private-key")}],
        Adapter.new(api_keys: %{"openai" => "direct-key"})
      )

    assert {:ok, discovered} = Runtime.discover_tui_provider(provider)

    assert {:ok, prepared, "ixway:team/coding"} =
             ProviderMux.prepare(discovered, "ixway:@default")

    assert Provider.available_models(prepared, scope: :ixway) == ["ixway:team/coding"]
    assert_receive {:prefetch_request, "/.well-known/ixway"}
    assert_receive {:prefetch_request, "/v1/models"}
    refute_receive {:prefetch_request, _path}, 20
    refute inspect(prepared) =~ "private-key"
  end

  test "missing credentials, invalid catalogues and redirects never fall through" do
    assert {:error, %Ixway.Error{reason: :api_key_required}} =
             Ixway.discover(Ixway.new(endpoint: "https://unused.example"))

    endpoint =
      discovery_server(fn request ->
        case request.path do
          "/.well-known/ixway" ->
            {200, %{"product" => "ixway", "ingress_dialects" => %{"openai_chat" => %{}}}}

          "/v1/models" ->
            {200, %{"data" => [%{"id" => "*"}]}}
        end
      end)

    assert {:error, %Ixway.Error{reason: :invalid_catalogue}} =
             Ixway.discover(Ixway.new(endpoint: endpoint, api_key: "key"))

    redirect = discovery_server(fn _ -> {302, %{}} end)

    assert {:error, %Ixway.Error{reason: {:http_status, 302}}} =
             Ixway.discover(Ixway.new(endpoint: redirect, api_key: "key"))
  end

  test "streaming uses the gateway key, tool constraints, correlation and disclosed route" do
    parent = self()

    {endpoint, listener, server} =
      LemieuxTest.HTTPFixture.server(fn headers, body, socket ->
        send(parent, {:inference, headers, JSON.decode!(body)})

        events = [
          %{
            "id" => "response-1",
            "model" => "resolved-model",
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => "hello"}, "finish_reason" => nil}
            ]
          },
          %{
            "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
            "usage" => %{"prompt_tokens" => 12, "completion_tokens" => 3, "total_tokens" => 15}
          }
        ]

        body =
          Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <>
            "data: [DONE]\n\n"

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nx-ixway-resolved-model: resolved-model\r\nx-ixway-decision-id: decision-1\r\nx-ixway-key: never-record\r\ncontent-length: ",
            Integer.to_string(byte_size(body)),
            "\r\nconnection: close\r\n\r\n",
            body
          ])

        :sent
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    config = %{
      connection()
      | endpoint: endpoint,
        headers: [
          {"x-ixway-residency", "local_only"},
          {"x-ixway-session-id", "ixbench-run-1"}
        ]
    }

    provider = Ixway.provider(config, max_retries: 0)

    request =
      Request.new("ixway:team/coding",
        tools: [Lemieux.Tools.Read, Lemieux.Tools.AskUser],
        context: %{
          session_id: "session-1",
          agent_id: "child-1",
          parent_agent_id: "session-1",
          request_id: "request-1"
        },
        entries: [Lemieux.Entry.new(:user, %{"text" => "hello"}, seq: 1)],
        params: [
          base_url: "https://must-not-contact.example",
          api_key: "wrong-key",
          req_http_options: [headers: [{"authorization", "Bearer wrong"}]]
        ]
      )

    assert :ok = Provider.run(provider, request, &send(parent, {:event, &1}))
    assert_receive {:inference, headers, body}
    assert headers["authorization"] == "Bearer gateway-key"
    assert headers["x-ixway-required-capabilities"] == "tools"
    assert headers["x-ixway-session-id"] == "ixbench-run-1"
    assert headers["x-ixway-conversation-id"] == "session-1"

    # A subagent is an actor inside a conversation, not a conversation of its
    # own: it reports the root's session id and names itself and its spawner.
    # Without these a gateway sees one agent making more requests, and no
    # configuration recovers the difference.
    assert headers["x-ixway-agent-id"] == "child-1"
    assert headers["x-ixway-parent-agent-id"] == "session-1"
    refute Map.has_key?(headers, "x-ixway-request-id")
    assert headers["x-ixway-residency"] == "local_only"
    assert body["model"] == "team/coding"

    assert [
             %{"function" => %{"name" => "read"}},
             %{"function" => %{"name" => "ask_user", "parameters" => ask_schema}}
           ] = body["tools"]

    assert ask_schema["type"] == "object"

    for keyword <- ~w(oneOf anyOf allOf enum const not) do
      refute Map.has_key?(ask_schema, keyword)
    end

    assert ask_schema["properties"]["questions"]["type"] == "array"
    assert ask_schema["properties"]["question"]["type"] == "string"
    assert_receive {:event, {:text_delta, "hello"}}
    assert_receive {:event, {:message, %{"ixway" => disclosure}}}
    assert disclosure == %{"resolved_model" => "resolved-model", "decision_id" => "decision-1"}
    assert_receive {:event, {:usage, usage}}
    assert usage["input_tokens"] == 12
    assert Lemieux.Usage.normalize(usage, request.model)["cost_usd"] == nil
    assert_receive {:event, {:done, :stop}}
  end

  test "explicit unsupported tools are rejected; partial pools require capable admission" do
    [entry] = connection().models

    blocked = %{
      connection()
      | models: [Map.put(entry, "ixway_capabilities", %{"tools" => %{"status" => "unsupported"}})]
    }

    assert {:error, %Ixway.Error{reason: :tools_unsupported}} =
             Provider.validate_model(Ixway.provider(blocked), "ixway:team/coding", [
               Lemieux.Tools.Read
             ])

    assert :ok = Provider.validate_model(Ixway.provider(blocked), "ixway:team/coding", [])
  end

  test "known OpenAI IDs retain the explicitly selected chat grammar" do
    config = %{
      connection()
      | models: [%{"id" => "gpt-5", "ixway_ingress_dialects" => ["openai_chat"]}]
    }

    assert {:ok, {model, opts}} = Ixway.target(config, Request.new("ixway:gpt-5"), [])
    assert model.extra.wire.protocol == "openai_chat"
    assert opts[:base_url] == "https://gateway.example/v1"
  end

  @tag :tmp_dir
  test "startup resolves the default and resume retains the model with a fresh connection", %{
    tmp_dir: tmp_dir
  } do
    endpoint =
      discovery_server(fn request ->
        case request.path do
          "/.well-known/ixway" ->
            {200, %{"product" => "ixway", "ingress_dialects" => %{"openai_chat" => %{}}}}

          "/v1/models" ->
            {200, %{"data" => connection().models, "ixway_client" => connection().client_policy}}
        end
      end)

    provider = Ixway.provider(endpoint: endpoint, api_key: "private-key")
    {:ok, options} = Options.parse(["--model", "ixway:@default"])
    store = JSONL.new(tmp_dir)
    supervisor = :"ixway_startup_#{System.unique_integer([:positive])}"

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: provider,
               store: store,
               supervisor: supervisor,
               tools: []
             )

    assert :sys.get_state(session).model == "ixway:team/coding"

    assert Lemieux.Session.model_metadata(session) == %{
             "ixway:team/coding" => %{kind: nil, route: "Automatic"}
           }

    id = Lemieux.Session.id(session)
    Supervisor.stop(supervisor)

    {:ok, options} = Options.parse(["--resume", id])

    assert {:ok, resumed} =
             Runtime.start_session(options,
               provider: provider,
               store: store,
               supervisor: supervisor,
               tools: []
             )

    assert :sys.get_state(resumed).model == "ixway:team/coding"
    Supervisor.stop(supervisor)

    contents =
      tmp_dir |> Path.join("**/*.jsonl") |> Path.wildcard() |> Enum.map_join(&File.read!/1)

    assert contents =~ "ixway:team/coding"
    refute contents =~ "ixway:@default"
    refute contents =~ "private-key"
    refute contents =~ endpoint
  end

  test "structured output and tool calls use the same gateway transport" do
    parent = self()
    structured = %{"verdict" => "yes", "reason" => "verified"}

    config =
      stream_fixture(parent, [
        %{
          "choices" => [
            %{
              "index" => 0,
              "delta" => %{"content" => JSON.encode!(structured)},
              "finish_reason" => "stop"
            }
          ]
        }
      ])

    request =
      Request.new("ixway:team/coding",
        output_schema: [
          verdict: [type: :string, required: true],
          reason: [type: :string, required: true]
        ]
      )

    assert :ok =
             Provider.run(Ixway.provider(config), request, &send(parent, {:structured, &1}))

    assert_receive {:wire, %{"model" => "team/coding"} = body}
    assert body["response_format"] || body["tools"]
    assert_receive {:structured, {:message, %{"content" => [%{"text" => json}]}}}
    assert JSON.decode!(json) == structured

    call = %{
      "index" => 0,
      "id" => "call-1",
      "type" => "function",
      "function" => %{"name" => "read", "arguments" => JSON.encode!(%{"path" => "README.md"})}
    }

    config =
      stream_fixture(parent, [
        %{
          "choices" => [
            %{"index" => 0, "delta" => %{"tool_calls" => [call]}, "finish_reason" => "tool_calls"}
          ]
        }
      ])

    assert :ok =
             Provider.run(
               Ixway.provider(config),
               Request.new("ixway:team/coding", tools: [Lemieux.Tools.Read]),
               &send(parent, {:tools, &1})
             )

    assert_receive {:tools,
                    {:tool_call,
                     %{id: "call-1", name: "read", arguments: %{"path" => "README.md"}}}}

    assert_receive {:tools, {:done, :tool_calls}}
  end

  test "a partial stream ending in a gateway error cannot report completion" do
    parent = self()

    config =
      stream_fixture(parent, [
        %{
          "choices" => [
            %{"index" => 0, "delta" => %{"content" => "partial"}, "finish_reason" => nil}
          ]
        },
        %{
          "error" => %{
            "message" => "backend failed",
            "type" => "server_error",
            "code" => "upstream_error"
          }
        }
      ])

    assert {:error, _} =
             Provider.run(
               Ixway.provider(config),
               Request.new("ixway:team/coding"),
               &send(parent, {:partial, &1})
             )

    refute_receive {:partial, {:done, _}}
  end

  # The projection used to live in `Lemieux.Provider.Error`, one clause per
  # Ixway failure. The same sentences now come from the typed error itself, so
  # a host that formats through `Provider.Error` sees no difference and the
  # error module knows nothing about this gateway.
  test "errors describe themselves through Provider.Error, with the sentences hosts saw before" do
    expected = [
      {:api_key_required, "Ixway requires IXWAY_API_KEY (a gateway model key)."},
      {:model_choice_required,
       "Ixway has no available compatible default. Choose an advertised model with --model ixway:ID."},
      {:model_not_available,
       "Choose an ixway:ID advertised by this gateway key for OpenAI chat. Direct-provider models are unavailable in Ixway mode."},
      {:tools_unsupported,
       "This Ixway model does not support the session's tools. Choose a tool-capable profile."},
      {:connection_failed,
       "Cannot reach Ixway discovery. Check the instance URL and network connection."},
      {{:http_status, 403},
       "Ixway discovery returned HTTP 403. Check the gateway key and access policy."},
      {:invalid_catalogue, "Ixway discovery failed: invalid_catalogue."},
      {:incompatible_instance, "Ixway discovery failed: incompatible_instance."}
    ]

    for {reason, sentence} <- expected do
      error = %Ixway.Error{reason: reason}
      assert Exception.message(error) == sentence
      assert Lemieux.Provider.Error.message(error) == sentence

      # Typed, so policy reads the failure as data: no status, no retry-after,
      # nothing a transport retry would change.
      assert Lemieux.Provider.Error.category(error) == :other
      assert Lemieux.Provider.Error.retry_after_ms(error) == nil
      refute Lemieux.Provider.Error.transient?(error)
    end
  end

  test "the connection behind a routed provider is reachable, and absent from a direct one" do
    assert Ixway.connection(Ixway.provider(connection())) == connection()
    assert Ixway.connection(Adapter.new()) == nil
  end

  test "the route is the behaviour the adapter dispatches to" do
    assert Lemieux.Provider.Route in List.flatten(
             Keyword.get_values(Ixway.module_info(:attributes), :behaviour)
           )

    assert {Lemieux.Providers.ReqLLM, %{route: {Ixway, %Ixway{}}}} =
             Ixway.provider(connection())
  end

  defp stream_fixture(parent, events) do
    {endpoint, listener, server} =
      LemieuxTest.HTTPFixture.server(fn _headers, body, _socket ->
        send(parent, {:wire, JSON.decode!(body)})

        body =
          Enum.map_join(events, "", &("data: " <> JSON.encode!(&1) <> "\n\n")) <>
            "data: [DONE]\n\n"

        %{status: 200, headers: [{"content-type", "text/event-stream"}], body: body}
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    %{connection() | endpoint: endpoint}
  end

  defp discovery_server(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    server = spawn(fn -> accept_discovery(listener, handler) end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept_discovery(listener, handler) do
    case :gen_tcp.accept(listener, 10_000) do
      {:ok, socket} ->
        head = read_head(socket, "")
        [line | headers] = String.split(head, "\r\n", trim: true)
        [_method, path, _version] = String.split(line, " ")

        headers =
          Map.new(headers, fn header ->
            [key, value] = String.split(header, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        {status, data} = handler.(%{path: path, headers: headers})
        body = JSON.encode!(data)

        :gen_tcp.send(socket, [
          "HTTP/1.1 ",
          Integer.to_string(status),
          " OK\r\ncontent-type: application/json\r\nlocation: https://must-not-contact.example\r\ncontent-length: ",
          Integer.to_string(byte_size(body)),
          "\r\nconnection: close\r\n\r\n",
          body
        ])

        :gen_tcp.close(socket)
        accept_discovery(listener, handler)

      {:error, _} ->
        :ok
    end
  end

  defp read_head(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [head, _rest] ->
        head

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        read_head(socket, bytes <> more)
    end
  end

  defp connection(entry_overrides \\ %{}) do
    %{
      Ixway.new(endpoint: "https://gateway.example", api_key: "gateway-key")
      | models: [Map.merge(catalogue_entry(), entry_overrides)],
        client_policy: %{"default_profile" => %{"id" => "team/coding", "status" => "available"}}
    }
  end

  defp catalogue_entry do
    %{
      "id" => "team/coding",
      "ixway_ingress_dialects" => ["openai_chat"],
      "ixway_default_for" => ["openai_chat"],
      "max_input_tokens" => 32_000
    }
  end
end
