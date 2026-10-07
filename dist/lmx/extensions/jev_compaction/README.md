# Jev compaction

`LemieuxJevCompaction` is a Lemieux extension that asks a System One scorer
— TypeSafe's Jev model, unless the host selects another provider — whether
old, long `read` results in a conversation are still needed, and shortens the
ones it marks as no longer needed in the next request sent to the model. The full output stays in the transcript; only the outgoing request is
shortened. It adapts the selective idea in
[fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction) to
Lemieux's append-only transcript.

**lmx bundles it.** The installed `lmx` binary includes this extension, and so
does a source run through the release host, which has dependencies of its own
to fetch first:
`cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx -C ../..`.
The Lemieux library itself does not depend on it: an embedding host that wants
it adds this directory as a path dependency and assembles the extension with
its harness.

## When it runs, and what it sends

It sends nothing until it is given a provider. In `lmx`, the `jev_compaction`
setting's `mode` defaults to `"auto"`, which switches the extension on, with
no other setting, as soon as the selected provider is complete.
`jev_compaction.provider` selects it; two are built in:

- **TypeSafe**, the usual one: a Jev key, from `JEV_API_KEY` in the
  environment `lmx` runs in or `jev_compaction.api_key` saved in
  `~/.lmx/config.json`;
- **Ixway**: an Ixway endpoint (`jev_compaction.endpoint`, or the one `lmx`
  is routed through: `--ixway`, `LMX_IXWAY_URL` or the `ixway` section's
  `endpoint`), a pinned Jev model (`jev_compaction.model`) and an Ixway key
  (`IXWAY_API_KEY` or `ixway.api_key`). The same request then goes to that
  endpoint instead of TypeSafe, and never to TypeSafe.

