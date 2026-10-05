defmodule Lemieux.OpenTelemetry do
  @moduledoc """
  Opt-in OpenTelemetry bridge for Lemieux-owned agent work.

  `Lemieux.Telemetry` remains the stable, dependency-free source contract.
  This module maps that contract to metadata-only spans for the topology only
  the harness knows: agent prompts, turns, tools, compaction and provider
  admission waits. ReqLLM owns model-call spans, token usage and provider
  response details; attaching its existing bridge is an explicit option so an
  embedding host cannot accidentally emit both its own and Lemieux's copy.

  The bridge configures no SDK, sampler, processor, exporter, endpoint or
  credential and starts no process. A standalone host may install the Erlang
  OpenTelemetry packages and attach with `req_llm: true`. An embedding host
  that already records its own agent spans attaches with `agent_spans:
  :subagents`, `require_parent: true` and `req_llm: false`; root Lemieux work
  then borrows the host's active agent span while delegated Lemieux sessions
  remain visible beneath it.

  OpenTelemetry context does not cross BEAM process boundaries implicitly.
  `Lemieux.Session` captures the caller context at a prompt and uses
  `with_context/4` around provider and tool tasks so ReqLLM, MCP and other
  downstream instrumentation inherit the right parent.
  """

  require Logger

  @config_table :lemieux_open_telemetry_configs
  @span_table :lemieux_open_telemetry_spans
  @default_handler_id "lemieux-open-telemetry"
  @default_adapter :"Elixir.Lemieux.OpenTelemetry.OTelAdapter"

  @events [
    [:lemieux, :session, :prompt, :start],
    [:lemieux, :session, :prompt, :stop],
    [:lemieux, :session, :cancel],
    [:lemieux, :turn, :start],
    [:lemieux, :turn, :stop],
    [:lemieux, :provider, :request, :stop],
    [:lemieux, :provider, :request, :exception],
    [:lemieux, :provider, :first_delta],
    [:lemieux, :provider_limiter, :wait, :start],
    [:lemieux, :provider_limiter, :wait, :stop],
    [:lemieux, :provider_limiter, :wait, :exception],
    [:lemieux, :tool, :call, :start],
    [:lemieux, :tool, :call, :stop],
    [:lemieux, :compaction, :start],
    [:lemieux, :compaction, :stop]
  ]

  @type agent_spans :: :all | :subagents | :none

  @doc "Returns the Lemieux events translated by this bridge."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Returns whether the selected adapter can use the host's OTel API."
  @spec available?(opts :: keyword()) :: boolean()
  def available?(opts \\ []), do: adapter(opts).available?()

  @doc """
  Attaches the bridge to Lemieux telemetry.

  Options:

    * `:adapter` — tracer adapter, defaulting to `#{inspect(@default_adapter)}`.
    * `:agent_spans` — `:all` (default), `:subagents`, or `:none`.
      `:subagents` borrows the captured host span for a root session and emits
      agent spans only for delegated sessions.
    * `:require_parent` — when true, ignore work with no captured host parent.
      This prevents a host's ordinary sessions from becoming OTLP root traces.
    * `:req_llm` — when true, also attaches `ReqLLM.OpenTelemetry` with
      content capture forced to `:none`. Default false.
    * `:req_llm_options` — additional options for ReqLLM's bridge, such as a
      host adapter. `:content` is always overwritten with `:none`.

  Other options are retained for a custom adapter.
  """
  @spec attach(handler_id :: term(), opts :: keyword()) ::
          :ok | {:error, :already_exists | :opentelemetry_unavailable}
  def attach(handler_id \\ @default_handler_id, opts \\ []) do
    config = config(handler_id, opts)

    if adapter(config).available?() do
      ensure_tables()

      case :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_event/4, config) do
        :ok -> finish_attach(config)
        {:error, :already_exists} = error -> error
      end
    else
      {:error, :opentelemetry_unavailable}
    end
  end

  @doc "Detaches the bridge and clears its in-flight state."
  @spec detach(handler_id :: term()) :: :ok
  def detach(handler_id \\ @default_handler_id) do
    config = fetch_config(handler_id)

    if config && Keyword.get(config, :req_llm),
      do: ReqLLM.OpenTelemetry.detach(req_llm_id(handler_id))

    close_handler_spans(handler_id, config)
    delete_config(handler_id)
    :telemetry.detach(handler_id)
  end

  @doc """
  Removes bridge records older than `ttl_ms` and returns their count.

  Hosts can call this from their own scheduler. Lemieux starts no cleanup
  process because library embedders own lifecycle and supervision.
  """
  @spec prune_stale_spans(handler_id :: term(), ttl_ms :: non_neg_integer()) :: non_neg_integer()
  def prune_stale_spans(handler_id \\ @default_handler_id, ttl_ms)
      when is_integer(ttl_ms) and ttl_ms >= 0 do
    if table_exists?(@span_table) do
      prune_handler_records(handler_id, ttl_ms)
    else
      0
    end
  end

  @doc false
  @spec capture_contexts() :: [{term(), term()}]
  def capture_contexts do
    for {handler_id, config} <- configs(),
        context = safe_current_context(config),
        not is_nil(context),
        do: {handler_id, context}
  end

  @doc false
  @spec bind_prompt_parent(session_id :: String.t(), contexts :: [{term(), term()}]) :: :ok
  def bind_prompt_parent(_session_id, []), do: :ok

  def bind_prompt_parent(session_id, contexts) when is_binary(session_id) and is_list(contexts) do
    ensure_tables()

    Enum.each(contexts, fn {handler_id, context} ->
      put_record(handler_id, :parent, session_id, borrowed(context))
    end)

    :ok
  end

  @doc false
  @spec drop_prompt_parent(session_id :: String.t()) :: :ok
  def drop_prompt_parent(session_id) when is_binary(session_id) do
    if table_exists?(@span_table) do
      Enum.each(configs(), fn {handler_id, _config} ->
        :ets.delete(@span_table, record_key(handler_id, :parent, session_id))
      end)
    end

    :ok
  end

  @doc false
  @spec drop_session(session_id :: String.t()) :: :ok
  def drop_session(session_id) when is_binary(session_id) do
    if table_exists?(@span_table) do
      Enum.each(configs(), &drop_session_records(&1, session_id))
    end

    :ok
  end

  @doc false
  @spec with_context(session_id :: String.t(), scope :: atom(), id :: term(), fun :: (-> result)) ::
          result
        when result: term()
  def with_context(session_id, scope, id, fun)
      when is_binary(session_id) and is_atom(scope) and is_function(fun, 0) do
    activated =
      Enum.flat_map(configs(), &activate_record_context(&1, session_id, scope, id))

    try do
      fun.()
    after
      activated
      |> Enum.reverse()
      |> Enum.each(fn {config, token} -> safe_detach_context(token, config) end)
    end
  end

  @doc false
  @spec inject_req_options(options :: keyword()) :: keyword()
  def inject_req_options(options), do: inject_req_options(options, &default_inject_headers/1)

  @doc false
  @spec inject_req_options(
          options :: keyword(),
          injector :: ([{String.t(), String.t()}] -> Enumerable.t())
        ) :: keyword()
  def inject_req_options(options, injector)
      when is_list(options) and is_function(injector, 1) do
    {propagate?, options} = Keyword.pop(options, :propagate_trace_context, false)

    case propagate? do
      true ->
        put_propagated_headers(options, injector)

      false ->
        options

      invalid ->
        raise ArgumentError,
              ":propagate_trace_context must be a boolean, got: #{inspect(invalid)}"
    end
  end

  @doc false
  @spec handle_event(
          event :: [atom()],
          measurements :: map(),
          metadata :: map(),
          config :: keyword()
        ) :: :ok
  def handle_event(event, measurements, metadata, config) do
    do_handle_event(event, measurements, metadata, config)
  rescue
    error ->
      Logger.warning(fn ->
        "Lemieux.OpenTelemetry: handler crashed on #{inspect(event)} -- " <>
          Exception.format(:error, error, __STACKTRACE__)
      end)

      :ok
  end

  defp do_handle_event([:lemieux, :session, :prompt, :start], _measurements, metadata, config) do
    session_id = metadata[:session_id]
    put_record(config, :prompt, session_id, prompt_record(config, metadata))
  end

  defp do_handle_event([:lemieux, :session, :prompt, :stop], measurements, metadata, config) do
    finish_record(config, :prompt, metadata[:session_id], measurements, metadata)
  end

  defp do_handle_event([:lemieux, :session, :cancel], _measurements, metadata, config) do
    add_to_record(config, :prompt, metadata[:session_id], "lemieux.session.cancel", %{
      "lemieux.stop_reason" => string(metadata[:stop_reason])
    })
  end

  defp do_handle_event([:lemieux, :turn, :start], _measurements, metadata, config) do
    start_child_record(
      config,
      :turn,
      {metadata[:session_id], metadata[:request_id]},
      "lemieux turn",
      turn_attributes(metadata),
      prompt_reference(config, metadata[:session_id]),
      metadata[:session_id]
    )
  end

  defp do_handle_event([:lemieux, :turn, :stop], measurements, metadata, config) do
    finish_record(
      config,
      :turn,
      {metadata[:session_id], metadata[:request_id]},
      measurements,
      metadata
    )
  end

  defp do_handle_event(
         [:lemieux, :provider_limiter, :wait, :start],
         _measurements,
         metadata,
         config
       ) do
    parent = operation_reference(config, metadata)

    start_child_record(
      config,
      :provider_wait,
      {metadata[:session_id], metadata[:request_id]},
      "lemieux provider wait",
      provider_wait_attributes(metadata),
      parent,
      metadata[:session_id]
    )
  end

  defp do_handle_event(
         [:lemieux, :provider_limiter, :wait, terminal],
         measurements,
         metadata,
         config
       )
       when terminal in [:stop, :exception] do
    finish_record(
      config,
      :provider_wait,
      {metadata[:session_id], metadata[:request_id]},
      measurements,
      metadata
    )
  end

  defp do_handle_event([:lemieux, :tool, :call, :start], _measurements, metadata, config) do
    tool = bounded(metadata[:tool_name]) || "unknown"

    start_child_record(
      config,
      :tool,
      {metadata[:session_id], metadata[:call_id]},
      "execute_tool #{tool}",
      tool_attributes(metadata, tool),
      prompt_reference(config, metadata[:session_id]),
      metadata[:session_id]
    )
  end

  defp do_handle_event([:lemieux, :tool, :call, :stop], measurements, metadata, config) do
    finish_record(
      config,
      :tool,
      {metadata[:session_id], metadata[:call_id]},
      measurements,
      metadata
    )
  end

  defp do_handle_event([:lemieux, :compaction, :start], _measurements, metadata, config) do
    start_child_record(
      config,
      :compaction,
      {metadata[:session_id], metadata[:request_id]},
      "lemieux compaction",
      compaction_attributes(metadata),
      prompt_reference(config, metadata[:session_id]),
      metadata[:session_id]
    )
  end

  defp do_handle_event([:lemieux, :compaction, :stop], measurements, metadata, config) do
    finish_record(
      config,
      :compaction,
      {metadata[:session_id], metadata[:request_id]},
      measurements,
      metadata
    )
  end

  defp do_handle_event([:lemieux, :provider, :first_delta], measurements, metadata, config) do
    add_to_operation(config, metadata, "lemieux.provider.first_delta", %{
      "lemieux.duration_ms" => duration_ms(measurements),
      "lemieux.entry.id" => metadata[:entry_id]
    })
  end

  defp do_handle_event(
         [:lemieux, :provider, :request, terminal],
         measurements,
         metadata,
         config
       )
       when terminal in [:stop, :exception] do
    add_to_operation(
      config,
      metadata,
      "lemieux.provider.request",
      terminal_attributes(measurements, metadata)
    )
  end

  defp prompt_record(config, metadata) do
    session_id = metadata[:session_id]
    root_id = metadata[:root_session_id] || session_id
    root? = session_id == root_id

    parent =
      if root?,
        do: take_parent(config, session_id),
        else: take_parent(config, session_id) || prompt_reference(config, root_id)

    build_prompt_record(config, metadata, root?, parent)
  end

  defp finish_attach(config) do
    case attach_req_llm(config) do
      :ok ->
        :ets.insert(@config_table, {Keyword.fetch!(config, :handler_id), config})
        :ok

      {:error, _reason} = error ->
        :telemetry.detach(Keyword.fetch!(config, :handler_id))
        error
    end
  end

  defp attach_req_llm(config) do
    if Keyword.get(config, :req_llm) do
      options = config |> Keyword.get(:req_llm_options, []) |> Keyword.put(:content, :none)
      ReqLLM.OpenTelemetry.attach(req_llm_id(Keyword.fetch!(config, :handler_id)), options)
    else
      :ok
    end
  end

  defp req_llm_id(handler_id), do: {handler_id, :req_llm}

  defp config(handler_id, opts) do
    agent_spans = Keyword.get(opts, :agent_spans, :all)
    require_parent = Keyword.get(opts, :require_parent, false)
    req_llm = Keyword.get(opts, :req_llm, false)

    if agent_spans not in [:all, :subagents, :none],
      do: raise(ArgumentError, ":agent_spans must be :all, :subagents, or :none")

    if not is_boolean(require_parent),
      do: raise(ArgumentError, ":require_parent must be a boolean")

    if not is_boolean(req_llm), do: raise(ArgumentError, ":req_llm must be a boolean")

    opts
    |> Keyword.put(:handler_id, handler_id)
    |> Keyword.put(:adapter, adapter(opts))
    |> Keyword.put(:agent_spans, agent_spans)
    |> Keyword.put(:require_parent, require_parent)
    |> Keyword.put(:req_llm, req_llm)
  end

  defp adapter(opts), do: Keyword.get(opts, :adapter, @default_adapter)

  defp default_inject_headers(headers) do
    adapter = @default_adapter
    adapter.inject_headers(headers)
  end

  defp agent_span?(config, true), do: Keyword.fetch!(config, :agent_spans) == :all
  defp agent_span?(config, false), do: Keyword.fetch!(config, :agent_spans) in [:all, :subagents]

  defp parent_required_but_missing?(config, parent),
    do: Keyword.fetch!(config, :require_parent) and is_nil(parent)

  defp build_prompt_record(config, metadata, root?, parent) do
    case {parent, Keyword.fetch!(config, :require_parent), agent_span?(config, root?)} do
      {nil, true, _agent_span?} ->
        ignored()

      {parent, _require_parent?, true} ->
        reference =
          adapter(config).start_span(
            "invoke_agent lemieux",
            :internal,
            agent_attributes(metadata, if(root?, do: :root, else: :subagent)),
            parent,
            config
          )

        owned(reference, metadata[:session_id])

      {parent, _require_parent?, false} ->
        borrow_or_ignore(parent, metadata[:session_id])
    end
  end

  defp borrow_or_ignore(nil, _session_id), do: ignored()
  defp borrow_or_ignore(parent, session_id), do: borrowed(parent, session_id)

  defp start_child_record(config, scope, key, name, attributes, parent, session_id) do
    record =
      if parent_required_but_missing?(config, parent) do
        ignored()
      else
        reference = adapter(config).start_span(name, :internal, attributes, parent, config)
        owned(reference, session_id)
      end

    put_record(config, scope, key, record)
  end

  defp finish_record(config, scope, key, measurements, metadata) do
    case take_record(config, scope, key) do
      %{owned?: true, reference: reference} ->
        adapter(config).set_attributes(
          reference,
          terminal_attributes(measurements, metadata),
          config
        )

        adapter(config).set_status(reference, status(metadata), config)
        adapter(config).end_span(reference, config)

      _borrowed_ignored_or_missing ->
        :ok
    end
  end

  defp add_to_operation(config, metadata, name, attributes) do
    add_to_record(
      config,
      operation_scope(metadata[:kind]),
      {metadata[:session_id], metadata[:request_id]},
      name,
      attributes
    )
  end

  defp add_to_record(config, scope, key, name, attributes) do
    case lookup_record(config, scope, key) do
      %{ignored?: false, reference: reference} ->
        adapter(config).add_event(reference, name, compact(attributes), config)

      _missing_or_ignored ->
        :ok
    end
  end

  defp operation_reference(config, metadata) do
    config
    |> lookup_record(operation_scope(metadata[:kind]), {
      metadata[:session_id],
      metadata[:request_id]
    })
    |> record_reference()
  end

  defp operation_scope(:compaction), do: :compaction
  defp operation_scope(_turn), do: :turn

  defp prompt_reference(config, session_id) do
    config |> lookup_record(:prompt, session_id) |> record_reference()
  end

  defp record_reference(%{ignored?: false, reference: reference}), do: reference
  defp record_reference(_missing_or_ignored), do: nil

  defp take_parent(config, session_id) do
    config |> take_record(:parent, session_id) |> record_reference()
  end

  defp agent_attributes(metadata, role) do
    metadata
    |> common_attributes()
    |> Map.merge(%{
      "gen_ai.operation.name" => "invoke_agent",
      "gen_ai.agent.name" => "lemieux",
      "ixway.span.kind" => "agent",
      "ixway.definition.name" => "lemieux",
      "ixway.definition.version" => Lemieux.version(),
      "lemieux.agent.role" => Atom.to_string(role)
    })
    |> compact()
  end

  defp turn_attributes(metadata) do
    metadata
    |> common_attributes()
    |> Map.merge(%{
      "ixway.span.kind" => "custom",
      "lemieux.operation.name" => "turn",
      "lemieux.request.id" => metadata[:request_id]
    })
    |> compact()
  end

  defp tool_attributes(metadata, tool) do
    metadata
    |> common_attributes()
    |> Map.merge(%{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => tool,
      "gen_ai.tool.call.id" => metadata[:call_id],
      "ixway.span.kind" => "tool",
      "ixway.definition.name" => tool,
      "lemieux.operation.name" => "tool"
    })
    |> compact()
  end

  defp compaction_attributes(metadata) do
    metadata
    |> common_attributes()
    |> Map.merge(%{
      "ixway.span.kind" => "custom",
      "lemieux.operation.name" => "compaction",
      "lemieux.request.id" => metadata[:request_id],
      "lemieux.compaction.kind" => string(metadata[:kind])
    })
    |> compact()
  end

  defp provider_wait_attributes(metadata) do
    metadata
    |> common_attributes()
    |> Map.merge(%{
      "ixway.span.kind" => "custom",
      "lemieux.operation.name" => "provider_wait",
      "lemieux.request.id" => metadata[:request_id]
    })
    |> compact()
  end

  defp common_attributes(metadata) do
    %{
      "gen_ai.conversation.id" => metadata[:session_id],
      "conversation.id" => metadata[:session_id],
      "session.id" => metadata[:session_id],
      "lemieux.session.id" => metadata[:session_id],
      "lemieux.root_session.id" => metadata[:root_session_id],
      "lemieux.provider" => string(metadata[:provider]),
      "lemieux.model" => metadata[:model]
    }
  end

  defp terminal_attributes(measurements, metadata) do
    compact(%{
      "lemieux.duration_ms" => duration_ms(measurements),
      "lemieux.outcome" => string(metadata[:outcome]),
      "lemieux.stop_reason" => string(metadata[:stop_reason]),
      "lemieux.reason.category" => string(metadata[:reason_category]),
      "lemieux.terminal.kind" => string(metadata[:kind])
    })
  end

  defp duration_ms(%{duration: duration}) when is_number(duration) do
    System.convert_time_unit(trunc(duration), :native, :millisecond)
  end

  defp duration_ms(_measurements), do: nil

  defp status(%{outcome: outcome})
       when outcome in [:error, :exception, :invalid_return, :rejected],
       do: :error

  defp status(_metadata), do: :ok

  defp string(nil), do: nil
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value) when is_binary(value), do: value
  defp string(value) when is_number(value), do: value

  defp bounded(value) when is_binary(value), do: String.slice(value, 0, 128)
  defp bounded(value) when is_atom(value), do: value |> Atom.to_string() |> bounded()
  defp bounded(_value), do: nil

  defp compact(attributes) do
    Map.reject(attributes, fn {_key, value} -> is_nil(value) end)
  end

  defp owned(reference, session_id),
    do: %{reference: reference, owned?: true, ignored?: false, session_id: session_id}

  defp borrowed(reference, session_id \\ nil),
    do: %{reference: reference, owned?: false, ignored?: false, session_id: session_id}

  defp ignored, do: %{reference: nil, owned?: false, ignored?: true, session_id: nil}

  defp put_record(config, scope, key, record) when is_list(config) do
    put_record(Keyword.fetch!(config, :handler_id), scope, key, record)
  end

  defp put_record(handler_id, scope, key, record) do
    ensure_tables()

    :ets.insert(
      @span_table,
      {record_key(handler_id, scope, key), record, System.monotonic_time(:millisecond)}
    )

    :ok
  end

  defp lookup_record(config, scope, key) when is_list(config) do
    lookup_record(Keyword.fetch!(config, :handler_id), scope, key)
  end

  defp lookup_record(handler_id, scope, key) do
    if table_exists?(@span_table) do
      record_key = record_key(handler_id, scope, key)

      case :ets.lookup(@span_table, record_key) do
        [{^record_key, record, _inserted_at}] -> record
        [] -> nil
      end
    end
  end

  defp take_record(config, scope, key) do
    if table_exists?(@span_table) do
      record_key = record_key(Keyword.fetch!(config, :handler_id), scope, key)

      case :ets.take(@span_table, record_key) do
        [{^record_key, record, _inserted_at}] -> record
        [] -> nil
      end
    end
  end

  defp record_key(handler_id, scope, key), do: {handler_id, scope, key}

  defp record_session({_handler_id, :parent, session_id}), do: session_id
  defp record_session({_handler_id, :prompt, session_id}), do: session_id
  defp record_session({_handler_id, _scope, {session_id, _id}}), do: session_id
  defp record_session(_key), do: nil

  defp close_handler_spans(handler_id, nil) do
    if table_exists?(@span_table),
      do: :ets.match_delete(@span_table, {{handler_id, :_, :_}, :_, :_})
  end

  defp close_handler_spans(handler_id, config) do
    if table_exists?(@span_table) do
      @span_table
      |> :ets.match_object({{handler_id, :_, :_}, :_, :_})
      |> Enum.each(fn {key, record, _inserted_at} ->
        close_record(record, config)
        :ets.delete(@span_table, key)
      end)
    end
  end

  defp close_record(%{owned?: true, reference: reference}, config) when is_list(config) do
    safe_end_span(reference, config)
  end

  defp close_record(_borrowed_ignored_or_unconfigured, _config), do: :ok

  defp put_propagated_headers(options, injector) do
    http_options = Keyword.get(options, :req_http_options, [])
    existing_headers = http_option(http_options, :headers, []) |> header_list()
    injected_headers = injector.([]) |> header_list()
    headers = merge_missing_headers(existing_headers, injected_headers)
    Keyword.put(options, :req_http_options, put_http_option(http_options, :headers, headers))
  end

  defp http_option(options, key, default) when is_list(options),
    do: Keyword.get(options, key, default)

  defp http_option(options, key, default) when is_map(options), do: Map.get(options, key, default)
  defp http_option(_options, _key, default), do: default

  defp put_http_option(options, key, value) when is_list(options),
    do: Keyword.put(options, key, value)

  defp put_http_option(options, key, value) when is_map(options), do: Map.put(options, key, value)
  defp put_http_option(_options, key, value), do: [{key, value}]

  defp header_list(headers) when is_map(headers), do: Map.to_list(headers)
  defp header_list(headers) when is_list(headers), do: headers
  defp header_list(_headers), do: []

  defp merge_missing_headers(existing, injected) do
    existing_names = MapSet.new(existing, fn {name, _value} -> normalized_header(name) end)

    additions =
      Enum.reject(injected, fn {name, _value} ->
        MapSet.member?(existing_names, normalized_header(name))
      end)

    existing ++ additions
  end

  defp normalized_header(name), do: name |> to_string() |> String.downcase()

  defp prune_handler_records(handler_id, ttl_ms) do
    cutoff = System.monotonic_time(:millisecond) - ttl_ms
    config = fetch_config(handler_id)

    @span_table
    |> :ets.match_object({{handler_id, :_, :_}, :_, :_})
    |> Enum.reduce(0, &prune_record(&1, &2, cutoff, config))
  end

  defp prune_record({key, record, inserted_at}, count, cutoff, config) do
    if inserted_at <= cutoff do
      close_record(record, config)
      :ets.delete(@span_table, key)
      count + 1
    else
      count
    end
  end

  defp drop_session_records({handler_id, config}, session_id) do
    @span_table
    |> :ets.match_object({{handler_id, :_, :_}, :_, :_})
    |> Enum.each(&drop_session_record(&1, session_id, config))
  end

  defp drop_session_record({key, record, _inserted_at}, session_id, config) do
    if record_session(key) == session_id do
      close_record(record, config)
      :ets.delete(@span_table, key)
    end
  end

  defp activate_record_context({handler_id, config}, session_id, scope, id) do
    handler_id
    |> lookup_record(scope, {session_id, id})
    |> activate_record(config)
  end

  defp activate_record(%{ignored?: false, reference: reference}, config) do
    case safe_activate_context(reference, config) do
      {:ok, token} -> [{config, token}]
      :error -> []
    end
  end

  defp activate_record(_missing_or_ignored, _config), do: []

  defp safe_current_context(config) do
    adapter(config).current_context(config)
  rescue
    error ->
      log_adapter_error(:current_context, error, __STACKTRACE__)
      nil
  end

  defp safe_activate_context(reference, config) do
    {:ok, adapter(config).activate_context(reference, config)}
  rescue
    error ->
      log_adapter_error(:activate_context, error, __STACKTRACE__)
      :error
  end

  defp safe_detach_context(token, config) do
    adapter(config).detach_context(token, config)
  rescue
    error ->
      log_adapter_error(:detach_context, error, __STACKTRACE__)
      :ok
  end

  defp safe_end_span(reference, config) do
    adapter(config).end_span(reference, config)
  rescue
    error ->
      log_adapter_error(:end_span, error, __STACKTRACE__)
      :ok
  end

  defp log_adapter_error(operation, error, stacktrace) do
    Logger.warning(fn ->
      "Lemieux.OpenTelemetry: adapter #{operation} failed -- " <>
        Exception.format(:error, error, stacktrace)
    end)
  end

  defp configs do
    if table_exists?(@config_table), do: :ets.tab2list(@config_table), else: []
  end

  defp fetch_config(handler_id) do
    if table_exists?(@config_table) do
      case :ets.lookup(@config_table, handler_id) do
        [{^handler_id, config}] -> config
        [] -> nil
      end
    end
  end

  defp delete_config(handler_id) do
    if table_exists?(@config_table), do: :ets.delete(@config_table, handler_id)
    :ok
  end

  defp ensure_tables do
    ensure_table(@config_table)
    ensure_table(@span_table)
    :ok
  end

  defp ensure_table(table) do
    if :ets.whereis(table) == :undefined do
      :ets.new(table, [
        :named_table,
        :public,
        :set,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  defp table_exists?(table), do: :ets.whereis(table) != :undefined
end
