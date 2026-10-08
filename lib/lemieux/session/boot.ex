defmodule Lemieux.Session.Boot do
  @moduledoc false

  alias Lemieux.Contract
  alias Lemieux.Environment
  alias Lemieux.Hooks
  alias Lemieux.MCP
  alias Lemieux.Prompt
  alias Lemieux.Provider
  alias Lemieux.Session.Accounting
  alias Lemieux.Session.Audit
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.MCPServers
  alias Lemieux.Session.Prompts
  alias Lemieux.Session.Recovery
  alias Lemieux.Session.Setup
  alias Lemieux.Session.State
  alias Lemieux.Session.Subscribers
  alias Lemieux.Tool
  alias Lemieux.Transcript.Dedup

  # A budget, not a guard: the repeat rules catch loops, and this bounds what a
  # prompt that never loops may cost in requests. It used to be fifty, which was
  # under three minutes of work at the turn rate a capable model takes over a
  # read-heavy task — a session working well stopped at a count nobody chose. Four
  # hundred is set where a session doing well on a long task never meets it.
  @max_turns 400

  # Late enough that most sessions never reach it, early enough that the
  # summarising request itself still fits in what is left of the window.
  @compact_at 0.8

  # The largest window compaction plans against. A model with a million-token
  # window used to be compacted at 800,000 tokens, which a person meets as a
  # session that got slow, expensive and forgetful long before anything was
  # summarised. Past a couple of hundred thousand tokens a window is room to
  # recover in, not room to work in.
  @window_cap 200_000

  # How long a first prompt waits for servers still connecting before its
  # request goes without their tools, from when the session started.
  @mcp_grace_ms 15_000

  # How many attachment-carrying prompts keep their attachments in a request.
  # Enough that a conversation about a file still has the file while it is the
  # subject, few enough that a long session does not re-send every file it was
  # ever shown. `Lemieux.Compaction.applied/2` says what the older ones carry.
  @keep_attachments 3

  def boot(opts) do
    # OTP only calls terminate/2 for a supervisor shutdown when the child
    # traps exits. SessionEnd hooks are cleanup, so silently skipping them on
    # the ordinary DynamicSupervisor.terminate_child/2 path is worse than the
    # small amount of explicit shutdown handling this flag asks of GenServer.
    Process.flag(:trap_exit, true)

    messages = Setup.messages_option(opts)
    guard = Setup.guard_option(opts)
    compaction = Setup.compaction_option(opts)
    # Whole payloads, whatever the store handed over: a store other than the
    # JSONL one returns what was written, references and all.
    entries = opts |> Keyword.get(:entries, []) |> Dedup.expand()
    recorded = Setup.recorded_config(entries)
    model = Setup.resolve(opts, :model, recorded, "model", nil)
    params = Setup.resolve_params(opts, recorded)
    supervisor = Keyword.fetch!(opts, :supervisor)
    hooks = Keyword.get(opts, :hooks, [])
    configured_tools = Setup.resolve_tools(opts, recorded)
    host_tools = Keyword.get(opts, :host_tools, [])
    local_tools = configured_tools ++ host_tools
    disabled_tools = Setup.resolve_disabled_tools(opts, recorded)
    tool_profile = Setup.resolve_tool_profile(opts, recorded)
    subscribers = Subscribers.new(Keyword.get(opts, :subscriber))

    tools =
      with :ok <- Tool.validate_all(local_tools),
           tools = Catalog.enabled_tools(local_tools, disabled_tools, tool_profile),
           :ok <- Tool.validate_all(tools) do
        {:ok, tools}
      end

    evidence_artifacts =
      Setup.validate_evidence_artifacts(Keyword.get(opts, :evidence_artifacts, []))

    # The transcript is claimed last, once everything that can refuse the
    # session has had its say, so a refused start never holds a lock.
    with {:ok, tools} <- tools,
         {:ok, evidence_artifacts} <- evidence_artifacts,
         state = %State{
           id: Keyword.fetch!(opts, :id),
           supervisor: supervisor,
           provider: Keyword.fetch!(opts, :provider),
           provider_limiter: Recovery.admission_option(opts, supervisor),
           provider_limit_key: Keyword.get(opts, :provider_limit_key, :default),
           root_session_id: Keyword.get(opts, :root_session_id, Keyword.fetch!(opts, :id)),
           store: Keyword.fetch!(opts, :store),
           request_count: Enum.count(entries, &(&1.type == :request)),
           context_window_fallback:
             Keyword.get(opts, :context_window_fallback, Provider.fallback_context_window()),
           mcp_connect_opts: Keyword.get(opts, :mcp_connect_opts, []),
           clock: Keyword.get(opts, :clock),
           mcp_grace_deadline:
             Setup.mcp_grace_deadline(
               Keyword.get(opts, :clock),
               Keyword.get(opts, :mcp_grace_ms, @mcp_grace_ms)
             ),
           model: model,
           input_modalities: Setup.modalities_option(opts),
           system: Setup.resolve(opts, :system, recorded, "system", &Prompt.default/0),
           params: params,
           output_schema: Keyword.get(opts, :output_schema),
           configured_tools: configured_tools,
           host_tools: host_tools,
           # Keep the whole local catalog separately from the request catalog.
           # A disabled tool must remain available to `/tools enable`; dropping
           # it from state would turn disable into an irreversible removal.
           local_tools: local_tools,
           disabled_tools: disabled_tools,
           tools: tools,
           tool_profile: tool_profile,
           tool_timeout_ms: Setup.positive_option(opts, :tool_timeout_ms, :timer.hours(1)),
           tool_output_bytes: Setup.positive_option(opts, :tool_output_bytes, 120_000),
           provider_retry_policy: Recovery.retry_policy(Keyword.get(opts, :provider_retry, [])),
           tool_token_counter: Keyword.get(opts, :tool_token_counter),
           hooks: hooks,
           # A host seam like `:hooks`: what the loop says to the model is host
           # behaviour, so it is neither recorded nor restored. `Lemieux.Messages`
           # says what each sentence is for.
           messages: messages,
           guard: guard,
           # Attention notifications are observations and must neither block the
           # session nor overtake one another. One supervised mailbox per session
           # gives them both properties; it exits when the session does.
           attention_observer: Prompts.start_attention_observer(supervisor, hooks, self()),
           # Location, not behaviour: never restored from the transcript. A
           # conversation resumed in another checkout, or on another machine,
           # belongs where it is being run rather than at a path that may be gone.
           cwd: Keyword.get_lazy(opts, :cwd, &File.cwd!/0),
           environment: Keyword.get(opts, :environment, Environment.local()),
           mcp_servers:
             opts
             |> Setup.resolve(:mcp_servers, recorded, "mcp_servers", fn -> [] end)
             |> Enum.map(&MCP.config/1)
             |> Setup.merge_mcp_servers([]),
           # A seam, like `:hooks` — never restored and never recorded, because it
           # holds a function and a credential store rather than a description of
           # what this session is.
           mcp_auth: Keyword.get(opts, :mcp_auth),
           mcp_stdio_launcher: Keyword.get(opts, :mcp_stdio_launcher),
           mcp_transports: Keyword.get(opts, :mcp_transports, %{}),
           mcp_connections: %{},
           mcp_errors: %{},
           mcp_disabled: MapSet.new(),
           max_turns: Keyword.get(opts, :max_turns, @max_turns),
           max_cost_usd: Setup.max_cost_usd(opts),
           max_requests: Setup.optional_positive_option(opts, :max_requests),
           deadline_ms: Setup.optional_positive_option(opts, :deadline_ms),
           deadline_at: Setup.deadline_at(Keyword.get(opts, :clock), opts[:deadline_ms]),
           spent_usd: Accounting.measured_spend(entries),
           request_cost_pending?: false,
           # The model's own window, or nil when nobody knows it: a status line
           # reports this, and `effective_window/1` puts the fallback beside it.
           context_window:
             Keyword.get_lazy(opts, :context_window, fn ->
               case Provider.planning_window(Keyword.fetch!(opts, :provider), model) do
                 {window, :provider} -> window
                 {_fallback, :fallback} -> nil
               end
             end),
           # Remember whether the host supplied the window. A manual value is an
           # instruction and survives a model switch; a discovered value belongs
           # to its model and has to be looked up again.
           context_window_source:
             if(Keyword.has_key?(opts, :context_window), do: :configured, else: :provider),
           compaction: %State.Compaction{
             strategy: compaction,
             auto_compaction?: Keyword.get(opts, :auto_compaction, true),
             compact_at: Keyword.get(opts, :compact_at, @compact_at),
             window_cap: Keyword.get(opts, :compaction_window_cap, @window_cap),
             input_token_counter: Keyword.get(opts, :input_token_counter),
             keep: Keyword.get(opts, :keep),
             keep_recent_tokens: Keyword.get(opts, :keep_recent_tokens),
             keep_attachments: Keyword.get(opts, :keep_attachments, @keep_attachments),
             keep_media: Setup.keep_media_option(opts),
             stub_tool_results: Setup.stub_option(opts),
             summary_sections: Setup.boolean_option(opts, :summary_sections, false),
             summary_model: Keyword.get(opts, :summary_model),
             summary_params: Keyword.get(opts, :summary_params, []),
             summary_max_bytes: Keyword.get(opts, :summary_max_bytes, 32_768),
             price_tiers: Keyword.get(opts, :compaction_price_tiers, %{}),
             price_expected_output_tokens:
               Keyword.get(opts, :compaction_expected_output_tokens, 0),
             price_minimum_savings_usd: Keyword.get(opts, :compaction_minimum_savings_usd, 0.0),
             # The task summarising, while it is running. A session is busy for the
             # length of it: it is one more request in front of the turn somebody is
             # waiting for, not a background job.
             compacting: nil,
             # Set when a summarising request fails. Threshold compaction stops being
             # attempted after that, because the alternative is paying for a doomed
             # request in front of every turn for the rest of the session. `compact/1`
             # still works, and clears it.
             compaction_failed?: false,
             # A typed context overflow before any provider progress may force one
             # compaction and retry. This is per prompt so a still-oversized tail
             # cannot create an unbounded series of paid requests.
             context_recovery_attempted?: false,
             context_recovery_reason: nil
           },
           evidence: %State.Evidence{
             level: Audit.evidence_level_option(opts),
             harness_context: opts |> Keyword.get(:harness_context, %{}) |> Contract.json(),
             correlation_ids: opts |> Keyword.get(:correlation_ids, %{}) |> Contract.json(),
             evidence_artifacts: evidence_artifacts,
             current_harness_snapshot: nil,
             current_run: nil,
             # A resumed process must not reuse a caller-supplied first-run id.
             # Terminal evidence is the durable count because it is written once
             # per accepted prompt before `:finished`.
             run_sequence: Enum.count(entries, &(&1.type == :run_evidence)),
             last_run_evidence: nil
           },
           subscribers: subscribers,
           # Newest first. Appending to a list's head is constant time and taking
           # its head is how every append finds its parent; a session that grows
           # to a thousand entries would otherwise walk the whole transcript twice
           # per entry.
           reversed_entries: Enum.reverse(entries),
           transcript_seen:
             if(Keyword.get(opts, :transcript_dedup, true), do: Dedup.seen(entries)),
           next_seq: length(entries),
           recorded_config: recorded,
           turn: nil,
           turn_ref: nil,
           current_request_id: nil,
           provider_progress?: false,
           prompt_started_at: nil,
           turn_started_at: nil,
           first_delta_emitted?: false,
           task: nil,
           # A blocking lifecycle hook runs in its own task. The session remains
           # responsive while a prompt policy or stop verifier is thinking, just
           # as it does while a tool approval is parked.
           hook_task: nil,
           stop_hook_active: false,
           turns_taken: 0,
           wave: %State.Wave{
             tool_tasks: %{},
             tool_results: %{},
             tool_order: [],
             # The rest of the current wave, waiting its turn: writers one at a time
             # in execution batches. See
             # `run_tools/2`.
             tool_batches: [],
             # The last wave's fingerprint and how many times running it has come
             # back the same. See `note_wave/2`.
             last_wave: nil,
             repeats: 0
           },
           # call_id => %{from:, kind:, payload:, timer:}, for calls waiting on
           # somebody to answer.
           parked: %{},
           approval_timeout: Setup.approval_timeout_option(opts),
           # Newest first, like the transcript, and for the same reason.
           reversed_steers: [],
           reversed_follow_ups: [],
           subagent_groups: %{}
         },
         {:ok, store_lock} <- Setup.claim_transcript(opts) do
      {:ok, %{state | store_lock: store_lock}, {:continue, :connect_mcp}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  def continue_with(:connect_mcp, %{mcp_servers: []} = state),
    do: {:noreply, %{state | mcp_ready?: true}, {:continue, :record_config}}

  # Started here and settled in `handle_info/2`, not waited for. Connecting in
  # this callback made the session deaf for as long as its slowest server took:
  # an `npx` that had to download its package, a server waiting on somebody's
  # OAuth consent. A screen asking for a snapshot in that time gave up after
  # five seconds and reported that the session had failed to start. Each server
  # now connects in its own task, its tools join the catalog when it answers,
  # and a first prompt waits a bounded time for the rest (`:mcp_grace_ms`),
  # because the model is told what it may call in the request itself. A server
  # that is unavailable still contributes no tools and stops nothing.
  def continue_with(:connect_mcp, state),
    do:
      {:noreply, MCPServers.start_mcp_connections(state, state.mcp_servers),
       {:continue, :record_config}}

  # No window notice here: one sent at start reaches nobody who would show it.
  # `Lemieux.Session.Window` sends it before the first request instead.
  def continue_with(:record_config, state) do
    state = state |> Setup.answer_lost_calls() |> Setup.record_config()

    source = if state.next_seq == 1, do: :startup, else: :resume
    hooks = state.hooks
    context = Prompts.hook_context(state)

    {:noreply,
     Prompts.observe_async(state, fn -> Hooks.session_start(hooks, source, context) end)}
  end
end
