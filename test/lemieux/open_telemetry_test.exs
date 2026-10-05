defmodule Lemieux.OpenTelemetryTest do
  use ExUnit.Case, async: false

  alias Lemieux.OpenTelemetry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Subagent
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Task, as: SubagentTask
  alias Lemieux.Telemetry
  alias Lemieux.Testing

  @moduletag :tmp_dir

  defmodule FakeAdapter do
    @behaviour Lemieux.OpenTelemetry.Adapter

    @impl true
    def available?, do: true

    @impl true
    def current_context(config) do
      Process.get({__MODULE__, Keyword.fetch!(config, :handler_id)})
    end

    @impl true
    def start_span(name, kind, attributes, parent, config) do
      span = {:span, make_ref()}
      send(Keyword.fetch!(config, :owner), {:otel, :start, span, name, kind, attributes, parent})
      span
    end

    @impl true
    def activate_context(context, config) do
      token = {:token, make_ref()}
      send(Keyword.fetch!(config, :owner), {:otel, :activate, context, token, self()})
      token
    end

    @impl true
    def detach_context(token, config) do
      send(Keyword.fetch!(config, :owner), {:otel, :detach, token, self()})
      :ok
    end

    @impl true
    def set_attributes(span, attributes, config) do
      send(Keyword.fetch!(config, :owner), {:otel, :attributes, span, attributes})
      :ok
    end

    @impl true
    def add_event(span, name, attributes, config) do
      send(Keyword.fetch!(config, :owner), {:otel, :event, span, name, attributes})
      :ok
    end

    @impl true
    def set_status(span, status, config) do
      send(Keyword.fetch!(config, :owner), {:otel, :status, span, status})
      :ok
    end

    @impl true
    def end_span(span, config) do
      send(Keyword.fetch!(config, :owner), {:otel, :end, span})
      :ok
    end
  end

  defmodule UnavailableAdapter do
    @behaviour Lemieux.OpenTelemetry.Adapter

    @impl true
    def available?, do: false

    @impl true
    def current_context(_config), do: nil

    @impl true
    def start_span(_name, _kind, _attributes, _parent, _config), do: :unreachable

    @impl true
    def activate_context(_context, _config), do: :unreachable

    @impl true
    def detach_context(_token, _config), do: :ok

    @impl true
    def set_attributes(_span, _attributes, _config), do: :ok

    @impl true
    def add_event(_span, _name, _attributes, _config), do: :ok

    @impl true
    def set_status(_span, _status, _config), do: :ok

    @impl true
    def end_span(_span, _config), do: :ok
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})

    handler = {__MODULE__, System.unique_integer([:positive])}
    on_exit(fn -> OpenTelemetry.detach(handler) end)

    %{handler: handler, runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  test "standalone spans preserve the harness topology without content", context do
    :ok = attach(context)
    session_id = "session-standalone"
    request_id = "request-1"
    call_id = "call-1"
    bind_parent(context.handler, session_id, :host_workflow)

    prompt_started =
      Telemetry.start([:session, :prompt], %{
        session_id: session_id,
        root_session_id: session_id,
        provider: "anthropic",
        model: "anthropic:claude-sonnet-5",
        prompt: "do not export me"
      })

    assert_receive {:otel, :start, agent, "invoke_agent lemieux", :internal, agent_attrs,
                    :host_workflow}

    assert agent_attrs["ixway.span.kind"] == "agent"
    assert agent_attrs["gen_ai.operation.name"] == "invoke_agent"
    assert agent_attrs["gen_ai.conversation.id"] == session_id
    refute inspect(agent_attrs) =~ "do not export me"

    turn_started =
      Telemetry.start([:turn], %{
        session_id: session_id,
        root_session_id: session_id,
        request_id: request_id,
        provider: "anthropic",
        model: "anthropic:claude-sonnet-5"
      })

    assert_receive {:otel, :start, turn, "lemieux turn", :internal, turn_attrs, ^agent}
    assert turn_attrs["lemieux.request.id"] == request_id
    assert turn_attrs["ixway.span.kind"] == "custom"

    _tool_started =
      Telemetry.start([:tool, :call], %{
        session_id: session_id,
        root_session_id: session_id,
        tool_name: "read",
        call_id: call_id,
        arguments: %{"path" => "/secret/file"}
      })

    assert_receive {:otel, :start, tool, "execute_tool read", :internal, tool_attrs, ^agent}
    assert tool_attrs["ixway.span.kind"] == "tool"
    assert tool_attrs["gen_ai.tool.call.id"] == call_id
    refute inspect(tool_attrs) =~ "/secret/file"

    Telemetry.event(
      [:provider, :first_delta],
      %{duration: System.convert_time_unit(25, :millisecond, :native)},
      %{session_id: session_id, request_id: request_id}
    )

    assert_receive {:otel, :event, ^turn, "lemieux.provider.first_delta", first_delta}
    assert first_delta["lemieux.duration_ms"] == 25

    Telemetry.stop_ms(
      [:tool, :call],
      3,
      %{session_id: session_id, tool_name: "read", call_id: call_id, outcome: :ok}
    )

    assert_receive {:otel, :status, ^tool, :ok}
    assert_receive {:otel, :end, ^tool}

    Telemetry.stop([:turn], turn_started, %{
      session_id: session_id,
      request_id: request_id,
      outcome: :ok,
      stop_reason: :stop
    })

    assert_receive {:otel, :status, ^turn, :ok}
    assert_receive {:otel, :end, ^turn}

    Telemetry.stop([:session, :prompt], prompt_started, %{
      session_id: session_id,
      root_session_id: session_id,
      outcome: :ok,
      stop_reason: :stop
    })

    assert_receive {:otel, :status, ^agent, :ok}
    assert_receive {:otel, :end, ^agent}
  end

  test "embedded mode borrows the host agent span and only adds subagent spans", context do
    :ok = attach(context, agent_spans: :subagents, require_parent: true)
    root_id = "root-session"
    child_id = "child-session"
    bind_parent(context.handler, root_id, :host_agent)

    root_started =
      Telemetry.start([:session, :prompt], %{
        session_id: root_id,
        root_session_id: root_id,
        model: "test:model"
      })

    refute_receive {:otel, :start, _span, "invoke_agent lemieux", _kind, _attrs, _parent}

    bind_parent(context.handler, child_id, :delegate_tool)

    child_started =
      Telemetry.start([:session, :prompt], %{
        session_id: child_id,
        root_session_id: root_id,
        model: "test:model"
      })

    assert_receive {:otel, :start, child, "invoke_agent lemieux", :internal, child_attrs,
                    :delegate_tool}

    assert child_attrs["lemieux.agent.role"] == "subagent"

    root_tool_started =
      Telemetry.start([:tool, :call], %{
        session_id: root_id,
        root_session_id: root_id,
        tool_name: "read",
        call_id: "root-call"
      })

    assert_receive {:otel, :start, root_tool, "execute_tool read", :internal, _attrs, :host_agent}

    child_tool_started =
      Telemetry.start([:tool, :call], %{
        session_id: child_id,
        root_session_id: root_id,
        tool_name: "bash",
        call_id: "child-call"
      })

    assert_receive {:otel, :start, child_tool, "execute_tool bash", :internal, _attrs, ^child}

    stop_tool(root_id, "root-call", root_tool_started)
    stop_tool(child_id, "child-call", child_tool_started)

    Telemetry.stop([:session, :prompt], child_started, %{
      session_id: child_id,
      root_session_id: root_id,
      outcome: :ok
    })

    assert_receive {:otel, :end, ^child}

    Telemetry.stop([:session, :prompt], root_started, %{
      session_id: root_id,
      root_session_id: root_id,
      outcome: :ok
    })

    refute_receive {:otel, :end, :host_agent}
    assert_receive {:otel, :end, ^root_tool}
    assert_receive {:otel, :end, ^child_tool}
  end

  test "a session prompt captures and inherits the host process context", context do
    :ok = attach(context, agent_spans: :subagents, require_parent: true)
    Process.put({FakeAdapter, context.handler}, :host_agent)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: Scripted.new([Scripted.complete("done")]),
        store: context.store,
        model: "test:model",
        tools: []
      )

    assert {:ok, %{stop_reason: :stop}} = Testing.prompt(session, "secret prompt")

    refute_receive {:otel, :start, _span, "invoke_agent lemieux", _kind, _attrs, _parent}

    assert_receive {:otel, :start, turn, "lemieux turn", :internal, attributes, :host_agent}

    assert attributes["lemieux.model"] == "test:model"
    refute inspect(attributes) =~ "secret prompt"

    assert_receive {:otel, :activate, ^turn, token, provider_pid}
    assert provider_pid != self()
    assert_receive {:otel, :detach, ^token, ^provider_pid}
  end

  test "delegation carries the active tool context through its coordinator process", context do
    :ok = attach(context, agent_spans: :subagents, require_parent: true)
    Process.put({FakeAdapter, context.handler}, :delegate_tool)

    {:ok, parent} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: Scripted.new([]),
        store: context.store,
        model: "test:parent",
        tools: []
      )

    definition =
      Definition.new(
        id: "scout",
        description: "Reads one subsystem",
        system_prompt: "Return evidence",
        model: "test:child",
        tools: [],
        max_cost_usd: 0.1
      )

    task = SubagentTask.new(objective: "Inspect telemetry propagation", snapshot: %{"v" => 1})
    child_provider = Scripted.new([Scripted.complete("no structured result")])

    assert {:ok, child_ref} =
             Subagent.spawn(parent, definition, task,
               max_cost_usd: 0.5,
               providers: %{"scout" => child_provider}
             )

    assert_receive {:otel, :start, child, "invoke_agent lemieux", :internal, attributes,
                    :delegate_tool}

    assert attributes["lemieux.agent.role"] == "subagent"
    assert attributes["lemieux.session.id"] == child_ref.id
    assert {:ok, _result} = Subagent.await(child_ref, 5_000)
    assert_receive {:otel, :end, ^child}
  end

  test "require_parent drops standalone traces instead of creating accidental roots", context do
    :ok = attach(context, require_parent: true)

    started =
      Telemetry.start([:session, :prompt], %{
        session_id: "unparented",
        root_session_id: "unparented",
        model: "test:model"
      })

    turn_started =
      Telemetry.start([:turn], %{
        session_id: "unparented",
        root_session_id: "unparented",
        request_id: "request",
        model: "test:model"
      })

    Telemetry.stop([:turn], turn_started, %{
      session_id: "unparented",
      request_id: "request",
      outcome: :ok
    })

    Telemetry.stop([:session, :prompt], started, %{
      session_id: "unparented",
      root_session_id: "unparented",
      outcome: :ok
    })

    refute_receive {:otel, _operation, _rest1, _rest2, _rest3, _rest4, _rest5}
    refute_receive {:otel, _operation, _rest1, _rest2, _rest3, _rest4}
    refute_receive {:otel, _operation, _rest1, _rest2, _rest3}
    refute_receive {:otel, _operation, _rest1, _rest2}
    refute_receive {:otel, _operation, _rest1}
  end

  test "provider trace propagation merges W3C headers without overriding host policy" do
    options = [
      propagate_trace_context: true,
      req_http_options: [
        receive_timeout: 1_000,
        headers: [{"TraceParent", "host-parent"}, {"x-ixway-key", "secret"}]
      ]
    ]

    injector = fn headers ->
      [{"traceparent", "generated-parent"}, {"tracestate", "ixway=value"} | headers]
    end

    propagated = OpenTelemetry.inject_req_options(options, injector)
    http_options = Keyword.fetch!(propagated, :req_http_options)

    assert http_options[:receive_timeout] == 1_000
    assert {"TraceParent", "host-parent"} in http_options[:headers]
    refute {"traceparent", "generated-parent"} in http_options[:headers]
    assert {"tracestate", "ixway=value"} in http_options[:headers]
    assert {"x-ixway-key", "secret"} in http_options[:headers]
    refute Keyword.has_key?(propagated, :propagate_trace_context)
  end

  test "trace propagation is inert by default and the private option never reaches ReqLLM" do
    options = [propagate_trace_context: false, max_tokens: 100]

    assert OpenTelemetry.inject_req_options(options, fn _headers ->
             flunk("the injector must not run")
           end) == [max_tokens: 100]
  end

  test "attachment fails locally when the host has no OpenTelemetry API", context do
    assert OpenTelemetry.attach(context.handler, adapter: UnavailableAdapter) ==
             {:error, :opentelemetry_unavailable}
  end

  defp attach(context, options \\ []) do
    OpenTelemetry.attach(
      context.handler,
      Keyword.merge([adapter: FakeAdapter, owner: self()], options)
    )
  end

  defp bind_parent(handler, session_id, parent) do
    Process.put({FakeAdapter, handler}, parent)
    OpenTelemetry.bind_prompt_parent(session_id, OpenTelemetry.capture_contexts())
  end

  defp stop_tool(session_id, call_id, started_at) do
    Telemetry.stop([:tool, :call], started_at, %{
      session_id: session_id,
      call_id: call_id,
      outcome: :ok
    })
  end
end
