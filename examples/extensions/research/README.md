# Research extension example

- **What it shows:** a research agent that searches, fetches bounded public
  pages and accepts an answer only when each claim quotes a passage from a
  page it actually fetched.
- **Runs offline?** Yes. `mix test` and `mix lemieux.extension.eval
  bench/compare.exs` use local fixture pages and a scripted responder, with no
  key and no network.
- **Needs:** for live use, a model with its provider's key and
  `BRAVE_SEARCH_API_KEY`. The live benches default to an Ixway route
  (`ixway:gpt-6-luna`); set `RESEARCH_MODEL` to run them on another provider.

This is a native **extension**: an ordinary Mix library that starts nothing on
its own. Its default path plans the question's facts, searches and fetches
bounded public pages, then requires a matching passage in a fetched page for
each answer claim. It makes focused follow-up searches when evidence is
missing. The stages are plain functions (`ResearchExtension.Pipeline` and
`ResearchExtension.Deep`). The one-search or Jev-guided path remains
available with `research_mode: :simple` for comparisons.

From this directory, with an absolute path to your Lemieux checkout:

```sh
export LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux
mix deps.get
mix test
mix lemieux.extension.eval bench/compare.exs
mix lemieux.extension.export . /tmp/research-extension-export
```

## What the pipeline returns

```elixir
{:ok,
 %{
   answer: "Tidepool listens on TCP port 7433 by default.",
   citations: ["http://127.0.0.1:PORT/tidepool-overview.html"],
   claims: [%{id: "C1", need: "Default TCP port", answer: "Port 7433", citation: "…", passage: "Tidepool listens on TCP port 7433 by default."}],
   fetched: [%{url: "…", bytes: 1_204, truncated?: false}, …],
   skipped: [%{url: "http://10.0.0.1/secret", reason: "web_fetch refused …"}],
   session: %{"status" => "completed", "usage" => …, …}
 }}
```

## Claim-led default

The planner uses one structured model request to list at most six facts, an
initial query and a focused query for each fact. The pipeline opens up to four
initial results, synthesizes an answer with a supporting passage per fact,
then uses at most two focused searches and one more synthesis for gaps. Across
the run it permits at most three searches, eight page attempts and the shared
`max_total_bytes` budget (default 2 MiB). Fetch refusals are recorded. It
returns `{:error, {:incomplete_evidence, ids}, partial}` if any planned fact
still lacks a passage in a cited fetched page. It uses full bounded page text;
passage selection can omit a required exception.

The quote check establishes that the passage was actually seen. It cannot
decide whether the model's interpretation follows from the passage, or whether
the planner listed every relevant fact. A source may be secondary even when
its quote matches. Hosts should review those limits for consequential work.
Search and fetch run through `Lemieux.Tools.run/4`, so host tool hooks apply.

Normal `lmx` coding agents get a related model-driven workflow when a Brave
key is configured: `web_search`, guarded `web_fetch`, `research_check` and a
short claim-led prompt. The checker validates passages against that agent's
fetch receipts without hidden model or web calls. The standalone extension's
automatic planner and synthesis sessions are separate and have their own
bounded request counts.

## One-search path

Pass `research_mode: :simple` to use the previous one-search synthesis or Jev
source selector. `top_k` bounds the results opened and `max_total_bytes`
bounds the streaming fetch budget. A page the fetch tool refuses is skipped;
fetching nothing is fatal.

The synthesis receives that contract through the session's `:output_schema`,
in addition to the prompt, so ReqLLM selects structured generation. A tool-based
structured answer is converted to JSON answer content by Lemieux's provider
boundary. The synthesis must reply with `{"answer": …, "citations": [urls]}`. A citation
to a URL that was not fetched is `{:error, {:unfetched_citation, url}, partial}`
and an answer with no citations is `{:error, :uncited_answer, partial}`. The
pipeline reports these rather than passing a plausible-looking answer through:
grounding is a check here, not a label. Search and fetch calls go through
`Lemieux.Tools.run/4`, so a host's `before_tool_call` hooks apply to them.

`ResearchExtension` wraps the pipeline as a `Lemieux.Agent`: a completed
observation carries the plain answer plus `"citations"`, `"fetched"` and
`"skipped"`; a failed one keeps the same evidence and the raw model reply.

## Guided source discovery

In `research_mode: :simple`, `Pipeline.run/2` and the agent automatically enable Jev-guided discovery when
`JEV_API_KEY` is nonempty or a key is saved in the personal config's
`jev_compaction.api_key`. Environment credentials take precedence over saved
credentials. `LMX_CONFIG=none` disables personal lookup; another value selects
that config path. Config files are validated, never created or modified here.
Without a key, the pipeline opens the deterministic search shortlist.
Pass `discovery: false` to opt out even with a key. An explicit
`discovery: [api_key: key]` overrides credential lookup.