Any other name is a provider declared in `jev_compaction_providers`: a
`base_url` that implements `POST /v1/systemone`, with an optional key, extra
headers, a default model and a tariff — a vendor's decision API, or a scorer
on a machine the person controls. A declared provider is never selected by
default and receives nothing until `provider` names it; see
[Providers](#providers) and
[Declaring a provider](../../../../docs/compaction.md#declaring-a-provider).

The installed `lmx` never reads a working directory's `.env`, so a repository
you open cannot supply a key or an endpoint. Nor does the source run through
the release host, which shares that configuration (`dist/lmx/config/config.exs`):
give it `JEV_API_KEY` in its environment or `jev_compaction.api_key` in
`~/.lmx/config.json`.

Once on, it makes an evaluation before a model request only when all of this
holds: the request contains successful `read` results of at least 1,000
characters that are older than the request's six most recent entries (and
are not `AGENTS.md` or `SKILL.md`); there are at most 20 such results; the
session has made fewer than three Jev evaluations; the request is not a
retry; and the same request has not been evaluated before. Each evaluation is
one HTTP request, `POST /v1/systemone` under the selected provider's URL
(`https://api.typesafe.ai` for TypeSafe), with the provider's key as a
bearer token if it has one, no retries, no redirects and a 15-second
timeout. Its body, capped at 60 KB (a larger one is not sent),
holds:

- the model name (`jev-1.13.0` unless configured);
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
and no credential other than the key that authenticates the request. Jev
answers with a keep probability per candidate. A result scored below
`keep_threshold` (default 0.1) is replaced, in the outgoing request only, by
its first 160 characters and a note telling the model to rerun the tool if it
needs the exact contents. Calls and results stay paired; writes, errors and
recent results are never shortened.

The session's transcript records each evaluation in the extension's document:
the selected entry IDs, output digests, keep probabilities, estimated token
savings, the SDK's token usage and latency. No tool output or credential is
stored there. Up to eight evaluations and twenty candidates per evaluation
are kept.

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

- `"jev_compaction": {"mode": "off"}` in `~/.lmx/config.json`;
- `"disabled_extensions": ["jev_compaction"]` in `~/.lmx/config.json`;
- leaving the selected provider incomplete: no `JEV_API_KEY` or
  `jev_compaction.api_key` for TypeSafe, no pinned `jev_compaction.model`
  for an Ixway endpoint, and no `provider` naming a declared one.

The other modes are `"apply"`, which requires a complete provider and fails
to start without one, and `"shadow"`, which still sends the same data to score
results but never shortens anything, for measuring what it would have done.
`max_evaluations`, `max_cost_usd`, `reservation_per_call_usd`,
`input_per_million` and `output_per_million` bound and price the calls; see
[Compaction](../../../../docs/compaction.md#optional-jev-projection-before-compaction).

## Providers

The extension sends to exactly one System One provider, described by the
`provider:` option:

```elixir
%{
  name: "local",                        # what usage records and lmx explain call it
  type: :endpoint,                      # :typesafe for TypeSafe's service, :endpoint for any other
  base_url: "http://127.0.0.1:8080",    # the root before /v1/systemone; a path prefix is kept
  api_key: nil,                         # the key, or nil for a service that wants none
  api_key_header: nil,                  # the header the key travels in; nil means Authorization: Bearer
  headers: %{"X-Scorer-Tenant" => "a"}, # extra request headers
  model: "jev-local-1"                  # the model to ask; nil only for TypeSafe, whose default is jev-1.13.0
}
```

`type: :typesafe` is reached through `SystemOneSDK.Providers.TypeSafe` and
carries TypeSafe's published rates. `type: :endpoint` is reached through
`SystemOneSDK.Providers.Endpoint`, the SDK's generic `POST /v1/systemone`
client: an Ixway gateway, a vendor's decision API and a scorer on the
person's own machine are all this kind, and none is priced until
`input_per_million` and `output_per_million` are given, so a capped session
makes no evaluation through an unpriced one. `type: :typesafe` is priced as TypeSafe whatever its `base_url` says, so a
proxy you price yourself is an `:endpoint`. `lmx` builds the map from
`jev_compaction` and `jev_compaction_providers` in its config file
(`Lemieux.CLI.JevCompaction`). A selected provider never falls back to
another on missing credentials or HTTP failure; the request stays as it was.

The older spelling still works for hosts: `route:` (`:auto`, `:typesafe` or
`:ixway`) with `api_key:`, `ixway_endpoint:`, `ixway_api_key:` and `model:`,
where `:auto` chooses Ixway only when an endpoint and a pinned model are
both given. Ixway's chat-completions endpoint is a different protocol and
cannot stand in for `POST /v1/systemone`. A host may also inject its own
`%SystemOneSDK.Client{}` with `client:`.

## Using it from a host

```elixir
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  LemieuxJevCompaction
])

# With a client the host built, for a local or router-backed endpoint:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxJevCompaction, client: client}
])

# For any endpoint implementing POST /v1/systemone — here a scorer on the
# host's own machine, with no key and a declared tariff:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxJevCompaction,
   provider: %{
     name: "local",
     type: :endpoint,
     base_url: "http://127.0.0.1:8080",
     api_key: nil,
     headers: %{},
     model: "jev-local-1"
   },
   input_per_million: 0.0,
   output_per_million: 0.0}
])

# For an Ixway endpoint, in the older spelling:
{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxJevCompaction,
   route: :ixway,
   ixway_endpoint: "https://ixway.example",
   ixway_api_key: System.fetch_env!("IXWAY_API_KEY"),
   model: "jev-local-1"}
])

# Pass harness: harness to start_session/1 or resume_session/1.
```

As a library extension the default is `enabled: :auto` (on when a client or
key is available) and `mode: :apply`. Pass `enabled: false` to disable it
explicitly, or install `LemieuxJevCompaction.hook/1` directly as a
`prepare_next_turn` hook. Assemble it after other request-rewriting hooks.

`activation_tokens` defaults to 1 and is based on Lemieux's encoded-byte / 4
estimate, not the provider's exact tokenizer, and a projection applies whenever
it saves at least one estimated token, so savings can come before any context
or price threshold. Set a higher activation or minimum saving for a provider
whose cost per evaluation exceeds the expected uncached input saving. The hook runs
before the usual window and price checks, so a successful elision can reduce
the pending request immediately; if it cannot save enough, the ordinary
summary compaction remains available. It does not change `compact_at` or
trigger compaction itself. A resumed or forked session reapplies recorded
elisions when the host installs the hook again. A capped host must set
`reservation_per_call_usd` to permit the SDK call; set `max_cost_usd` for an
additional per-session Jev cap and declare `input_per_million` and
`output_per_million` for every provider but TypeSafe's own service. Shadow mode never replays
earlier elisions, even if a host changes mode in the same session. Shadow
scores support offline threshold sweeps; they are not evidence that a model
continuation will remain correct after shortening, so tune the threshold with
real transcript evaluations before widening `eligible_tools`. There is no
claim of net dollar savings without measured route prices and live
task-quality evaluation.

## Paired Jev evaluation

`LemieuxJevCompaction.Trial` replays the same scripted `read`
history into four continuation arms: unchanged history (`baseline`), Jev
scoring without projection (`shadow`), Jev projection (`jev`), and forced
ordinary summary compaction (`summary`). Each arm gets fresh local files and
an independent session. The summary arm uses a 40K window with a 10% trigger
to exercise the summarizer; it is a mechanism comparison, not a claim about a
host's production compaction settings. The runner rotates arm order by case
and repetition to expose cache-warming effects.

The local command loads credentials from the checkout's ignored root `.env`
and requires an upfront dollar reservation for every run. A missing usage
record stops the batch with unknown cost. Prompts, file contents, model
answers and keys never enter the report; only case IDs, exact-answer verdicts,
bounded Jev scores, latency and usage are written to the ignored `tmp/`
directory. It makes paid model and Jev calls. For example:

```sh
cd dist/lmx/extensions/jev_compaction
LMX_CONFIG=none mise exec -- mix run scripts/jev_compaction_eval.exs \
  --model openai:gpt-5-mini \
  --tariff eval/v1/openai_gpt_5_mini_2026_09_22.json \
  --repetitions 4 --cost-cap 1.0 --reservation-per-run 0.05
```

For an end-to-end Luna session with the extension's normal selection bounds,
use `--model openai:gpt-5.6-luna --production-defaults` and the matching Luna
tariff and corpus. The standalone
[live report](eval/v1/results/standalone_luna_production_defaults_2026_09_22.json)
records whether the extension attached and whether the seeded outputs remained
unchanged in the transcript.

`--arms baseline,shadow,jev,summary`, `--threshold 0.1`, `--corpus` and
`--output` can narrow a run. `--production-defaults` keeps the extension's
normal recency, result-size and attempt bounds; without it, the trial lowers
those bounds to score the fixture's short histories. The included corpus is
synthetic and uses exact
answer grading. `score_sweep` reuses shadow scores at several thresholds
without another SDK call; its `false_elisions` count is based on fixture
labels, so only the paired continuations check answer quality. `pair_comparisons`
prices every provider request and Jev call in each matched case, including
summary calls and later turns. A tariff is a dated estimate; compare
`provider_reported_cost_usd` with `provider_cost_usd` and invoices before
claiming billed savings. Recheck the linked provider tariffs before each new
run. The reservation is checked before the batch and known cost after each
arm; an in-flight request can exceed its reservation. In particular, a
shortened prompt can lose a discounted cache prefix.

The default 0.1 keep threshold remains conservative. Repeated paired cases
should refine it, including ordinary compaction and prompt-cache effects.
Compaction generally changes the cache prefix, so the extension applies by
default where Jev access is configured; a host can use shadow mode where its
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
