# Telemetry

Lemieux emits harness-level Telemetry events for work that ReqLLM cannot see:
prompt and turn lifecycles, admission waits, first output, tool execution,
compaction, and cancellation. ReqLLM's own events remain the authority for its
HTTP/provider internals and token accounting.

Attach to `Lemieux.Telemetry.events/0` when a host wants the whole contract, or
to individual names:

```elixir
:telemetry.attach_many(
  "my-app-lemieux",
  Lemieux.Telemetry.events(),
  &MyApp.LemieuxTelemetry.handle_event/4,
  %{}
)
```

## Event contract

| Event | Measurements | Useful metadata |
| --- | --- | --- |
| `[:lemieux, :session, :prompt, :start]` | `monotonic_time`, `system_time` | session/root id, provider, model |
| `[:lemieux, :session, :prompt, :stop]` | `duration` | stop reason and outcome |
| `[:lemieux, :turn, :start | :stop]` | start clocks or `duration` | request id, provider, model, outcome |
| `[:lemieux, :provider, :request, :start | :stop | :exception]` | start clocks or `duration` | request id, request kind, typed error category |
| `[:lemieux, :provider, :first_delta]` | `duration` | request and destination entry ids |
| `[:lemieux, :provider_limiter, :wait, :start | :stop | :exception]` | start clocks or `duration` | root id, request id, outcome |
| `[:lemieux, :tool, :call, :start | :stop]` | start clocks or `duration` | tool name, call id, outcome |
| `[:lemieux, :compaction, :start | :stop]` | start clocks or `duration` | request id, threshold/recovery kind, outcome |
| `[:lemieux, :session, :cancel]` | `monotonic_time` | session id and stop reason |
| `[:lemieux, :subagent, :admission, :start | :stop]` | start clocks or `duration` | group, child, definition and root ids, outcome |
| `[:lemieux, :subagent, :cancel, :start | :stop]` | `children`, then `duration` and `terminated` | group and root ids, requested stop reason, `:settled` or `:terminated` |
| `[:lemieux, :subagent, :group, :pressure]` | `message_queue_len`, `memory_bytes`, `running`, `queued` | group and root ids |
| `[:lemieux, :subagent, :progress]` | `elapsed_ms`, `checks` | group, child, definition and root ids, `outcome` (`:progressing` or `:stalled`), `assessed_by` (`:activity`, `:model`, `:host` or `:error`) |

Durations use the VM's native time unit, following Telemetry convention. Event
names and keys are a public API; consumers should ignore unknown metadata so
new correlation fields remain additive. `Lemieux.Telemetry.metadata_keys/0`
returns the whole allowlist, which is what a host auditing what reaches its
exporter should read rather than infer from the events it happens to see.

One event sits outside `events/0`: a mounted `Lemieux.A2A.Server` emits
`[:lemieux, :a2a, :task, :stop]` with a `count` of 1, the task id and its
final state each time a task finishes.

The progress event is one soft-deadline check on a delegated child: how long
it had run, how many checks it has had, and who decided (see
`Lemieux.Progress`). The other three subagent events measure the coordinator
rather than the work a fan-out does. Usage summaries already answer what a
delegation cost; these answer whether the coordinator kept up with it: how
long a child waited for a runtime slot, how long a cancellation took and how
many children had to be terminated after the grace interval, and the
coordinator's own mailbox and memory while children run. Any wider delegation
tree needs these measurements first: breadth that is not measured is breadth
nobody can say was safe.

## Redaction and cardinality

`Lemieux.Telemetry` applies a central metadata allowlist. It never emits:

- user or system prompts;
- tool arguments, output, paths, or structured content;
- API keys, request headers, endpoints, or provider response bodies;
- exception structs, stacktraces, or arbitrary hook data.

It does include stable session, root, request, entry and call identifiers.
Those make standalone and embedded traces correlatable, but a multi-tenant host
may consider its own identifiers sensitive. Such a host should supply opaque or
pseudonymous session ids rather than putting tenant/workspace names in them.

Telemetry handlers execute in the process that emits the event. Keep the
handler small and forward export work to a supervised process; blocking a
handler adds latency to the session or provider task being observed.

## OpenTelemetry bridge

`Lemieux.OpenTelemetry` is an optional translation of the redacted event
contract above. Lemieux does not depend on OpenTelemetry, start its SDK, or
configure an exporter. The embedding application owns those dependencies and
the whole delivery path; attaching the bridge merely uses the tracer provider
already running in that application.

`Lemieux.OpenTelemetry.events/0` lists the Lemieux events the bridge
translates, and `available?/1` reports whether the selected adapter can reach
the host's OTel API before you attach.

The resulting structure is deliberately split by ownership:

| Span or event | Owner |
| --- | --- |
| Agent prompt, turn, local/MCP tool, compaction, provider admission wait | `Lemieux.OpenTelemetry` |
| Model request, response model, token usage, finish reason, server-side tool | `ReqLLM.OpenTelemetry` |
| Workflow, durable step, retry and outer application agent | The host application |
| Exact routed provider, gateway timing, token/cost ledger and request settlement | Ixway gateway |

