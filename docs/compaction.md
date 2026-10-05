# Compaction and price-aware preflight

A model reads at most so many tokens at once: its context window. A long
session outgrows it. **Compaction** keeps the session inside the window: the
session asks the model to summarise the older part of the conversation, then
sends that summary and the recent part instead of everything.

Lemieux never rewrites the transcript to do this. Compaction appends a
summary entry and sends only the retained tail on later requests, so resume,
fork and replay still see the whole conversation. A failed summary leaves the
conversation intact.

The check runs on every model request, **after** `prepare_next_turn` hooks
and **before** the request is sent, so a new prompt, tool result, tool
catalog or host rewrite takes part in the decision. The loop makes at most
one compaction attempt before each request. `/compact` in the terminal UI,
and `Lemieux.Session.compact/2` in the library, compact on demand.

## When it compacts

The default trigger is `compact_at: 0.8`: compact when the next request is
forecast to fill 80% of the model's window. The window is capped at
`compaction_window_cap` (200,000 tokens by default), so a million-token model
compacts at 160,000 tokens rather than 800,000: long before a window that
size fills, requests are slower, dearer and worse at finding what matters.
`compaction_window_cap: nil` plans against the whole window. `compact_at:
nil` turns the trigger off while leaving explicit, price, advisory and
overflow compaction available.

The forecast is an estimate, not a provider tokenizer. Without a counter,
Lemieux projects from the provider's last measured usage and how much the
request grew since, and never forecasts less than the request's encoded
bytes divided by four. Only what is sent to the model counts: user, system,
assistant and tool-result entries, not the session's own records such as
earlier request snapshots. Images, caching and provider framing can change
the actual number. A host with an exact local count can supply
`input_token_counter: fn request -> {:ok, n} end`.

If a provider still refuses a request as too long, and has produced no
output yet, the session compacts once and sends the request again.

## How much room there is

Three things can say how big a model's window is:

1. a host's `:context_window` (`--context-window N` or `"context_window"` in
   `lmx`), which is an instruction and wins over the catalog;
2. the model catalog, or a provider refusal that states the window
   (`Lemieux.Provider.Error.stated_context_window/1`), which describe the
   model;
3. the window the serving endpoint reports after an answer
   (`{:context_window, tokens}` from a local Ollama daemon), which describes
   this server. It replaces a window from the catalog and caps one the host
   gave, because planning past what the server keeps loses the task without
   an error. A model change forgets it.

When nothing knows the window, compaction plans against
`context_window_fallback`: 128,000 tokens
(`Lemieux.Provider.fallback_context_window/0`) unless the host says
otherwise, and `nil` keeps automatic compaction off for such a model.

The session reports the window through three events:

- `{:context_window_unknown, %{model:, fallback:}}`: nothing knows the
  window, so compaction plans against `fallback`. Sent once per model, just
  before that model's first request and again after a model change, not at
  session start. A host that subscribes when it sends the first prompt hears
  it.
- `{:context_window_small, %{model:, window:, overhead:, source:}}`: the
  known window leaves less than 8,192 tokens beyond the session's own
  instructions and tool schemas (`overhead`, estimated). `source` says where
  the window came from: `:configured`, `:provider`, `:stated` by a refusal,
  or `:served`. Sent once per model and window. When the overhead alone is
  over the compaction threshold, threshold compaction is not tried: no
  summary could get under it.
- `{:compaction_ineffective, %{input_tokens:, threshold:, window:, retry_in:}}`:
  the request built right after an automatic compaction was still over the
  threshold, so the summary made no room. The threshold is not tried again
  for `retry_in` requests (32). Explicit compaction still works, and a new
  window or model starts over.