The default uses the existing Req dependency with the native
[TypeSafe classification contract](https://docs.typesafe.ai/api), pinned to
`jev-1.13.0`. It requires no browser or SDK installation. One classification
request has a 15-second receive timeout and a 5-second connect timeout, with
redirects and retries disabled. Source-choice errors fail the research run with
partial evidence rather than silently claiming that guided discovery succeeded.

An explicit `discovery: [classify: classifier]` replaces that default.
The callback accepts a native typed-question request and returns
`{:ok, %{"answers" => ..., "model" => ..., "usage" => ...}}`. A host that
already loads the optional computer-use extension can use
`&LemieuxComputerUse.Jev.evaluate/1`. The research example adds no SDK dependency.

```elixir
discovery: [
  candidate_limit: 5,
  max_depth: 1,
  timeout_ms: 30_000
]
```

Instead of opening every top hit, this path offers search metadata and then
same-host links from fetched pages to the classifier. It asks for primary,
current, direct evidence for remaining parts of the question. Selections are
validated against offered IDs and probability distributions. Canonical URLs
are deduplicated, including fragment variants and final redirect URLs.
`candidate_limit` bounds the initial search (default 10, maximum 10), while
`top_k` bounds fetch attempts, including failures. The frontier holds at most
20 candidates and link depth defaults to one (maximum three). The shared
streaming byte budget still applies; a failed fetch consumes its full reserved
allowance because failed-transfer bytes are unknown.

Classifier calls cross the `research_discovery_choice` tool hook and page
requests cross `web_fetch`. Rewritten classification inputs are refused.
The discovery deadline cancels the worker, with incomplete evidence marked
explicitly and unknown counters reported as null. Returned `discovery`
evidence contains source provenance, choices, usage, attempts and stop reason;
Jev billed cost remains unknown. `model_stop` is a model judgement about the
supplied excerpts, not an independently verified completeness claim. The
synthesis receives the full retained page text, and citation checks still run.

[Research extension](../../../docs/web-tools.md#research-extension) in the
web tools guide summarizes the same bounds. To try Jev activation with the
computer-use example's env-file loader and your personal model configuration,
run from that directory:

```sh
LMX_CONFIG=none MIX_ENV=test mise exec -- mix run bench/guided_research.exs \
  --execute --env-file ../../../.env
```

This spends one Brave call, at most three Jev calls, three guarded HTTP fetches
and one synthesis request. It creates a temporary workspace and session store;
it does not alter personal settings. The source host omits the unrelated
optional Jev compaction setting supplied by `dist/lmx`.

## Offline tests and bench

`ResearchExtension.Search.Static` is a keyword index that maps queries to
fixture URLs, and `ResearchExtension.FixtureServer` serves `bench/fixtures/pages`
from `127.0.0.1` with OTP's `:httpd`. Because the fetch tool refuses loopback
by default, tests and the bench build it with
`Lemieux.Tools.WebFetch.new(unsafe_allow_loopback_for_tests: true)`; the option
is named to keep it out of hosts, and it admits loopback only. The tests cover
the happy path, an unfetched citation, an uncited answer, malformed and fenced
replies, a page over the per-page cap and the total budget, a search backend
error, a refused private page, hooks, and the agent entry point. Offline tests
and the deterministic bench explicitly disable automatic Jev discovery.

`bench/compare.exs` starts the fixture server itself and pairs two agents on
five fixture questions whose answers live in the pages:

- `grounded-fetch` — this extension over the static index and the fetch tool;
- `model-alone` — `ResearchExtension.Baseline`, the same synthesis session
  asked the bare question with no search, no fetch and no tools.

Both use one scripted, deterministic *extractive* responder in place of a
model: it answers with the sentence from the supplied sources that best matches
the question and cites that source, and says it cannot answer when no sources
were supplied. Its answer therefore contains a fact only when the pipeline
fetched the page carrying it. The grader (`bench/fixtures/workspace/check.exs`)
checks the answer for the expected phrase, the way the discovery corpus's
report-only cases do. Expect `grounded-fetch: 5/5` and `model-alone: 0/5`.

This shows the pipeline's plumbing and its grounding check. It does not
measure any model's research quality, and the scripted responder is not a
model.

## Live comparisons

These scripts make paid provider and search requests. They compare selected
development tasks, not general research accuracy. Freeze inputs and graders
before a new campaign and retain failures and accounting uncertainty.

Every live script takes its model from `bench/live_setup.exs`, so the arms of
a comparison always match. `RESEARCH_MODEL` selects it as `provider:model`;
the default, `ixway:gpt-6-luna`, is the model the recorded campaigns ran on
and goes through Ixway, configured by the `ixway` object in
`~/.lmx/config.json` or by `IXWAY_API_KEY` and `LMX_IXWAY_URL`. Any other
model goes straight to its provider through ReqLLM, with that provider's key
in the environment, for example `RESEARCH_MODEL=openai:gpt-5-mini` with
`OPENAI_API_KEY`. `RESEARCH_EFFORT` sets the reasoning effort (`max` on
Ixway, the provider's default otherwise). The Brave key comes from
`BRAVE_SEARCH_API_KEY` and the Jev key from `JEV_API_KEY`, or from
`~/.lmx/config.json` when the variable is unset. Keys in the environment are
enough: the scripts read that file only if it exists. They read it whatever
`LMX_CONFIG` says, because the v5 command below sets `LMX_CONFIG=none`, which
turns off the pipeline's own lookup of a saved Jev key, and still takes its
keys from the file.

`bench/live.exs` and `bench/live-manifest.json` pair the bare model against
Brave search and production-policy page fetch. Both arms use the same model
and effort, and optional Jev discovery is disabled to isolate search and
fetch. From this directory, with an absolute path to Lemieux:

```sh
LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux mise exec -- mix lemieux.extension.eval bench/live.exs --allow-live
```

The script runs four tasks serially with one model request per arm per task
(eight maximum), four Brave searches and at most 16 page fetches. An Ixway
route has no usable pre-request dollar estimate, so the local limit is a
request cap, not a dollar cap; check the provider's or gateway's budget before
repeating the run. Fetched-URL citations establish that a page was retrieved;
score correctness and source support independently.

`bench/deep-live.exs` extends that comparison with four multi-part questions
whose answer key is frozen in [deep-live-sources.md](bench/deep-live-sources.md).
It runs the same model and effort in three arms: model alone, one Brave search
with up to six guarded page fetches, and an iterative tool session with up to
six model requests, three searches and eight fetches. The full campaign is
serial, one repetition per task and arm, with at most 32 model requests, 16
searches and 56 fetches. The example's `mix.lock` pins its dependencies. Run
from this directory with an absolute path to the Lemieux checkout:

```sh
LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux mise exec -- mix lemieux.extension.eval bench/deep-live.exs --allow-live
```

`bench/v5.exs` is the larger follow-up. Its [12-task corpus](bench/v5-corpus.json)
freezes 46 atomic claims across version conflicts and false premises. It
compares model alone, one search with six page attempts, Jev-guided discovery
and iterative web on the `RESEARCH_MODEL` model (by default `ixway:gpt-6-luna`
at `max` effort). The run is serial with one repetition and also needs a
`JEV_API_KEY`. The script passes the frozen key path to the grader. From this
directory, with credentials in the environment or the personal config:

```sh
LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux mise exec -- mix deps.get
LMX_CONFIG=none MIX_ENV=test LEMIEUX_EXTENSION_BASE=/absolute/path/to/lemieux mise exec -- mix lemieux.extension.eval bench/v5.exs --allow-live
```

The preflight, query, balanced-query and passage-replay scripts are under
`bench/v5-*`; they make additional live requests. `:query_strategy` is an
experimental pipeline option: `:leading` remains the default, and
`:balanced` preserves late words inside the local Brave cap. Compare source
coverage and factual completion before selecting an experimental strategy.
Raw reports, sanitized summaries, plans and fetched page snapshots belong in
ignored `tmp/` or a host-owned artifact store. Original campaign records are
not kept in the repository.

## Embedding

```elixir
Lemieux.Agent.run(ResearchExtension,
  %{prompt: "What changed in the last release?", cwd: "/tmp/research", timeout_ms: 60_000},
  provider: provider,
  model: model,
  supervisor: MyHost.Lemieux,
  session_options: [max_cost_usd: 0.50],
  search: {Lemieux.Extensions.Web.Brave, Lemieux.Extensions.Web.Brave.new(api_key: key)},
  fetch: Lemieux.Tools.WebFetch.new(),
  top_k: 4,
  max_total_bytes: 2_097_152
)
```

The host owns credentials, the search backend, the fetch limits and the model.
Outside this checkout the example depends on `lemieux` from Hex. For
development against this checkout, set `LEMIEUX_EXTENSION_BASE` to its
absolute path; unset it to use the Hex release. Export preserves `mix.exs` and
does not publish to Hex or install the extension into `lmx`.