Lemieux's spans are metadata-only. They never contain prompts, completions,
tool arguments or results, paths, headers, exception text, or provider bodies.
ReqLLM content capture is forced to `:none` when Lemieux attaches its bridge.
Ixway's gateway ledger remains the billing and routing authority; an OTLP model
span is useful topology, not a second cost ledger.

Every span carries the session id as `session.id` and `conversation.id`.
The other attributes come in three namespaces: `gen_ai.*` from the GenAI
semantic conventions; `lemieux.*` for session, request, outcome and timing
details; and `ixway.*`. `ixway.span.kind` classifies each span as `agent`,
`tool` or `custom`, `ixway.definition.name` names the agent or tool it ran,
and the agent span adds the Lemieux version as `ixway.definition.version`.

### Standalone Lemieux pointed at Ixway

The host application installs and configures `:opentelemetry` and its exporter
for the Ixway OTLP endpoint, then explicitly attaches both harness and ReqLLM
instrumentation:

```elixir
:ok =
  Lemieux.OpenTelemetry.attach("my-app-lemieux-otel",
    req_llm: true
  )

provider =
  Lemieux.Ixway.provider(
    [
      endpoint: ixway_origin,
      api_key: ixway_virtual_key,
      headers: ixway_identity_headers
    ],
    propagate_trace_context: true
  )
```

The OTLP exporter and the model API route are separate connections even when
both end at Ixway. `propagate_trace_context: true` injects the active W3C
`traceparent`/`tracestate` into ReqLLM's HTTP headers so the gateway request can
join the application trace. Enable it only for a trusted gateway endpoint.
Explicit host headers win case-insensitively, so Lemieux never replaces a
route-specific `traceparent` or `tracestate`.

The bridge activates the turn or compaction span inside the provider task and
the tool span inside the tool task. This explicit handoff is required because
[OpenTelemetry context does not automatically cross BEAM process
boundaries](https://opentelemetry-process-propagator.hexdocs.pm/). It also
means downstream ReqLLM and MCP instrumentation receives the correct parent
rather than appearing as unrelated root traces.

### Inside a host that records its own agent spans

A host application that already runs the OpenTelemetry SDK and its exporter,
records its own agent spans, and has attached `ReqLLM.OpenTelemetry` itself
(perhaps with a redacting adapter) attaches Lemieux from the same long-lived
telemetry process with:

```elixir
:ok =
  Lemieux.OpenTelemetry.attach({MyApp.Telemetry, :lemieux},
    agent_spans: :subagents,
    require_parent: true,
    req_llm: false
  )
```

That combination is load-bearing:

- `agent_spans: :subagents` borrows the host's active agent span for the root
  Lemieux session instead of creating a duplicate agent span. Delegated
  Lemieux sessions still get their own agent spans beneath that root.
- `require_parent: true` ignores sessions the host started without an active
  agent span of its own (ordinary or interactive ones) instead of turning
  them into unrelated OTLP roots. Their model calls stay visible wherever the
  host already records them; for a host that routes through Ixway, that is
  the gateway's ledger.
- `req_llm: false` leaves the host's one `ReqLLM.OpenTelemetry` attachment,
  and its adapter, authoritative for model spans.

The host's agent span must be active when it calls
`Lemieux.start_session/1` or `Lemieux.Session.prompt/2`. Lemieux captures that
context, borrows it for the root prompt, and makes child sessions descendants
even though their processes start elsewhere. A delegated child prefers the
captured `delegate` tool context and falls back to the root agent context, so
the call tree retains the causal tool-to-subagent edge. A host that already
supplies an explicit gateway `traceparent` does not need
`propagate_trace_context: true` on the Lemieux provider in that path.

If the host already turns Lemieux's tool events into tool spans itself, stop
doing so when it attaches the bridge: keeping both produces two spans for the
same call. The host's own workflow and step spans and its ReqLLM model spans
stay as they are.

The long-lived host process should prune and eventually detach the bridge on
the same schedule it already uses for ReqLLM:

```elixir
Lemieux.OpenTelemetry.prune_stale_spans(
  {MyApp.Telemetry, :lemieux},
  :timer.minutes(30)
)

Lemieux.OpenTelemetry.detach({MyApp.Telemetry, :lemieux})
```

### Why this shape

The useful pattern in
[`agent_obs`](https://github.com/lostbean/agent_obs) is its separation between
agent lifecycle events and an OpenTelemetry handler. Lemieux keeps that split,
but does not adopt an SDK/exporter dependency, automatic OTP application,
process-dictionary span bookkeeping, or default content capture. Cross-process
starts and stops are instead correlated by stable redacted IDs in ETS.

The OpenTelemetry [GenAI agent span
conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-agent-spans.md)
and [tool span
conventions](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/gen-ai-spans.md)
are still marked Development, so their `gen_ai.*` mapping is isolated in this
bridge while the underlying `Lemieux.Telemetry` names remain stable. The
bridge follows the current `invoke_agent` and `execute_tool` span shapes and
emits one tool span at the owner boundary; lower [MCP
instrumentation](https://github.com/open-telemetry/semantic-conventions-genai/blob/main/docs/gen-ai/mcp.md)
should not duplicate a tool span already covered by Lemieux.
