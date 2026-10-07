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

## Optional System One projection before compaction

The installed `lmx` bundles one more step that runs before compaction: the
[System One compaction extension](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md)
(`LemieuxSystemOneCompaction`). It asks a System One model — TypeSafe's
hosted Jev, an Ixway gateway, a vendor's decision API or an open model on
your own machine — whether old, long `read` results are still needed, and
shortens the ones it marks as not needed in the next request sent to the
model. The transcript keeps the full output. It runs as a
`prepare_next_turn` hook, before the window and price checks above, so a
successful projection may avoid a summary on the pending request; if it
saves too little or the scorer is unavailable, the ordinary summary logic
still applies.

The extension lives in `dist/lmx/extensions/systemone_compaction` and is
part of the `lmx` release, not of the library: the `lemieux` package does
not depend on it, and an embedding host that wants it adds that directory as
a path dependency and assembles `LemieuxSystemOneCompaction` with its
harness, or installs its `hook/1` directly.

Until this release the step was called Jev compaction, and its settings were
`"jev_compaction"`. That key is now refused at startup with a sentence
naming the new ones; see [Moving from Jev compaction](#moving-from-jev-compaction).

### Choosing a provider

Choosing a provider is separate from configuring one, the way `"web_search"`
and `"web_search_providers"` divide search. `"systemone_providers"` declares
each System One provider once, under a name of your choosing, with what it
needs; the list is shared by every feature that asks such a model, and each
feature picks its own from it. For this step, `"systemone_compaction"` holds
the choice and the budget:

```json
{
  "systemone_compaction": {"mode": "auto", "provider": "local"},
  "systemone_providers": {
    "local": {"base_url": "http://127.0.0.1:11434", "model": "clef-flash",
              "input_per_million": 0.0, "output_per_million": 0.0},
    "typesafe": {"api_key": "…"}
  }
}
```

`provider` names the one the evaluations go to. The computer-use and
research examples select theirs from the same list
([System One providers](configuration.md#system-one-providers)), so a small
local model can serve compaction while a stronger one picks browser actions.
Two are built in, and need an entry only to change what they default to:

- **`typesafe`**, TypeSafe's hosted service at `https://api.typesafe.ai`. Its
  key is `JEV_API_KEY` in the environment `lmx` runs in, or the entry's
  `api_key`; the environment wins, and an empty `JEV_API_KEY` switches the
  saved key off. It alone has a default model (`jev-1.13.0`, TypeSafe's Jev)
  and published rates.
- **`ixway`**, an Ixway gateway that implements `POST /v1/systemone`. Its
  endpoint is the entry's `base_url`, or the Ixway route `lmx` uses
  (`--ixway`, `LMX_IXWAY_URL` or `ixway.endpoint`); its model is the entry's
  `model`; its key is the Ixway key (`IXWAY_API_KEY` or `ixway.api_key`),
  which stays in the `ixway` section beside the gateway it opens.

Any other name is a provider you declare ([Declaring a
provider](#declaring-a-provider)): a service that implements
`POST /v1/systemone`, which can be a model on your own machine, keeping the
excerpts described below off anyone else's servers.

With no `provider` (or `"provider": "auto"`), `lmx` chooses between the two
built-in ones: Ixway when its endpoint and a model are both set, TypeSafe
when its key is. A declared provider is never chosen that way: its entry
switches nothing on and sends nothing until `provider` names it, so it can
sit in the file before you want it. There is no fallback from one provider
to another.

`"mode"` defaults to `"auto"`, which switches the step on, with no other
setting, as soon as the selected provider is complete, and leaves it off
when it is not. `"apply"` and `"shadow"` require a complete provider: without
one the session does not start, and the sentence names the missing piece.

The provider is chosen in the file alone; there is no flag or `LMX_`
variable for it, since where the excerpts go belongs beside the credentials
it needs. The installed `lmx` never reads a working directory's `.env`, so a
repository you open cannot supply a key or an endpoint.

### When it sends something

Once on, the extension makes an evaluation before a model request only when
all of these hold:

- the request holds successful `read` results of at least 1,000 characters
  that are older than its six most recent entries, and are not `AGENTS.md`
  or `SKILL.md`;
- there are at most 20 such results;
- the session has made fewer than three evaluations;
- the request is not a retry, and has not been evaluated before.

Each evaluation is one HTTP request, `POST /v1/systemone` under the selected
provider's URL, with the provider's key as a bearer token (or in its
`api_key_header`) if it has one, no retries, no redirects and a 15-second
timeout. Its body, capped at 60 KB (a larger one is not sent), holds:

- the model name and a fixed instruction;
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

A result the scorer scores below `keep_threshold` (0.1) is replaced, in the
outgoing request only, by its first 160 characters and a note telling the
model to run the tool again if it needs the exact contents. Calls and
results stay paired; writes, errors and recent results are never shortened.
The transcript records each evaluation in the extension's own entry (the
`systemone_compaction` namespace): the entry IDs, output digests, scores,
estimated savings, token usage and latency, but no tool output or
credential.

The provider bills each evaluation at its tariff, and the known cost counts
toward the session's dollar budget (`--max-cost-usd`) across resume and fork.

### Turning it off

Any of these keeps it from sending anything:

- `"systemone_compaction": {"mode": "off"}` in `~/.lmx/config.json`;
- `"disabled_extensions": ["systemone_compaction"]`;
- leaving the selected provider incomplete: no TypeSafe key, no model for
  an Ixway endpoint, and no `provider` naming a declared one.

`"shadow"` mode still sends the same data, to score results, but never
shortens anything.

### Declaring a provider

An entry under any name other than `typesafe` and `ixway` declares a
provider, and the name selects it:

```json
{
  "systemone_compaction": {"provider": "local"},
  "systemone_providers": {
    "local": {"base_url": "http://127.0.0.1:8080", "model": "local-scorer-1"}
  }
}
```

With this, the evaluations go to `POST http://127.0.0.1:8080/v1/systemone`
and nowhere else: no TypeSafe or Ixway key is needed, and nothing reaches
TypeSafe or Ixway. Each kind of entry takes:

| Key | Declared provider | `typesafe` | `ixway` |
| --- | --- | --- | --- |
| `base_url` | Required. The root before `/v1/systemone`: an `http(s)` URL, a path prefix allowed, with no credentials, query or fragment | fixed | the gateway's origin (no path, as `ixway.endpoint`), if not the Ixway route `lmx` uses |
| `model` | Required. The model to ask | default `jev-1.13.0` | required |
| `api_key` | A key, if the service wants one; the file must then be readable only by you | the TypeSafe key; `JEV_API_KEY` wins | refused: the key is `IXWAY_API_KEY` or `ixway.api_key` |
| `api_key_env` | The name of an environment variable holding the key instead. When the variable is set it wins over `api_key`, and an empty value switches the saved key off; when it is unset and there is no `api_key`, the provider is incomplete rather than unauthenticated | — | — |
| `api_key_header` | The header the key travels in, for a service that does not take a bearer token (`X-API-Key`, say); without it the key is sent as `Authorization: Bearer` | — | — |
| `headers` | Extra request headers, as an object of names to one-line values. `Authorization` is refused, and a key does not belong here: `api_key` and `api_key_env` are the fields `lmx` keeps private (the file must be yours alone, and an empty value is a named placeholder), and `api_key_header` puts the key in whatever header the service wants | — | — |
| `input_per_million`, `output_per_million` | The tariff in USD per million tokens, both or neither | overrides the published rates | the gateway's tariff |
| `type` | `endpoint`, the only kind so far | — | — |

An open decision model served on your own machine is the shortest entry of
all. Ollama 0.35 and later serves System One models on the same
`POST /v1/systemone` path as its chat models, so with Bespoke Labs' Nimble
or Cloudflare's Clef pulled (`ollama pull nimble`, `ollama pull clef-flash`;
both Apache-2.0), this is the whole configuration:

```json
{
  "systemone_compaction": {"provider": "ollama", "reservation_per_call_usd": 0.001},
  "systemone_providers": {
    "ollama": {
      "base_url": "http://127.0.0.1:11434",
      "model": "clef-flash",
      "input_per_million": 0.0,
      "output_per_million": 0.0
    }
  }
}
```

The zero tariff says what a local model costs, so a session with a dollar
cap still runs the step; the reservation is what a capped session asks for
before any call, and a local one is held to the same rule. Any other server
that implements the protocol — Laya ships one — takes the same entry with
its URL and model name. The extension's suite has a live check for exactly
this ([Checking it](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md#checking-it)).

A vendor's hosted decision API fits the same entry, with the key kept in
your shell:

```json
{
  "systemone_compaction": {"provider": "vendor"},
  "systemone_providers": {
    "vendor": {
      "base_url": "https://decisions.vendor.example/accounts/ACCOUNT_ID",
      "api_key_env": "VENDOR_API_KEY",
      "model": "decision-1",
      "input_per_million": 0.05,
      "output_per_million": 0.0
    }
  }
}
```

To score through an Ixway gateway instead, give its entry a model (and a
`base_url` unless `lmx` already routes through that gateway), with the Ixway
key in the `ixway` section or `IXWAY_API_KEY`:

```json
{
  "ixway": {"enabled": false, "endpoint": "https://ixway.example"},
  "systemone_compaction": {
    "mode": "apply",
    "provider": "ixway",
    "max_cost_usd": 0.05,
    "reservation_per_call_usd": 0.01
  },
  "systemone_providers": {
    "ixway": {"model": "gateway-scorer-1", "input_per_million": 0.04, "output_per_million": 0.0}
  }
}
```

The scorer's provider is independent of the ordinary inference route, so
this example keeps chat inference direct. An endpoint counts as configured
before any network call; a later HTTP failure leaves the outgoing model
request unprojected. Ixway's chat-completions endpoint is a different
protocol and cannot stand in for `POST /v1/systemone`.

### Settings and cost

`"systemone_compaction"` takes `mode` (`auto`, `apply`, `shadow` or `off`),
`provider` (`auto`, `typesafe`, `ixway` or a declared name),
`max_evaluations`, `max_cost_usd` and `reservation_per_call_usd`. Everything
about a provider — its address, key, model and tariff — is in its entry.

Only TypeSafe has a default model and published rates. Every other provider
is unpriced until its entry declares both rates, so a session with a dollar
cap (`--max-cost-usd`, or `systemone_compaction.max_cost_usd`) makes no
evaluation through it: the step fails closed rather than paying an unknown
price. `lmx explain` reports the mode and the selected provider's name under
`diagnostics.systemone_compaction`, and nothing else about it.

Each call records its usage, its known USD cost (or `null` when the cost is
unknown) and its provider (under the record's `route` key) in the session,
so `Session.snapshot/1` includes the spend and `max_cost_usd` accounts for
it across resume and fork. A session with a dollar cap needs
`reservation_per_call_usd` before the scorer is called;
`systemone_compaction.max_cost_usd` caps the scorer's calls separately. Both
caps check the reservation before a call, and the reported token usage sets
the charge afterwards. An unpriced or failed attempt has unknown cost, not
zero. TypeSafe uses the extension's dated published rate unless its entry
overrides it. The byte-based trigger and reduction remain estimates, so
measure task quality and net cost on your own work before counting on
savings.

In the terminal UI, `/compact` adds the last projection's **estimated**
tokens kept out of a model request when the step is active, or says no
projection has been recorded. That is evidence about the request sent,
separate from the summary's token count and from billed savings.

`mode: "shadow"` records bounded keep scores and candidate savings without
changing the request, for measuring what the extension would have done. The
default keep threshold of 0.1 is deliberately conservative. The extension
also ships a
[paired evaluation command](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md#paired-evaluation)
that compares unchanged history, shadow scores, projection and ordinary
summarization on the same seeded reads. It makes paid model and TypeSafe
calls.

### Moving from Jev compaction

The old settings map onto the new ones like this:

| Was | Now |
| --- | --- |
| `jev_compaction.mode`, `.max_evaluations`, `.max_cost_usd`, `.reservation_per_call_usd` | the same fields under `systemone_compaction` |
| `jev_compaction.route` or `.provider` | `systemone_compaction.provider` |
| `jev_compaction.api_key` | `systemone_providers.typesafe.api_key` |
| `jev_compaction.endpoint` | `systemone_providers.ixway.base_url` |
| `jev_compaction.model` | `model` in the selected provider's entry |
| `jev_compaction.input_per_million`, `.output_per_million` | the same fields in the selected provider's entry |
| `jev_compaction_providers.NAME` | `systemone_providers.NAME` |
| `"disabled_extensions": ["jev_compaction"]` | `"disabled_extensions": ["systemone_compaction"]` |

Under the old automatic choice, a `jev_compaction.model` beside an Ixway
endpoint selected Ixway. To keep that choice, put the model in the `ixway`
entry (or set `"provider": "ixway"`); a model put in the `typesafe` entry
instead would send the excerpts to TypeSafe.

`JEV_API_KEY` is unchanged: it is TypeSafe's name for its key. A session
recorded before the rename kept its decisions under the `jev_compaction`
namespace, which the renamed extension does not replay: resuming one sends
its old reads in full again until a new evaluation shortens them, and the
step's own count of evaluations and its `max_cost_usd` start again for that
session. The session's dollar cap is unaffected, since it counts every
recorded charge.

### From a source checkout

The repository root is the library project, which does not include the
extension. There, with no `systemone_compaction` settings nothing happens,
even with `JEV_API_KEY` set; with any setting other than `"mode": "off"`,
`lmx` stops before the session starts and says where the extension lives.
The release host's project in `dist/lmx` includes it. Fetch its dependencies
once, then run `lmx` from there. The session works in the repository root,
not in `dist/lmx`; `-C ../..` says so explicitly, and `-C DIR` names any
other directory. That run reads no `.env`, so keep keys in your shell or in
`~/.lmx/config.json`:

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
