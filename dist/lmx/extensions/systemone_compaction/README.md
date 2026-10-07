# System One compaction

`LemieuxSystemOneCompaction` is a Lemieux extension that asks a System One
model whether old, long `read` results in a conversation are still needed,
and shortens the ones it marks as no longer needed in the next request sent
to the model. The full output stays in the transcript; only the outgoing
request is shortened. It adapts the selective idea in
[fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) to
Lemieux's append-only transcript.

A System One model answers typed questions about a state with calibrated
probabilities over `POST /v1/systemone`, rather than generating text.
TypeSafe's hosted Jev is one; Cloudflare's Clef, Bespoke Labs' Nimble and
Laya are open ones you can run yourself. The extension works with any of
them. It was called Jev compaction (`LemieuxJevCompaction`) until it could.

**lmx bundles it.** The installed `lmx` binary includes this extension, and so
does a source run through the release host, which has dependencies of its own
to fetch first:
`cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`.
The Lemieux library itself does not depend on it: an embedding host that wants
it adds this directory as a path dependency and assembles the extension with
its harness.

## When it runs, and what it sends

It sends nothing until it is given a provider. In `lmx`,
`"systemone_compaction"` holds the choice (`provider`), the `mode` and the
budget, and `"systemone_compaction_providers"` holds what each provider
needs. `mode` defaults to `"auto"`, which switches the extension on, with no
other setting, as soon as the selected provider is complete. Two providers
are built in:

- **`typesafe`**, TypeSafe's hosted service: a key from `JEV_API_KEY` in the
  environment `lmx` runs in, or `systemone_compaction_providers.typesafe.api_key`
  in `~/.lmx/config.json`;
- **`ixway`**, an Ixway gateway: an endpoint (the entry's `base_url`, or the
  route `lmx` uses: `--ixway`, `LMX_IXWAY_URL` or `ixway.endpoint`), the
  entry's `model` and the Ixway key (`IXWAY_API_KEY` or `ixway.api_key`). The
  request then goes to that endpoint, and never to TypeSafe.

Any other name is a provider declared in `systemone_compaction_providers`: a
`base_url` that implements `POST /v1/systemone`, with an optional key, extra
headers, a model and a tariff — an open model on your own machine, or a
vendor's decision API. A declared provider is never selected by default and
receives nothing until `provider` names it; see [Providers](#providers) and
[Declaring a provider](../../../../docs/compaction.md#declaring-a-provider).

The installed `lmx` never reads a working directory's `.env`, so a repository
you open cannot supply a key or an endpoint. Nor does the source run through
the release host, which shares that configuration (`dist/lmx/config/config.exs`):
give it keys in its environment or in `~/.lmx/config.json`.

Once on, it makes an evaluation before a model request only when all of this
holds: the request contains successful `read` results of at least 1,000
characters that are older than the request's six most recent entries (and
are not `AGENTS.md` or `SKILL.md`); there are at most 20 such results; the
session has made fewer than three evaluations; the request is not a retry;
and the same request has not been evaluated before. Each evaluation is one
HTTP request, `POST /v1/systemone` under the selected provider's URL, with
the provider's key as a bearer token (or in its `api_key_header`) if it has
one, no retries, no redirects and a 15-second timeout. Its body, capped at
60 KB (a larger one is not sent), holds:

- the model name;
- a fixed instruction describing the task;
- the text of every user and assistant message in the request, each longer
  than 500 bytes cut to its first and last 250 characters, with the last three
  user messages repeated as the goal;
- the summary of earlier conversation, cut the same way, if an earlier
  compaction wrote one;
- for each candidate result: the tool name, the call's arguments as JSON (at
  most 500 characters, typically a file path) and the result's length.

It does **not** send tool results: nothing a tool read or printed, only each
candidate result's length. Message text and the earlier summary are sent
abridged as above, and can themselves quote files, code or anything else
pasted into the conversation. Nothing else from the system prompt is sent,
and no credential other than the key that authenticates the request. The
model answers with a keep probability per candidate. A result scored below
`keep_threshold` (default 0.1) is replaced, in the outgoing request only, by
its first 160 characters and a note telling the model to rerun the tool if it
needs the exact contents. Calls and results stay paired; writes, errors and
recent results are never shortened.

The session's transcript records each evaluation in the extension's document,
under the `systemone_compaction` namespace: the selected entry IDs, output
digests, keep probabilities, estimated token savings, the SDK's token usage
and latency. No tool output or credential is stored there. Up to eight
evaluations and twenty candidates per evaluation are kept.

The provider bills each evaluation. The known cost counts toward the
session's dollar budget (`--max-cost-usd`) and across resume; TypeSafe's own
service uses its published $0.042 per million input tokens and zero output
rate as of 2026-09-22, which operators should update when pricing changes,
and every other provider is unpriced until its tariff is declared. An
evaluation whose cost cannot be priced makes the session's spend unknown,
and a session with a dollar limit then refuses its next request. The
evaluation's tokens do not count toward the conversation's context window.

