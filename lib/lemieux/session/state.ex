defmodule Lemieux.Session.State.Compaction do
  @moduledoc false

  # How and when the elder conversation is summarised, and the summarising
  # request while one is running. `strategy` is the `{module, state}` the
  # session summarises through — `Lemieux.Compaction` unless a host said
  # otherwise; `compacting` is that request's task and plan, and a session is
  # busy for the length of it.
  #
  # No module is named as a default here, nor for `messages` and `guard` below:
  # an alias in a struct default is a compile-time reference, and the state
  # would then recompile the loop's seams into every module that builds one.
  # `Lemieux.Session.init/1` fills all three.
  #
  # `window_cap` is the most of a window the trigger and the default retained
  # tail are sized against; `stub_tool_results` is the stubbing projection's
  # options, or nil. `failures` and `retry_at` are the backoff that replaced a
  # flag which turned threshold compaction off for good after one failure:
  # `retry_at` is the request count before which the threshold is not tried.
  # `verify_room?` is set by an automatic compaction and settled by the
  # request built after it, which says whether the summary made any room.
  defstruct strategy: nil,
            auto_compaction?: true,
            compact_at: nil,
            window_cap: nil,
            input_token_counter: nil,
            preflight_attempted?: false,
            keep: nil,
            keep_recent_tokens: nil,
            keep_attachments: nil,
            keep_media: nil,
            stub_tool_results: nil,
            summary_sections: false,
            summary_model: nil,
            summary_params: [],
            summary_max_bytes: 32_768,
            price_tiers: %{},
            price_expected_output_tokens: 0,
            price_minimum_savings_usd: 0.0,
            advice: nil,
            trigger: nil,
            forecast: nil,
            compacting: nil,
            compaction_failed?: false,
            failures: 0,
            retry_at: nil,
            verify_room?: false,
            context_recovery_attempted?: false,
            context_recovery_reason: nil
end

defmodule Lemieux.Session.State.Wave do
  @moduledoc false

  # The tool calls one assistant turn asked for: the tasks running them, the
  # results and receipts they have produced, the order the model asked in and
  # the batches still to run. `last_wave`, `repeats` and `recent_calls` are
  # what the loop remembers across waves so a stuck one can be recognised;
  # `Lemieux.Session.note_wave/2` says what each one means.
  defstruct tool_tasks: %{},
            tool_results: %{},
            tool_receipts: %{},
            tool_order: [],
            tool_batches: [],
            last_wave: nil,
            repeats: 0,
            recent_calls: []
end

defmodule Lemieux.Session.State.Evidence do
  @moduledoc false

  # What a run records about itself beyond the conversation: the host's
  # harness context and correlation ids, the harness snapshot in force for
  # the current request, and the run whose terminal evidence is being built.
  # `level` is how much of it is written: `:full`, `:digests` (request
  # snapshots keep digests and sizes, not the prompt and schemas) or `:off`
  # (no harness snapshots or run evidence at all).
  defstruct level: :full,
            harness_context: %{},
            correlation_ids: %{},
            evidence_artifacts: [],
            current_harness_snapshot: nil,
            current_run: nil,
            run_sequence: 0,
            last_run_evidence: nil
end