`lmx` reports all three: the terminal UI as notices, `lmx run` as lines on
standard error (`--output-format stream-json` as `notice` events). A local
model's window is set by the Ollama server, not by anything a request
carries; [Use a local model](providers.md#use-a-local-model) has the recipe.

## Choosing a cut

`keep_recent_tokens: n` keeps at most about `n` tokens of recent conversation
based on encoded bytes divided by four. This is an estimate. A safe user
boundary is preferred; if a single user span is too large, the default
strategy retains from an assistant message so that tool calls remain paired
with their results, and the request is led by a short synthetic user message
saying that what came before is summarised — never written to the transcript.
If no safe boundary exists, compaction does not cut. `keep: fraction` asks
for the entry-count rule instead. With neither, the shipped plan is handed
the capped window and keeps 30% of it, and never more than half of the
conversation, so every compaction cuts something. This is what lets one
prompt followed by a long run of tool calls compact: the count rule could only
cut at a later user message, and that session has none. When price bands are
configured and neither option is set, the target is 20,000 estimated tokens.

Between compactions, `stub_tool_results` replaces the output of old, large tool
results with a line saying what was there and that calling again recovers it.
The newest 40 results are always sent whole; older results over 4,096 bytes
are stubbed 20 at a time, so the stubbed set — and a cached prompt prefix —
changes once per batch rather than on every request. `stub_tool_results: false`
sends every result whole until compaction.

The summarizing request uses the same provider route and budgets. It can use
`summary_model: "provider:cheaper-model"` and `summary_params: [...]` while the
ordinary request retains its model. It asks for low reasoning effort where the
model offers one and 8,192 output tokens (at most 16,384 when the session sets
its own `max_tokens`); an explicit `summary_params` value wins either way. A
smaller cap was spent entirely on reasoning by a model thinking hard, so the
summary stopped at its length limit. The request ends on a user message
asking for the summary, so a conversation that ended on an assistant message
is summarised rather than continued, and for Anthropic models it is sent
without prompt caching, since its prefix is one no later request reads.
`summary_max_bytes` defaults to 32,768. A missing terminal event, length stop,
tool call, empty answer, or oversized answer cannot replace transcript
history. A transient provider failure is retried once; any other failure
leaves the conversation whole and holds the threshold off for a few requests,
a number that doubles with each consecutive failure. Old attachments are
projected according to `keep_attachments` before they reach the summarizer.

`lmx` accepts `"auto_compaction"` (`false` stops every automatic
compaction), `"keep_recent_tokens"`, `"summary_model"` and
`"compaction_price_tiers"` in `~/.lmx/config.json`.

## Structured summary sections

Set `summary_sections: true` to ask the summarizer to preserve `open work`,
`dependencies`, `decisions` and `verification debt`. `Lemieux.Compaction.sections/1`
reads those sections back. The compaction entry, subscriber event and harness
snapshot retain them, and the front ends can display the structured result.
The full transcript remains authoritative.

This is opt-in. Compare obligation retention and overhead on a paired workload
before selecting it as a host default. Structured headings alone do not verify
obligations or create a persistent work queue.

## A price cliff

Some models charge more per token once a request crosses a size boundary.
Pass `compaction_price_tiers` as a map keyed by the **resolved request model**.
Each ordered band specifies `up_to` input tokens (`nil` means infinity),
`input_per_million`, `output_per_million`, and optionally
`cached_input_per_million`, all in USD. Lemieux triggers only when the pending
request is projected to cross into a higher whole-request rate, the projected
post-compaction request enters a cheaper band, and one request's estimated
savings exceeds the estimated summarizing cost plus
`compaction_minimum_savings_usd`. `compaction_expected_output_tokens` defaults
to zero; the summary projection reserves 4,096 output tokens. Unknown model
prices never count as free.

For example, [Google's standard Gemini 3.1 Pro Preview price table](https://ai.google.dev/gemini-api/docs/pricing)
currently lists a 200,000-token boundary. A direct, standard paid route could
configure:

```elixir
compaction_price_tiers: %{
  "google:gemini-3.1-pro-preview" => [
    %{up_to: 200_000, input_per_million: 2.0, output_per_million: 12.0,
      cached_input_per_million: 0.20},
    %{up_to: nil, input_per_million: 4.0, output_per_million: 18.0,
      cached_input_per_million: 0.40}
  ]
}
```

The host owns this tariff. Batch, Flex, gateways, discounts, and later price
changes may differ. Do not attach direct-provider rates to an `ixway:` alias
unless Ixway has resolved and supplied the matching route economics. A
200,000-token threshold is not a general context-window limit; the model's
[input window is much larger](https://ai.google.dev/gemini-api/docs/models/gemini-3.1-pro-preview).

In `lmx`, use the same bands with JSON string keys in `~/.lmx/config.json`:

```json
{
  "compaction_price_tiers": {
    "google:gemini-3.1-pro-preview": [
      {"up_to": 200000, "input_per_million": 2.0, "output_per_million": 12.0,
       "cached_input_per_million": 0.2},
      {"up_to": null, "input_per_million": 4.0, "output_per_million": 18.0,
       "cached_input_per_million": 0.4}
    ]
  }
}
```

The config loader rejects malformed or unordered bands before starting a
session. When a cheaper summary model is configured, include its prices too
if price-aware compaction should calculate a net saving.

`{:compaction_planned, %{trigger: :price, forecast: economics}}` exposes the
decision and projected savings. The persisted `:compaction` entry and
`{:compacted, %{usage: usage}}` expose the summarizing request's **actual**
provider-reported usage and cost. Failed paid summaries also persist their
usage on an error entry. The ordinary request's later usage is separate; no
forecast is presented as realized savings.

### Bands come from the host

Lemieux does not derive price bands from the model catalog. The catalog's
`model.cost` is a flat base rate, and the catalog Lemieux is locked to does
not supply a complete, consistently applicable price curve for every model,
so a price cliff cannot be read from it, from a context-window size or from
a model name. Pass `compaction_price_tiers` yourself.
`Lemieux.Compaction.Price` says where a catalog tariff would plug in once one
exists.

The catalog is a packaged snapshot, not live provider pricing. Check your
bands against the provider's published tariff when you set or update them,
and reconcile modeled cost with the provider's usage reports and invoices; a
discrepancy is not evidence of savings.

## Optional Jev projection before compaction

The installed `lmx` bundles one more step that runs before compaction: the
[Jev compaction extension](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/jev_compaction/README.md)
(`LemieuxJevCompaction`). It asks TypeSafe's Jev model whether old, long
`read` results are still needed, and shortens the ones it marks as not needed
in the next request sent to the model. The transcript keeps the full output.
It runs as a `prepare_next_turn` hook, before the window and price checks
above, so a successful projection may avoid a summary on the pending request;
if it saves too little or Jev is unavailable, the ordinary summary logic still
applies.

The extension lives in `dist/lmx/extensions/jev_compaction` and is part of
the `lmx` release, not of the library: the `lemieux` package does not depend
on it, and an embedding host that wants it adds that directory as a path
dependency and assembles `LemieuxJevCompaction` with its harness, or installs
its `hook/1` directly.

### When it sends something

Nothing is sent until a route is complete. `"jev_compaction"`'s `mode`
defaults to `"auto"`, which switches the extension on, with no other setting,
as soon as either route is complete:

- **TypeSafe**, the usual one: a Jev key, from `JEV_API_KEY` in the
  environment `lmx` runs in or `jev_compaction.api_key` in
  `~/.lmx/config.json`. The environment value wins.
- **Ixway**: an Ixway endpoint (`jev_compaction.endpoint`, or the one `lmx`
  is routed through: `--ixway`, `LMX_IXWAY_URL` or `ixway.endpoint`), a pinned
  `jev_compaction.model` and an Ixway key (`IXWAY_API_KEY` or
  `ixway.api_key`). The request then goes to that endpoint, never to
  TypeSafe.

The installed `lmx` never reads a working directory's `.env`, so a repository
you open cannot supply a key or an endpoint.

Once on, the extension makes an evaluation before a model request only when
all of these hold:

- the request holds successful `read` results of at least 1,000 characters
  that are older than its six most recent entries, and are not `AGENTS.md`
  or `SKILL.md`;
- there are at most 20 such results;
- the session has made fewer than three evaluations;
- the request is not a retry, and has not been evaluated before.

Each evaluation is one HTTPS request: on the TypeSafe route,
`POST https://api.typesafe.ai/v1/systemone`, with the key as a bearer token,
no retries, no redirects and a 15-second timeout. Its body, capped at 60 KB
(a larger one is not sent), holds:

- the model name (`jev-1.13.0` unless configured) and a fixed instruction;
- the text of every user and assistant message in the request, each one over
  500 bytes cut to its first and last 250 characters, with the last three
  user messages repeated as the goal;
- the summary of earlier conversation, cut the same way, if a compaction
  wrote one;
- for each candidate result: the tool name, the call's arguments as JSON (at
  most 500 characters, typically a file path) and the result's length.

It does **not** send tool results: nothing a tool read or printed. But
message text and the earlier summary are sent, abridged as above, and can
quote files, code or anything pasted into the conversation. Nothing else from
the system prompt is sent, and no credential other than the key that
authenticates the request.

A result Jev scores below `keep_threshold` (0.1) is replaced, in the outgoing
request only, by its first 160 characters and a note telling the model to
run the tool again if it needs the exact contents. Calls and results stay
paired; writes, errors and recent results are never shortened. The
transcript records each evaluation in the extension's own entry: the entry
IDs, output digests, scores, estimated savings, token usage and latency, but
no tool output or credential.

TypeSafe bills each evaluation, and the known cost counts toward the
session's dollar budget (`--max-cost-usd`) across resume and fork.

### Turning it off

Any of these keeps it from sending anything:

- `"jev_compaction": {"mode": "off"}` in `~/.lmx/config.json`;
- `"disabled_extensions": ["jev_compaction"]`;
- leaving both routes incomplete: no `JEV_API_KEY` or
  `jev_compaction.api_key`, and no pinned model for an Ixway endpoint.

`"shadow"` mode still sends the same data, to score results, but never
shortens anything. `"apply"` and `"shadow"` require a usable route: without
one, the session does not start.

### Settings

`"jev_compaction"` takes `mode` (`auto`, `apply`, `shadow` or `off`),
`route` (`auto`, `typesafe` or `ixway`), `model`, `endpoint`, `api_key`,
`max_evaluations`, `max_cost_usd`, `reservation_per_call_usd`,
`input_per_million` and `output_per_million`.

To send the requests to an Ixway endpoint that implements
`POST /v1/systemone`, pin the model and give the endpoint and an Ixway key
(`IXWAY_API_KEY`, or `ixway.api_key` in your config file):

```json
{
  "ixway": {"enabled": false, "endpoint": "https://ixway.example"},
  "jev_compaction": {
    "mode": "apply",
    "route": "ixway",
    "model": "jev-local-1",
    "input_per_million": 0.04,
    "output_per_million": 0.0,
    "max_cost_usd": 0.05,
    "reservation_per_call_usd": 0.01
  }
}
```

The Jev route is independent of the ordinary inference route, so this
example keeps chat inference direct. `route: "auto"` chooses Ixway only when
an endpoint and a pinned Jev model are both configured, and TypeSafe
otherwise. The Ixway route uses the Ixway key, not the Jev key, and
`route: "ixway"` never falls back to TypeSafe after a failed or unavailable
Ixway route. An endpoint counts as configured before any network call; a
later HTTP failure leaves the outgoing model request unprojected. Ixway's
chat-completions endpoint is a different protocol and cannot stand in for
`POST /v1/systemone`.

Each call records its usage, its known USD cost (or `null` when the cost is
unknown) and its route in the session, so `Session.snapshot/1` includes the
spend and `max_cost_usd` accounts for it across resume and fork. A session
with a dollar cap needs `reservation_per_call_usd` before Jev will call the
endpoint; `jev_compaction.max_cost_usd` caps Jev's calls separately. Both
caps check the reservation before a call, and the reported token usage sets
the charge afterwards. An unpriced or failed attempt has unknown cost, not
zero. For an Ixway route, declare both rates from its tariff; the TypeSafe
route uses the extension's dated published rate unless you override it. The
byte-based trigger and reduction remain estimates, so measure task quality
and net cost on your own work before counting on savings.

In the terminal UI, `/compact` adds the last projection's **estimated**
tokens kept out of a model request when Jev is active, or says no projection
has been recorded. That is evidence about the request sent, separate from the
summary's token count and from billed savings.

`mode: "shadow"` records bounded keep scores and candidate savings without
changing the request, for measuring what the extension would have done. The
default keep threshold of 0.1 is deliberately conservative. The extension
also ships a
[paired evaluation command](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/jev_compaction/README.md#paired-jev-evaluation)
that compares unchanged history, shadow scores, Jev projection and ordinary
summarization on the same seeded reads. It makes paid model and Jev calls.

### From a source checkout

The repository root is the library project, which does not include the
extension. There, with no `jev_compaction` settings nothing happens, even
with `JEV_API_KEY` set; with any setting other than `"mode": "off"`, `lmx`
stops before the session starts and says where the extension lives. The
release host's project in `dist/lmx` includes it. Fetch its dependencies
once, then run `lmx` from there. The session works in the repository root,
not in `dist/lmx`; `-C ../..` says so explicitly, and `-C DIR` names any
other directory. That run reads no `.env`, so keep `JEV_API_KEY` in your
shell or in `~/.lmx/config.json`:

```sh
cd dist/lmx
mise exec -- mix deps.get
mise exec -- mix lmx -C ../..
```

## Optional host advice

Ixway or another host can send a short-lived timing signal while a turn runs:

```elixir
:ok = Lemieux.Session.advise_compaction(session, %{
  model: "ixway:resolved-route-id",
  reason: :cost,
  expires_at: DateTime.add(DateTime.utc_now(), 60, :second),
  scope: "ixway-route-version-42",
  keep_recent_tokens: 20_000
})
```

`reason: :logical` is also supported. The next prepared request must have the
same model and arrive before expiry. The signal is discarded on mismatch or
dispatch. It cannot interrupt an in-flight model or tool call, and no Ixway
dependency is required in Lemieux's core. Hosts with dynamic routing should
set `request.context["compaction_scope"]` in `prepare_next_turn` to the
resolved route version and issue a new signal when that version changes. The
optional scope must match the final prepared request for advice to apply.