## Turning it off, or down

Any of these keeps it from sending anything:

- `"systemone_compaction": {"mode": "off"}` in `~/.lmx/config.json`;
- `"disabled_extensions": ["systemone_compaction"]` in `~/.lmx/config.json`;
- leaving the selected provider incomplete: no TypeSafe key, no model for an
  Ixway endpoint, and no `provider` naming a declared one.

The other modes are `"apply"`, which requires a complete provider and fails
to start without one, and `"shadow"`, which still sends the same data to score
results but never shortens anything, for measuring what it would have done.
`max_evaluations`, `max_cost_usd` and `reservation_per_call_usd` bound the
calls, and a provider's entry prices them; see
[Compaction](../../../../docs/compaction.md#optional-system-one-projection-before-compaction).

## Providers

The extension sends to exactly one System One provider, described by the
`provider:` option:

```elixir
%{
  name: "local",                        # what usage records and lmx explain call it
  type: :endpoint,                      # :typesafe for TypeSafe's service, :endpoint for any other
  base_url: "http://127.0.0.1:11434",   # the root before /v1/systemone; a path prefix is kept
  api_key: nil,                         # the key, or nil for a service that wants none
  api_key_header: nil,                  # the header the key travels in; nil means Authorization: Bearer
  headers: %{"X-Scorer-Tenant" => "a"}, # extra request headers
  model: "clef-flash"                   # the model to ask; nil only for TypeSafe, whose default is jev-1.13.0
}
```

`type: :typesafe` is reached through `SystemOneSDK.Providers.TypeSafe` and
carries TypeSafe's published rates. `type: :endpoint` is reached through
`SystemOneSDK.Providers.Endpoint`, the SDK's generic `POST /v1/systemone`
client: an Ixway gateway, a vendor's decision API and an open model on the
person's own machine are all this kind, and none is priced until
`input_per_million` and `output_per_million` are given, so a capped session
makes no evaluation through an unpriced one. `type: :typesafe` is priced as
TypeSafe whatever its `base_url` says, so a proxy you price yourself is an
`:endpoint`. `lmx` builds the map from `systemone_compaction` and
`systemone_compaction_providers` in its config file
(`Lemieux.CLI.SystemOneCompaction`). A selected provider never falls back to
another on missing credentials or HTTP failure; the request stays as it was.

A host may instead inject its own `%SystemOneSDK.Client{}` with `client:`.
Those are the only two forms: the extension reads no environment variable,
so where a key comes from is the host's decision. Ixway's chat-completions
endpoint is a different protocol and cannot stand in for
`POST /v1/systemone`.

## Using it from a host

```elixir
# For any endpoint implementing POST /v1/systemone — here an open model that
# Ollama serves on the host's own machine, with no key and a zero tariff:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxSystemOneCompaction,
   provider: %{
     name: "local",
     type: :endpoint,
     base_url: "http://127.0.0.1:11434",
     api_key: nil,
     api_key_header: nil,
     headers: %{},
     model: "clef-flash"
   },
   input_per_million: 0.0,
   output_per_million: 0.0}
])

# For TypeSafe's hosted service:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxSystemOneCompaction,
   provider: %{
     name: "typesafe",
     type: :typesafe,
     base_url: "https://api.typesafe.ai",
     api_key: System.fetch_env!("JEV_API_KEY"),
     api_key_header: nil,
     headers: %{},
     model: nil
   }}
])

# With a client the host built itself:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxSystemOneCompaction, client: client}
])

# Pass harness: harness to start_session/1 or resume_session/1.
```

As a library extension the default is `enabled: :auto` (on when a provider or
client is usable) and `mode: :apply`. Pass `enabled: false` to disable it
explicitly, or install `LemieuxSystemOneCompaction.hook/1` directly as a
`prepare_next_turn` hook. Assemble it after other request-rewriting hooks.

`activation_tokens` defaults to 1 and is based on Lemieux's encoded-byte / 4
estimate, not the provider's exact tokenizer, and a projection applies whenever
it saves at least one estimated token, so savings can come before any context
or price threshold. Set a higher activation or minimum saving for a provider
whose cost per evaluation exceeds the expected uncached input saving. The hook
runs before the usual window and price checks, so a successful elision can
reduce the pending request immediately; if it cannot save enough, the ordinary
summary compaction remains available. It does not change `compact_at` or
trigger compaction itself. A resumed or forked session reapplies recorded
elisions when the host installs the hook again; a session recorded under the
old `jev_compaction` namespace is not replayed, so its old reads go out in
full until a new evaluation shortens them, and the extension's own
evaluation count and `max_cost_usd` start again for it (the session's
dollar cap still counts every recorded charge). A capped host must set
`reservation_per_call_usd` to permit the SDK call; set `max_cost_usd` for an
additional per-session cap on the scorer and declare `input_per_million` and
`output_per_million` for every provider but TypeSafe's own service. Shadow
mode never replays earlier elisions, even if a host changes mode in the same
session. Shadow scores support offline threshold sweeps; they are not
evidence that a model continuation will remain correct after shortening, so
tune the threshold with real transcript evaluations before widening
`eligible_tools`. There is no claim of net dollar savings without measured
route prices and live task-quality evaluation.

## Paired evaluation

`LemieuxSystemOneCompaction.Trial` replays the same scripted `read` history
into four continuation arms: unchanged history (`baseline`), scoring without
projection (`shadow`), projection (`projection`), and forced ordinary summary
compaction (`summary`). Each arm gets fresh local files and an independent
session. The scoring arms use TypeSafe's hosted provider unless the caller
supplies an SDK client. The summary arm uses a 40K window with a 10% trigger
to exercise the summarizer; it is a mechanism comparison, not a claim about a
host's production compaction settings. The runner rotates arm order by case
and repetition to expose cache-warming effects.

The local command loads credentials from the checkout's ignored root `.env`
and requires an upfront dollar reservation for every run. A missing usage
record stops the batch with unknown cost. Prompts, file contents, model
answers and keys never enter the report; only case IDs, exact-answer verdicts,
bounded scores, latency and usage are written to the ignored `tmp/`
directory. It makes paid model and TypeSafe calls. For example:

```sh
cd dist/lmx/extensions/systemone_compaction
LMX_CONFIG=none mise exec -- mix run scripts/systemone_compaction_eval.exs \
  --model openai:gpt-5-mini \
  --tariff eval/v1/openai_gpt_5_mini_2026_09_22.json \
  --repetitions 4 --cost-cap 1.0 --reservation-per-run 0.05
```

For an end-to-end Luna session with the extension's normal selection bounds,
use `--model openai:gpt-5.6-luna --production-defaults` and the matching Luna
tariff and corpus. The standalone
[live report](eval/v1/results/standalone_luna_production_defaults_2026_09_22.json)
records whether the extension attached and whether the seeded outputs remained
unchanged in the transcript. The reports in `eval/v1/results` predate the
rename and are kept as recorded: they call the projection arm `jev` and the
attachment flag `jev_extension_attached`.

`--arms baseline,shadow,projection,summary`, `--threshold 0.1`, `--corpus`
and `--output` can narrow a run. `--production-defaults` keeps the
extension's normal recency, result-size and attempt bounds; without it, the
trial lowers those bounds to score the fixture's short histories. The
included corpus is synthetic and uses exact answer grading. `score_sweep`
reuses shadow scores at several thresholds without another SDK call; its
`false_elisions` count is based on fixture labels, so only the paired
continuations check answer quality. `pair_comparisons` prices every provider
request and scorer call in each matched case, including summary calls and
later turns. A tariff is a dated estimate; compare
`provider_reported_cost_usd` with `provider_cost_usd` and invoices before
claiming billed savings. Recheck the linked provider tariffs before each new
run. The reservation is checked before the batch and known cost after each
arm; an in-flight request can exceed its reservation. In particular, a
shortened prompt can lose a discounted cache prefix.

The default 0.1 keep threshold remains conservative. Repeated paired cases
should refine it, including ordinary compaction and prompt-cache effects.
Compaction generally changes the cache prefix, so the extension applies by
default where a provider is configured; a host can use shadow mode where its
own workload shows a regression. Correctness and billed savings still require
host-specific validation. Retain new reports in an ignored `tmp/` directory or
a host-owned artifact store.

## Checking it

It is its own Mix project. From this directory, against this checkout:

```sh
LEMIEUX_EXTENSION_BASE="$PWD/../../../.." mise exec -- mix deps.get
LEMIEUX_EXTENSION_BASE="$PWD/../../../.." mise exec -- mix check
```

`mix check` formats, compiles with warnings as errors and runs the tests,
which make no network calls.

One more test runs only when you name a System One server on your own
machine, and scores a fixture through it over the real wire — the check
that a local open model is a provider like any other. Ollama 0.35 and later
serves Bespoke Labs' Nimble and Cloudflare's Clef on `/v1/systemone`:

```sh
ollama pull clef-flash
LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:11434 LOCAL_SYSTEM_ONE_MODEL=clef-flash \
  LEMIEUX_EXTENSION_BASE="$PWD/../../../.." mise exec -- mix test test/systemone_compaction/local_server_test.exs
```

It prints the model's keep probability and whether it shortened the read;
`LOCAL_SYSTEM_ONE_KEY` supplies a bearer token for a server that wants one.
Nimble and Clef-flash both passed it on 2026-10-06 and again after the
rename on 2026-10-07.