defmodule Lemieux.Session.State do
  @moduledoc false

  alias Lemieux.Session.State.Compaction
  alias Lemieux.Session.State.Evidence
  alias Lemieux.Session.State.Wave

  # Session has many responsibilities because it is the single ordered writer
  # for a run. Naming the state does not split that ownership; it makes adding
  # or misspelling a field visible to the compiler instead of silently growing
  # an anonymous map.
  #
  # Three concerns that travel together live under their own structs rather than
  # flat among sixty fields. Each is a separable opinion — how the elder
  # conversation is summarised, how a wave of tool calls is run and remembered,
  # what evidence a run leaves — and grouping them is what lets a later lift of
  # one behind a seam touch one field instead of eight scattered ones. Nothing
  # about ownership changes: the session process still writes all of it. They
  # are defined above rather than nested so this body can use them as struct
  # literals, which a module cannot do with one it is still defining.
  # A few groups below are flat rather than structs, and say so here:
  #
  #   * `clock` is where the session's timers and deadlines come from —
  #     `Lemieux.Clock`; nil is the real one.
  #   * `store_lock` is the claim `Lemieux.Store.lock/2` returned, released in
  #     `terminate/2`; `transcript_seen` the digests of the large values already
  #     written in full (`Lemieux.Transcript.Dedup`), or nil when the host
  #     turned references off; `request_count` is how many `:request` entries the
  #     transcript holds, kept as a count because the budget and the compaction
  #     backoff both ask on every request.
  #   * `context_window_fallback` is what the trigger sizes against when the
  #     provider knows no window, and `window_notice` the model the notice
  #     saying so was last sent for. `served_window` is what the provider
  #     last reported serving the current model with (`{:context_window, _}`),
  #     and `window_checked` the `{model, window}` the room left after the
  #     session's own instructions and tools was last weighed against —
  #     `Lemieux.Session.Window` says why each exists.
  #   * `mcp_pending` maps a connection task's ref to its server's name while
  #     the startup connections run; `mcp_ready?` turns true, once, when none
  #     are left. `mcp_wait` is a turn held for them within
  #     `mcp_grace_deadline`, and `mcp_waiters` the calls about the catalog —
  #     `mcp_status/1`, `tool_status/1` and the like — answered when they settle.
  #     `mcp_needs_auth` holds what a server wanting OAuth consent said about
  #     where to get it, and `mcp_notices` what each server's tools were
  #     renamed or dropped for; both by server name.
  #   * `input_modalities` is a host's own answer to what the model can be
  #     shown besides text, or nil to ask the provider on each tool call —
  #     the model can change mid-session, and the answer with it.
  @fields [
    id: nil,
    supervisor: nil,
    provider: nil,
    provider_limiter: nil,
    provider_limit_key: :default,
    root_session_id: nil,
    store: nil,
    store_lock: nil,
    transcript_seen: nil,
    clock: nil,
    request_count: 0,
    context_window_fallback: nil,
    window_notice: nil,
    served_window: nil,
    window_checked: nil,
    mcp_pending: %{},
    mcp_ready?: false,
    mcp_grace_deadline: nil,
    mcp_wait: nil,
    mcp_waiters: [],
    mcp_needs_auth: %{},
    mcp_notices: %{},
    mcp_connect_opts: [],
    model: nil,
    input_modalities: nil,
    system: nil,
    params: [],
    output_schema: nil,
    configured_tools: [],
    host_tools: [],
    local_tools: [],
    disabled_tools: MapSet.new(),
    tools: [],
    tool_profile: nil,
    tool_timeout_ms: nil,
    tool_output_bytes: nil,
    tool_token_counter: nil,
    hooks: [],
    messages: nil,
    guard: nil,
    attention_observer: nil,
    cwd: nil,
    environment: nil,
    mcp_servers: [],
    mcp_auth: nil,
    mcp_stdio_launcher: nil,
    mcp_transports: %{},
    mcp_connections: %{},
    mcp_errors: %{},
    mcp_disabled: MapSet.new(),
    max_turns: nil,
    max_cost_usd: nil,
    max_requests: nil,
    # The host's deadline for this session, as it was given and as the
    # monotonic instant on `clock` it falls at. Information only: see
    # `:deadline_ms` in `Lemieux.Session`.
    deadline_ms: nil,
    deadline_at: nil,
    spent_usd: nil,
    request_cost_pending?: false,
    context_window: nil,
    context_window_source: :provider,
    compaction: %Compaction{},
    provider_retry_policy: nil,
    provider_retry: nil,
    retry_attempt: 0,
    retry_note: nil,
    retry_failure: nil,
    evidence: %Evidence{},
    aside: nil,
    subscribers: nil,
    reversed_entries: [],
    next_seq: 0,
    recorded_config: %{},
    turn: nil,
    turn_ref: nil,
    current_request_id: nil,
    provider_progress?: false,
    prompt_started_at: nil,
    turn_started_at: nil,
    first_delta_emitted?: false,
    task: nil,
    hook_task: nil,
    stop_hook_active: false,
    turns_taken: 0,
    wave: %Wave{},
    parked: %{},
    approval_timeout: nil,
    reversed_steers: [],
    reversed_follow_ups: [],
    subagent_groups: %{}
  ]

  defstruct @fields
end
