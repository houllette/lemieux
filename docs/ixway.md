# Ixway inference integration

Ixway is an optional, first-party inference pipeline. Opting in makes it the
sole model destination for that provider instance: discovery, model selection,
agent turns, tool continuations, compaction, reflection, and inherited child
sessions use the gateway. Standalone extension providers and benchmark judges
also honor personal inference configuration and `LMX_IXWAY_URL`. Ordinary direct-provider operation remains the default.

This page covers inference routing only: a session's model calls travel
through Ixway. The separate observation and analytics role, in which run
evidence and findings are handed to Ixway, is described in the
[cross-system architecture](host-integration.md)
and the [Ixway handoff](host-integration.md#ixway-analytics-adoption). That handoff has no
client in this library.

## CLI and TUI

```sh
export LMX_IXWAY_URL=https://ixway.example.com
# Supply IXWAY_API_KEY privately through your shell or secret manager.
lmx
lmx run --model ixway:team/coding "Review this project"
```

`--ixway https://ixway.example.com` overrides `LMX_IXWAY_URL`. Supply the
instance origin, without `/v1`, a query, or URL credentials. `--base-url` and
`LMX_BASE_URL` select the direct route and conflict with Ixway choices in the same configuration layer. `IXWAY_API_KEY` alone
does not enable the integration. Direct-provider keys are used only when the
TUI explicitly selects a direct model, or when the route is set to direct.

In the TUI, `/provider` lists `ixway` alongside direct providers with configured
credentials and compatible models. `/model` lists only models for the selected
provider. Ixway choices come from the gateway key's catalog; direct choices
come from ReqLLM's credential-filtered catalog. Use the exact advertised ID after `ixway:`:
`ixway:team/coding` addresses `team/coding`, which could be an operator profile,
an alias, or a concrete model. No profile name is presumed to exist.

The Ixway model picker opens on **Ixway**. This tab lists bare model IDs,
intents, and aliases; a bare ID lets Ixway choose among compatible serving
backends. Qualified routes have separate tabs such as **OpenAI** and **Codex**,
so `gpt-5.6-luna` appears once per tab rather than three times together.
The picker keeps one height while cycling tabs. Press Shift+Tab to cycle tabs,
or click a tab when mouse capture is enabled.
Enter applies the highlighted model and closes the picker. Tab fills the input
with its exact route ID for editing: selecting `gpt-5.6-luna` under Codex writes
`/model openai_codex:gpt-5.6-luna`. Typing a qualified ID also searches across
tabs, so explicit routes remain reachable without tab navigation. Ixway's
catalogue marks intents and aliases, which lead the Ixway list after personal
selections. Concrete models with known release dates follow newest first;
unknown dates fall back to alphabetical order. Lemieux uses an optional
`ixway_release_date` from the gateway, falling back to the bundled model
catalogue for exact ID matches. It does not infer the route of a bare ID from
its `owned_by` field.

For Ixway's catalogue, `ixway_release_date` should be an ISO `YYYY-MM-DD`
date on a concrete model only when the underlying model's date is known.
Omit it for an alias, intent, or ambiguous target. The existing `created` and
`created_at` placeholders do not describe a model's release date.

A new session without `--model` or `LMX_MODEL` selects the available key policy
default, then the unique compatible instance recommendation. An unavailable
configured default or ambiguous recommendation requires an explicit choice.
The internal selection instruction `ixway:@default` resolves before a new CLI
session records its model. Resume preserves the recorded model and refreshes
discovery using the current host connection. To move a direct-provider
transcript onto Ixway, explicitly select `--model ixway:ID` when resuming.

Failures of Ixway discovery, authentication, compatibility or inference never
cause an `ixway:` request to try a direct provider. A TUI user can explicitly
switch to a direct model with `/provider` or `/model`. The TUI's convenience
catalogue may return an empty list after a discovery failure; startup and
request validation return an error explaining the failure.

You can save this connection and optional model and effort defaults in
[`~/.lmx/config.json`](configuration.md#personal-configuration). `--router direct`
disables the saved route for one command; `--router ixway` activates it.

`lmx` registers Ixway as the model route named `ixway` (`Lemieux.CLI.Routes`),
through the same mechanism an extension uses to register a route of its own
([Adding a model route](extensions.md#adding-a-model-route)). The prefetch
before the screen opens, the resolution of `ixway:@default`, the `/provider`
and `/model` listings and the rule that an `ixway:` request never reaches a
direct provider are that mechanism's, not special cases for this gateway;
`Lemieux.Ixway` supplies the gateway's discovery, catalogue, default and
routing disclosure through `Lemieux.Provider.Route`'s callbacks.

## Embedded hosts

No new dependency, supervisor child, database or endpoint is required.
Constructing a connection does no I/O; discovery is an explicit non-billable
operation:

```elixir
connection = Lemieux.Ixway.new(
  endpoint: ixway_origin,
  api_key: gateway_model_key,
  headers: [
    {"x-ixway-priority", "interactive"},
    {"x-ixway-residency", "local_only"},
    {"x-ixway-latency-slo-ms", "2000"},
    {"x-ixway-max-cost-per-mtok", "5.00"}
  ]
)

{:ok, connection} = Lemieux.Ixway.discover(connection)
{:ok, model} = Lemieux.Ixway.select_model(connection, "ixway:@default")
provider = Lemieux.Ixway.provider(connection, receive_timeout: :infinity)

{:ok, session} = Lemieux.start_session(
  supervisor: MyLemieux,
  provider: provider,
  store: Lemieux.Store.JSONL.new("sessions"),
  model: model
)
```

`Lemieux.Ixway` is the shipped `Lemieux.Provider.Route` (see
[providers](providers.md#routes)): `provider/2` builds a
`Lemieux.Providers.ReqLLM` with `route: {Lemieux.Ixway, connection}` and
passes the remaining options to the adapter. `Lemieux.Providers.ReqLLM.new/1`
refuses an `:ixway` option by name rather than forwarding it to `req_llm`.
`Lemieux.Ixway.connection/1` reads the connection back out of a provider.

Failures on the gateway side — a missing key, an unavailable model, a tool
the profile does not support, a discovery request that did not reach the
instance — are `%Lemieux.Ixway.Error{reason: ...}` values. Match on `reason`
for policy; `Lemieux.Provider.Error.message/1` renders the sentence, and
classifies them as `:other`, so no retry is attempted.

The host starts and owns `MyLemieux` as usual. `Lemieux.Ixway.new/1` also
accepts `:discovery_options`, Req transport options applied to the discovery
request. A connection without a discovered catalogue is also accepted;
callbacks discover on demand. Explicit discovery avoids repeated reads.
Rebuild and rediscover after changing a key/profile or reconnecting; catalogue
snapshots do not update themselves. Ixway still checks current policy at
inference admission.

The private provider state retains credentials and deployment URLs; neither
belongs in session parameters or transcripts. Generation parameters cannot
replace the Ixway origin, authentication, HTTP headers or wire transport.
Host-provided `x-ixway-*` constraints tighten gateway policy; gateway admission
validates their values. Authentication headers are constructed by the integration.

## Routing, tools and observability

All inference uses ReqLLM's OpenAI Chat Completions implementation and Ixway's
`/v1/chat/completions`. An inline model explicitly fixes that grammar, including
for model names ReqLLM would otherwise send to Responses. Ixway owns provider
selection, native egress, quota, priority, residency, routing and failover.
Lemieux implements no provider protocol or alternate inference HTTP client.

Every request offering tools sends `x-ixway-required-capabilities: tools`,
merged with the host's required capabilities. This matters for mixed pools:
a catalog's `partial` or `unknown` capability must not permit a request to land
on a target without tools. Explicit `unsupported` capability is rejected locally.
Structured output uses ReqLLM's normal structured-output path; gateway/backend
support is still required. No unsupported capability is synthesized locally.

The catalog's `max_input_tokens` supplies automatic context-window accounting.
For aliases and intents, Ixway publishes the smallest eligible target limit,
so Lemieux's default 80% auto-compaction threshold uses a conservative ceiling.
Cache-read input still occupies that window even when its price is lower;
Lemieux's context accounting includes the provider-reported cached tokens.
Missing limits remain unknown. Model/profile changes use the same validation
path. `ixway_reasoning_effort` supplies the reasoning-effort menu, least effort
first, and for an alias that list is the intersection across every target it may
route to. An entry that omits the key offers no menu — an older instance and a
model family that budgets thinking tokens rather than naming levels are
deliberately indistinguishable here — and a host can still supply an explicit
effort either way, because the catalog is advisory and gateway admission stays
authoritative.

Session inference carries Lemieux session/conversation IDs and the application name.
Ixway generates its own request ID, returned in response disclosure. Lemieux
request IDs stay in request snapshots and active trace spans.
Active W3C trace context is propagated by default in Ixway mode; set
`propagate_trace_context: false` on the provider to disable it. Explicit trace
headers take precedence. [OTLP export](telemetry.md) remains a separate host
connection.

Allowlisted response disclosure fields are saved under `ixway` in assistant
messages and request usage: session ID, resolved model/backend, policy,
resolution reason, decision ID and request ID when returned. Other response
headers are discarded. Requested profile identity remains the transcript's
model; routing disclosure records what actually served it.

### Accounting boundary

Token usage is retained. The current public catalog does not publish a
reliable price for the final routed request. Lemieux does not label a pool
with a guessed OpenAI price or count unknown cost as free. Ixway-mode cost
estimates and locally calculated request prices remain unknown. Consequently,
Lemieux's `max_cost_usd` gate rejects these requests; profiles or extensions
requiring a local USD budget must be reconfigured explicitly. Use gateway key
budgets and cost constraints for managed inference, with Lemieux token/turn
bounds where appropriate. Ixway's settlement ledger is the billing authority.

Ixway evaluates reviewed conditional tariffs, prompt-size tiers and
provider-reported cache read/write meters at quote and settlement time. These
are gateway decisions; Lemieux sends the same request and routing constraints
and does not copy a potentially stale tariff into local pricing. Its current
streaming route does not acquire an exact-request quote or send the
`x-ixway-max-cost-usd` hard-cap header. The settled receipt may carry a known
API-route cost, but Lemieux does not import it into its local budget after
dispatch. Gateway budgets and receipts remain the authoritative control and
record for routed USD spending.

When a completed stream supplies a request ID, receipt URL and receipt token,
Lemieux checks the URL against the configured Ixway origin and starts a
best-effort background receipt lookup with the same model key. A pending `202`
uses `Retry-After` within a three-attempt bound. Redirects are disabled. A
receipt that remains pending, fails, or cannot be reached leaves the comparison
unknown with a reason; it never retries inference or changes provider route.
The key and receipt token remain private and are not written to the transcript,
provider metadata, logs or subscriber events.

Only a settled receipt's `data.api_equivalent` is displayed. If it is absent,
no comparison is shown. Interactive front ends accumulate the USD decimal
strings in their status line as **estimated cost**, without printing a line
after each answer. `/context` shows the reference provider/source, exclusions,
and the installed-catalog caveat. An unknown estimate keeps Ixway's reason.
When measured API usage is also present, the status shows both amounts and an
approximate combined total only when every unpriced request has an estimate.
This is an illustrative comparison at the currently installed catalog rates;
another catalog may give a different estimate. It does not change actual cost,
`usage.cost_usd`, session spending, savings or budget limits. The comparison
is not a durable transcript entry, so it is not restored after a process
restart. A one-shot `lmx run` can exit before the background lookup reports it.

## Public API evaluation and boundaries

The table describes how the Lemieux integration uses gateway surfaces.
Confirm the deployed gateway contract before enabling optional features.

| Public surface | Lemieux use |
| --- | --- |
| `GET /.well-known/ixway` | Validate Ixway identity and OpenAI chat ingress before authenticated discovery |
| `GET /v1/models` and `ixway_client` | Key-scoped models, compatible dialect, explicit defaults, capabilities and limits |
| `POST /v1/chat/completions` | Sole interactive inference endpoint through ReqLLM; text, tool calls and structured output |
| Routing constraint headers | Host-controlled priority, quality, residency, latency, cost and capability constraints |
| Session/request and W3C headers | Correlation and gateway session affinity |
| Routing disclosure headers | Preserve requested-versus-resolved model evidence in the transcript |
| `GET /v1/ixway/requests/{id}` | Optional bounded receipt lookup for a separate subscription API equivalent comparison |
| `/openapi.json`, `/conformance/v1` | Versioned contract resources for evaluation; no automatic download on every turn |
| `/healthz`, `/readyz` | Operator diagnostics; neither proves model entitlement or successful inference |
| Anthropic, Responses, token-count endpoints | Available alternatives in Ixway; this integration fixes one compatible grammar |
| Durable batch submission/status/results | Separate scheduling lifecycle; interactive sessions retain cancellation and streaming semantics |
| Routing/execution feedback and observation APIs | Host-owned feedback authority; inference alone does not authorize feedback submission |
| Admin/settings/key APIs | Operator plane, outside a coding session's model-key integration |

Tests exercise local HTTP discovery and ReqLLM streaming, credential isolation,
selection and failure cases. They do not establish live provider entitlement,
managed-profile quality, gateway pricing, production deployment or midstream
failover. Ixway explicitly does not promise midstream failover.

## Embedding Lemieux inside Ixway

This is separate from pointing `lmx` at an inference gateway. Ixway's internal
analysis host mounts its own runtime, provides scoped query tools and owns ETS
storage, invocation cleanup, accounting and durable job retries. It can keep
ordinary Session/Provider/Environment/Store APIs; adopting `Harness` is optional.
No CLI loader, terminal or coding recipe is required.

Preserve explicit empty tool catalogs and meaningful nil settings. Mandatory
host hooks, limits, environment and current credentials belong beside `harness:`
so they win. Do not apply the coding recipe to a restricted analysis session.
Caller death and timeout must stop session/provider work before deleting storage;
subscribing to events does not establish ownership. Shared parallel query budgets
remain host-owned.

`provider_retry: false` leaves durable scheduling/backoff to the host; provider
`max_retries: 0` controls a separate transport retry layer. Lemieux counts actual
provider attempts against `max_requests`. An inevitable retry-budget refusal
retains the original typed failure and occurs without backoff. `context.retry`
identifies preparation re-entry without confusing it with a new ordinary turn.

For structured extraction, pin `wire_protocol: "openai_chat"` on the transport
route before changing an existing parser. Hosts may retain their current JSON
response format and feature-owned schema validation. For routing observations,
select safe `response_metadata` headers and `model_header`, then consume the
`{:response_metadata, map}` event. Requested aliases are not observed resolved
models; missing disclosure, caller-only timeouts and hard cancellation can leave
HTTP metadata unknown. Preserve that uncertainty in accounting. See
[Provider metadata](providers.md#pinning-extraction-transport-and-observing-responses).

The local package consumer models these constraints in separate VMs, including
resume, decorated host tools, custom messages/compaction and tightened authority.
It does not qualify Ixway's database, tenant boundary, Oban, native HTTP adapter
or production behavior. Dependency adoption still needs Ixway's own focused
Ask/inference/accounting/cancellation tests, repository gate and matching CI.
