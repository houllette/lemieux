defmodule Lemieux.MCP.SessionTest do
  @moduledoc """
  MCP tools inside a real session, with a real server behind them.

  The point of every test here is sameness: once a remote tool is resolved it
  goes through the dispatch, hooks, approval, transcript and error handling
  that `read` and `bash` go through, and nothing downstream knows the
  difference.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Clock.Manual
  alias Lemieux.Entry
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tools

  @moduletag :tmp_dir

  @fixture Path.expand("../../fixtures/mcp_server.py", __DIR__)

  # A server that offers prompts and no tools, spoken in memory so no fixture
  # mode is needed for it.
  # Reports the connect options it was configured with to a registered test
  # process, named in its configuration, and offers one tool.
  defmodule Probe do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    @impl true
    def configure(config, opts) do
      send(String.to_existing_atom(config["probe"]), {:configured, opts[:interactive_auth]})
      {:ok, %{}}
    end

    @impl true
    def connect(config), do: {:ok, config}

    @impl true
    def call(state, %{"id" => id, "method" => "server/discover"}, _timeout),
      do: {:ok, %{"id" => id, "result" => %{"supportedVersions" => ["2026-07-28"]}}, state}

    def call(state, %{"id" => id, "method" => "tools/list"}, _timeout) do
      tools = [%{"name" => "t", "inputSchema" => %{"type" => "object"}}]
      {:ok, %{"id" => id, "result" => %{"tools" => tools}}, state}
    end

    @impl true
    def notify(state, _message), do: {:ok, state}
    @impl true
    def prepare_tools(state, tools), do: {tools, state}
    @impl true
    def close(_state), do: :ok
  end

  defmodule PromptsOnly do
    @moduledoc false
    @behaviour Lemieux.MCP.Transport

    @impl true
    def configure(_config, _opts), do: {:ok, %{}}
    @impl true
    def connect(config), do: {:ok, config}

    @impl true
    def call(state, %{"id" => id, "method" => "server/discover"}, _timeout) do
      result = %{"supportedVersions" => ["2026-07-28"], "capabilities" => %{"prompts" => %{}}}
      {:ok, %{"id" => id, "result" => result}, state}
    end

    def call(state, %{"id" => id, "method" => "tools/list"}, _timeout),
      do: {:ok, %{"id" => id, "result" => %{"tools" => []}}, state}

    def call(state, %{"id" => id, "method" => "prompts/list"}, _timeout),
      do: {:ok, %{"id" => id, "result" => %{"prompts" => [%{"name" => "review"}]}}, state}

    @impl true
    def notify(state, _message), do: {:ok, state}
    @impl true
    def prepare_tools(state, tools), do: {tools, state}
    @impl true
    def close(_state), do: :ok
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_mcp_session_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp server(name \\ "fixture", mode \\ "modern") do
    %{"name" => name, "transport" => "stdio", "command" => "python3", "args" => [@fixture, mode]}
  end

  defp start(context, script, opts \\ []) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          subscriber: self(),
          tools: [],
          mcp_servers: [server()]
        ]
        |> Keyword.merge(opts)
      )

    # Servers connect off the session process now, so a test that inspects
    # what they contributed waits for them first; `mcp_status/1` answers once
    # every pending connection has settled.
    Session.mcp_status(session, 30_000)

    {session, provider}
  end

  defp call(name, arguments \\ %{"text" => "hi"}),
    do: %{id: "m1", name: name, arguments: arguments}

  describe "a configured server's tools" do
    test "are offered to the model under a name carrying the server", context do
      {session, provider} = start(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, _}}

      assert [%Request{tools: tools}] = Scripted.requests(provider)
      names = Enum.map(tools, &Lemieux.Tool.name/1)

      assert "fixture__echo" in names
      refute "echo" in names
    end

    test "sit alongside the first-party ones rather than replacing them", context do
      {session, provider} = start(context, [[{:done, :stop}]], tools: Tools.default())

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, _}}

      assert [%Request{tools: tools}] = Scripted.requests(provider)
      names = Enum.map(tools, &Lemieux.Tool.name/1)

      assert "bash" in names
      assert "fixture__echo" in names
    end

    test "a host launcher owns stdio creation and completes a protocol round trip", context do
      parent = self()

      launcher = fn command, args, env, cwd ->
        send(parent, {:launch_stdio, command, args, env, cwd})

        executable = System.find_executable(command)

        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :hide,
            args: args,
            env: Enum.map(env, fn {key, value} -> {to_charlist(key), to_charlist(value)} end),
            cd: cwd
          ])

        close = fn ->
          if Port.info(port), do: Port.close(port)
          send(parent, :stdio_launcher_closed)
        end

        {:ok, %{port: port, close: close}}
      end

      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          cwd: context.tmp_dir,
          mcp_servers: [Map.put(server(), "env", %{"LEMIEUX_TEST_SCOPE" => "allowed"})],
          mcp_stdio_launcher: launcher
        )

      assert_receive {:launch_stdio, "python3", [@fixture, "modern"],
                      %{"LEMIEUX_TEST_SCOPE" => "allowed"}, cwd}

      assert cwd == context.tmp_dir

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: hi"

      :ok =
        DynamicSupervisor.terminate_child(
          Lemieux.Supervisor.session_supervisor(context.runtime),
          session
        )

      assert_receive :stdio_launcher_closed
    end

    test "can be disabled and enabled without disconnecting the server", context do
      {session, provider} = start(context, [[{:done, :stop}], [{:done, :stop}]])

      assert %{name: "fixture__echo", source: {:mcp, "fixture"}, enabled?: true} =
               Enum.find(Session.tool_status(session), &(&1.name == "fixture__echo"))

      assert {:ok, ["fixture__echo"]} = Session.disable_tools(session, ["fixture__echo"])
      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, _}}

      assert {:ok, ["fixture__echo"]} = Session.enable_tools(session, ["fixture__echo"])
      :ok = Session.prompt(session, "second")
      assert_receive {:lemieux, _, {:finished, _}}

      assert [first, second] = Scripted.requests(provider)
      refute "fixture__echo" in Enum.map(first.tools, &Lemieux.Tool.name/1)
      assert "fixture__echo" in Enum.map(second.tools, &Lemieux.Tool.name/1)
      assert [%{name: "fixture", tool_count: 4}] = Session.mcp_status(session)
    end
  end

  describe "calling one" do
    test "routes to the server and returns what it said", context do
      {session, provider} =
        start(context, [
          [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
          [{:text_delta, "done"}, {:done, :stop}]
        ])

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: hi"
      assert payload["structured_content"] == %{"echo" => "echo: hi"}
      assert payload["content"] == [%{"type" => "text", "text" => "echo: hi"}]
      assert payload["tool_identity"]["canonical_name"] == "mcp.fixture/fixture__echo"
      refute payload["error"]
    end

    test "is written to the transcript like any other tool call", context do
      {session, _provider} =
        start(context, [
          [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
          [{:done, :stop}]
        ])

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert {:ok, entries} = Store.read(context.store, Session.id(session))
      assert %Entry{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["name"] == "fixture__echo"
    end

    test "a failure on the server is a result the model reads", context do
      {session, provider} =
        start(context, [
          [{:tool_call, call("fixture__explode", %{})}, {:done, :tool_calls}],
          [{:done, :stop}]
        ])

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["error"]
    end
  end

  describe "policy applies to remote tools too" do
    # This is the test that says MCP is not a side door: a host's hooks see
    # these calls exactly as they see `bash`.
    test "a hook can deny one, and it is never sent to the server", context do
      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          hooks: [
            before_tool_call: fn call, _context ->
              {:deny, "no remote tools for you: #{call.name}"}
            end
          ]
        )

      :ok = Session.prompt(session, "use the tool")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] =~ "no remote tools for you"
      assert payload["error"]
    end

    test "a hook can park one for approval, and resolving it runs the call", context do
      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          hooks: [before_tool_call: fn _call, _context -> :pending end]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "use the tool")

      assert_receive {:lemieux, ^id, {:tool_approval, parked}}
      assert parked.name == "fixture__echo"

      :ok = Session.resolve_tool(session, "m1", :allow)
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "echo: hi"
    end
  end

  describe "a server that asks for something before it will answer" do
    # The multi round-trip pattern: the server replies that it needs input,
    # lemieux puts the question to whoever is attached, and retries the call
    # with the answer and the server's opaque state echoed back. The fixture
    # rejects a retry that does not echo the state, so this passing proves it.
    test "the question reaches the session, and the answer completes the call", context do
      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
            [{:text_delta, "done"}, {:done, :stop}]
          ],
          mcp_servers: [server("fixture", "mrtr")]
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "use the tool")

      assert_receive {:lemieux, ^id, {:question, question}}, 5_000
      assert question.question =~ "who is asking?"

      :ok = Session.answer(session, question.call_id, "octocat")
      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "hello octocat"
      refute payload["error"]
    end

    # Nobody answers, so the client declines rather than inventing content, and
    # the server is told plainly.
    test "nobody answering becomes a decline the server can act on", context do
      clock = start_supervised!(Manual)

      {session, provider} =
        start(
          context,
          [
            [{:tool_call, call("fixture__echo")}, {:done, :tool_calls}],
            [{:done, :stop}]
          ],
          mcp_servers: [server("fixture", "mrtr")],
          approval_timeout: 40,
          clock: clock
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "use the tool")

      # Nobody answers the server's question; its forty milliseconds pass when
      # the test moves the clock, however slow the machine is.
      Manual.await_timer(clock, &match?({:park_timeout, _call_id}, &1.message))
      Manual.advance(clock, 40, settle: session)

      assert_receive {:lemieux, ^id, {:finished, :stop}}, 5_000

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)
      assert %{payload: payload} = Enum.find(entries, &(&1.type == :tool_result))
      assert payload["output"] == "declined"
      assert payload["error"]
    end
  end

  describe "a server that will not start" do
    test "costs its own tools and nothing else", context do
      {session, provider} =
        start(context, [[{:text_delta, "fine"}, {:done, :stop}]],
          tools: Tools.default(),
          mcp_servers: [
            %{"name" => "gone", "transport" => "stdio", "command" => "definitely-not-real"}
          ]
        )

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [%Request{tools: tools}] = Scripted.requests(provider)
      names = Enum.map(tools, &Lemieux.Tool.name/1)

      assert "bash" in names
      refute Enum.any?(names, &String.starts_with?(&1, "gone__"))
    end
  end

  describe "the configuration" do
    test "is recorded, so the transcript says which servers were attached", context do
      {session, _provider} = start(context, [[{:done, :stop}]])

      assert [%Entry{type: :session, payload: payload}] = Session.snapshot(session).entries
      assert [%{"name" => "fixture"}] = payload["mcp_servers"]
    end

    test "a resumed session reconnects to them", context do
      {session, _provider} = start(context, [[{:done, :stop}]])
      id = Session.id(session)

      :ok =
        DynamicSupervisor.terminate_child(
          Lemieux.Supervisor.session_supervisor(context.runtime),
          session
        )

      LemieuxTest.Sync.unregistered(Lemieux.Supervisor.registry(context.runtime), id)

      provider = Scripted.new([[{:done, :stop}]])

      {:ok, resumed} =
        Lemieux.resume_session(
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          subscriber: self(),
          resume: id
        )

      :ok = Session.prompt(resumed, "again")
      assert_receive {:lemieux, ^id, {:finished, _}}

      assert [%Request{tools: tools}] = Scripted.requests(provider)
      assert "fixture__echo" in Enum.map(tools, &Lemieux.Tool.name/1)
    end
  end

  describe "live configuration" do
    test "status includes every configured server and its current tool count", context do
      {session, _provider} =
        start(context, [[{:done, :stop}]],
          mcp_servers: [
            server("fixture"),
            %{"name" => "gone", "command" => "definitely-not-real"}
          ]
        )

      assert Session.mcp_status(session) == [
               %{name: "fixture", transport: "stdio", tool_count: 4, enabled?: true, error: nil},
               %{
                 name: "gone",
                 transport: "stdio",
                 tool_count: 0,
                 enabled?: true,
                 error: "there is no definitely-not-real on this machine"
               }
             ]

      children =
        context.runtime
        |> Lemieux.Supervisor.session_supervisor()
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)

      assert session in children
      assert length(children) == 2
    end

    test "adds servers and replaces an existing server by name", context do
      {session, provider} = start(context, [[{:done, :stop}]], mcp_servers: [])

      assert :ok = Session.add_mcp_servers(session, [server("extra")])
      assert [%{name: "extra", tool_count: 4}] = Session.mcp_status(session)

      assert :ok =
               Session.add_mcp_servers(session, [
                 %{name: "extra", command: "definitely-not-real"}
               ])

      assert [%{name: "extra", transport: "stdio", tool_count: 0}] =
               Session.mcp_status(session)

      :ok = Session.prompt(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}
      assert [%Request{tools: []}] = Scripted.requests(provider)
    end

    test "removes a server and persists only the normalized configuration", context do
      System.put_env("LEMIEUX_DYNAMIC_MCP_SECRET", "do-not-record")
      on_exit(fn -> System.delete_env("LEMIEUX_DYNAMIC_MCP_SECRET") end)

      {session, _provider} = start(context, [[{:done, :stop}]], mcp_servers: [])

      dynamic =
        server("dynamic")
        |> Map.put(:env, %{token: "${LEMIEUX_DYNAMIC_MCP_SECRET}"})

      assert :ok = Session.add_mcp_servers(session, [dynamic])

      assert [_initial, %Entry{type: :session, payload: added}] =
               Session.snapshot(session).entries

      assert [%{"env" => %{"token" => "${LEMIEUX_DYNAMIC_MCP_SECRET}"}}] =
               added["mcp_servers"]

      refute inspect(added) =~ "do-not-record"
      refute inspect(added) =~ "tool_count"

      assert :ok = Session.remove_mcp_server(session, "dynamic")
      assert Session.mcp_status(session) == []

      assert %{active: 1} =
               DynamicSupervisor.count_children(
                 Lemieux.Supervisor.session_supervisor(context.runtime)
               )

      assert %Entry{type: :session, payload: removed} =
               Session.snapshot(session).entries |> List.last()

      assert removed["mcp_servers"] == []
      assert Session.remove_mcp_server(session, "dynamic") == {:error, :unknown_server}
    end

    test "reconnect replaces the selected server's client without recording a config change",
         context do
      {session, provider} = start(context, [[{:done, :stop}], [{:done, :stop}]])

      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, :stop}}
      assert [%Request{tools: [%RemoteTool{client: first} | _rest]}] = Scripted.requests(provider)

      :ok =
        DynamicSupervisor.terminate_child(
          Lemieux.Supervisor.session_supervisor(context.runtime),
          first
        )

      entry_count = length(Session.snapshot(session).entries)
      assert :ok = Session.reconnect_mcp(session, "fixture")
      assert length(Session.snapshot(session).entries) == entry_count

      :ok = Session.prompt(session, "second")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{tools: [%RemoteTool{client: second} | _rest]}] =
               Scripted.requests(provider)

      refute first == second
      assert Process.alive?(second)

      before_all = length(Session.snapshot(session).entries)
      assert :ok = Session.reconnect_mcp(session, :all)
      assert length(Session.snapshot(session).entries) == before_all
      assert [%{name: "fixture", tool_count: 4}] = Session.mcp_status(session)

      assert Session.reconnect_mcp(session, "missing") == {:error, :unknown_server}
    end

    test "a configured server can be turned off and on without changing recorded config",
         context do
      {session, _provider} = start(context, [[{:done, :stop}]], mcp_servers: [server("fixture")])
      # Servers connect in the background; this test reads the connection itself.
      assert_receive {:lemieux, _, {:ready, _}}
      before = length(Session.snapshot(session).entries)
      {_tools, [first]} = :sys.get_state(session).mcp_connections["fixture"]

      assert :ok = Session.set_mcp_enabled(session, "fixture", false)
      assert [%{name: "fixture", enabled?: false, tool_count: 0}] = Session.mcp_status(session)
      refute Process.alive?(first)
      assert Session.reconnect_mcp(session, "fixture") == {:error, :server_disabled}

      refute Enum.any?(
               Session.tool_status(session),
               &(&1.source == {:mcp, "fixture"} and &1.enabled?)
             )

      assert length(Session.snapshot(session).entries) == before

      assert :ok = Session.set_mcp_enabled(session, "fixture", true)
      assert [%{name: "fixture", enabled?: true, tool_count: 4}] = Session.mcp_status(session)
      {_tools, [second]} = :sys.get_state(session).mcp_connections["fixture"]
      refute first == second

      assert Enum.any?(
               Session.tool_status(session),
               &(&1.source == {:mcp, "fixture"} and &1.enabled?)
             )

      assert length(Session.snapshot(session).entries) == before
      assert Session.set_mcp_enabled(session, "missing", false) == {:error, :unknown_server}
    end

    test "mcp_clients lists each connected server with the capabilities it declared",
         context do
      {session, _provider} =
        start(context, [[{:done, :stop}]], mcp_servers: [server("duplex", "duplex")])

      assert [%{name: "duplex", client: client, capabilities: capabilities}] =
               Session.mcp_clients(session)

      assert is_pid(client)
      assert Map.has_key?(capabilities, "prompts")
      assert Map.has_key?(capabilities, "resources")

      # Disabled servers offer nothing, so they are not listed.
      assert :ok = Session.set_mcp_enabled(session, "duplex", false)
      assert Session.mcp_clients(session) == []
    end

    test "resources are listed by server and read by name, without handling pids", context do
      {session, _provider} =
        start(context, [[{:done, :stop}]], mcp_servers: [server("duplex", "duplex")])

      assert [
               %{server: "duplex", uri: "fixture://notes", name: "notes"},
               %{server: "duplex", uri: "fixture://logo"}
             ] = Session.mcp_resources(session)

      assert {:ok, "remember the milk"} =
               Session.mcp_resource(session, "duplex", "fixture://notes")

      assert {:error, :unknown_server} =
               Session.mcp_resource(session, "missing", "fixture://notes")
    end

    # A server may offer prompts and nothing else. It used to be refused as
    # "offered no tools", so a host looking for prompts never found it.
    test "a server offering only prompts is connected and listed", context do
      {session, _provider} =
        start(context, [[{:done, :stop}]],
          mcp_servers: [%{"name" => "prompts", "transport" => "prompts_only"}],
          mcp_transports: %{"prompts_only" => __MODULE__.PromptsOnly}
        )

      assert [%{name: "prompts", status: :connected, tool_count: 0}] =
               Session.info(session).mcp

      assert [%{name: "prompts", capabilities: %{"prompts" => _}}] =
               Session.mcp_clients(session)

      assert Session.tool_status(session) |> Enum.filter(&match?({:mcp, _}, &1.source)) == []
    end

    # Startup must not wait on a browser, so a host passes
    # `interactive_auth: false`; a reconnect is a person asking, and is the
    # only way a server that needs a sign-in can get one.
    test "startup connects non-interactively, and an explicit reconnect may sign in",
         context do
      probe = :"mcp_probe_#{System.unique_integer([:positive])}"
      Process.register(self(), probe)

      {session, _provider} =
        start(context, [[{:done, :stop}]],
          mcp_servers: [%{"name" => "probe", "transport" => "probe", "probe" => "#{probe}"}],
          mcp_transports: %{"probe" => __MODULE__.Probe},
          mcp_connect_opts: [interactive_auth: false]
        )

      assert_receive {:configured, false}

      assert :ok = Session.reconnect_mcp(session, "probe")
      assert_receive {:configured, true}
    end

    test "a server with zero tools reports why reconnect did not provide tools", context do
      {session, _provider} =
        start(context, [[{:done, :stop}]], mcp_servers: [server("empty", "empty")])

      assert [%{name: "empty", tool_count: 0, error: "the server offered no tools"}] =
               Session.mcp_status(session)

      assert :ok = Session.reconnect_mcp(session, "empty")

      assert [%{name: "empty", tool_count: 0, error: "the server offered no tools"}] =
               Session.mcp_status(session)
    end

    test "all mutations are refused while a turn is running", context do
      test = self()

      {session, _provider} =
        start(context, [
          fn _request ->
            send(test, {:answering, self()})

            receive do
              :release -> [{:done, :stop}]
            end
          end
        ])

      :ok = Session.prompt(session, "wait")
      assert_receive {:answering, provider_task}

      assert Session.add_mcp_servers(session, [server("extra")]) == {:error, :busy}
      assert Session.remove_mcp_server(session, "fixture") == {:error, :busy}
      assert Session.reconnect_mcp(session, "fixture") == {:error, :busy}
      assert Session.reconnect_mcp(session, :all) == {:error, :busy}

      send(provider_task, :release)
      assert_receive {:lemieux, _, {:finished, :stop}}
    end
  end
end
