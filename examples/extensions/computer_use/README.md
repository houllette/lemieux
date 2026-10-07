# Experimental computer use

- **What it shows:** experimental headless **browser** use (not desktop
  control): a bounded crawl, then actions on the live page chosen by Jev, a
  hosted classifier, and carried out through Wallaby.
- **Runs offline?** Yes, for its checks: `mise exec -- mix check` needs no
  browser and no key, and `mix test --include browser` drives a real Chrome
  against local fixtures without model calls.
- **Needs:** Chrome and a matching ChromeDriver, a `JEV_API_KEY` (TypeSafe,
  billed) for any task that acts on a page, and a text model with its key
  (`--text-model`) for tasks that type text.

A separate Mix extension for Lemieux: optional search → bounded deterministic
crawl → current DOM observation → Jev operation/target choices → Wallaby input
→ a fresh observation. It operates a headless browser through ordinary HTML
and ARIA controls. This is browser use, not desktop or screenshot-based control.

## Run it

From this directory:

```sh
mise exec -- mix deps.get
export LMX_BROWSER_CHROME='/absolute/path/to/chrome'
export LMX_BROWSER_CHROMEDRIVER='/absolute/path/to/chromedriver'
mise exec -- mix lmx.browser --demo --env-file ../../../.env \
  --text-model openai:gpt-4o-mini --journal /tmp/lmx-browser-demo.jsonl
```

Install matching Chrome and ChromeDriver builds using
[Chrome for Testing](https://googlechromelabs.github.io/chrome-for-testing/).
The variables are optional when Wallaby can discover both binaries. Downloads
and browser startup are explicit host actions. The driver retains Chrome's
sandbox, uses a fresh profile for each task, and does not attach to your usual
signed-in browser. The journal must be a new path; it is created with mode 0600.

The demo serves a local fixture, opens its hotel finder, enters Lisbon, selects
Design, checks Free cancellation, and opens Casa Flora. It independently checks
the final URL and visible result. Only this demo enables loopback navigation.

`JEV_API_KEY` is passed to SystemOneSDK's TypeSafe provider for the native
classification endpoint. There is no OpenRouter requirement. `--env-file`
explicitly loads the file into this process; existing environment values win.
No credentials are put in extension configuration, reports, or source. Keep
`.env` and journals out of Git.

Jev selects among offered actions; it does not generate field text. A task that
needs typing requires `--text-model` and that ReqLLM provider's credentials. The
demo above therefore also needs `OPENAI_API_KEY`. Hosts can instead provide a
`:text` callback that supplies deterministic field values, or choose any suitable
ReqLLM structured-output model. There is no automatic fallback provider.

For another website:

```sh
mise exec -- mix lmx.browser \
  --url https://example.com \
  --goal 'Follow Learn more to the IANA Example Domains page.' \
  --allow-host example.com --allow-host iana.org --allow-host www.iana.org \
  --env-file ../../../.env \
  --expect-url https://www.iana.org/help/example-domains --expect-text 'Example Domains'
```

Alternatively pass `--query 'your search'` instead of `--url`. This explicitly
uses the credential-free Exa MCP endpoint, then selects the first result on an
allowed host. It uses Lemieux's existing MCP client and web-search tool, borrowing
the keyless search approach from
[pi-web-access](https://github.com/nicobailon/pi-web-access). This public service
can fail or change; failures do not switch to another provider. URL-only runs
never call search. Repeat `--allow-host` to permit additional destination hosts.

When assembled into a Lemieux harness that already contains a configured
`Lemieux.Tools.WebSearch`, query-seeded browser tasks reuse that backend and its
declared request cost. A host with Brave enabled therefore keeps using Brave.
An explicit extension `:search` option takes precedence; direct runner/standalone
use without a host search tool retains the documented Exa route. Search failures
retain the backend or hook's reason rather than looking like an empty result set.

## Fetch a page without model calls

With the browser paths configured as above:

```sh
MIX_ENV=test mise exec -- mix lmx.browser --fetch-only \
  --url https://docs.typesafe.ai/introduction --allow-host docs.typesafe.ai
```

No Jev or text-model key is needed for fetching. The HTTP request first asks
for Markdown; HTML extraction prefers article/main content and ranks its links
ahead of navigation. Only a successful, untruncated JavaScript shell can escalate
to a fresh Wallaby session through the separate `web_fetch_render` policy hook.
Add `--no-browser-fetch` to disable that escalation. `--render-timeout-ms` bounds
the entire browser attempt (default 10,000); `--render-wait-ms` bounds content
settling after navigation (default 2,000). Failure or denial retains the clearly
labelled static result. The DOM projection includes content below the viewport
and strips scripts, hidden content and form values. It performs no browser input.
`--fetch-only --no-browser-fetch` also skips Wallaby startup entirely, so that
combination works without installed browser binaries.

The extension registers `web_fetch` alongside `computer_use`, and its crawl uses
the same wrapper. A host's existing configured HTTP limits are retained. A custom
host tool named `web_fetch` is left in place. Result provenance distinguishes
HTTP from rendering; `bytes` measures only the initial HTTP transfer, while
`rendered_bytes` measures the bounded DOM projection. Browser network transfer
is unknown and cannot be accounted against the HTTP crawl byte budget.

## Embed it

Add this directory as a path dependency in a source-based Mix host. Its separate
lockfile contains Wallaby and its dependencies; Lemieux's root dependencies and
application startup remain unchanged.

```elixir
# During explicit host runtime startup, once per VM:
:ok = LemieuxComputerUse.Wallaby.start()

{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxComputerUse,
   allowed_hosts: ["example.com", "iana.org", "www.iana.org"],
   text_model: "openai:gpt-4o-mini",
   max_steps: 30,
   timeout_ms: 90_000,
   verify: fn page ->
     page["url"] == "https://www.iana.org/help/example-domains" and
       String.contains?(page["text"], "Example Domains")
   end}
])
# Pass harness: harness to Lemieux.start_session/1 in the normal mounted runtime.
```

For a custom CLI host, pass the same extension tuple in
`Lemieux.CLI.run(argv, extensions: [extension])` after starting the browser runtime.
The model receives `computer_use` with `goal` and either `url` or `query`, alongside
the enhanced `web_fetch` tool.
`LemieuxComputerUse.Runner.run/3` also runs the same workflow directly, as the
standalone task does. Assembly performs no network calls and starts no processes.

This experiment supports source-based Mix hosts. It does **not** provide a
prebuilt `lmx extension install` bundle: the current bundler traverses started
application dependencies, while Wallaby is deliberately `runtime: false`, and
its native dependencies need platform-specific distribution work. Wallaby also
uses VM-global configuration and starts ExUnit internally; use a dedicated host
process if another component configures Wallaby differently.

## Decisions and evidence

[TypeSafe's API](https://docs.typesafe.ai/api) is a typed classification API,
not OpenAI chat completions. This extension uses
[SystemOneSDK](https://github.com/nshkrdotcom/system_one_sdk) for the TypeSafe
request and response contract; it neither registers a core provider nor
substitutes for ReqLLM text generation. The default client pins `jev-1.13.0`
and the hosted TypeSafe endpoint. Each browser step disables SDK retries, while
the extension's Pristine transport disables `:httpc` redirects and automatic
Retry-After retries. This preserves the one-request budget and prevents a
redirect from forwarding the bearer credential. A single request asks for the
operation and a compatible target for each offered operation; only the chosen
operation's target answer is consumed. It does not predict and blindly replay
future pages.

The adapter uses SystemOneSDK's raw `system_one/4` API because a current page
can offer only one target for an operation; the SDK's strict `evaluate/4` API
requires at least two Choice alternatives. `Decision.decode/4` continues to
validate the chosen operation, target, distribution, and confidence against the
current observation. Hosts may pass an explicit SystemOneSDK client as
`jev: [client: client]` to select a compatible endpoint or, when supported by
the SDK, a native provider. This is a host-code option, not an extension JSON
setting. A selected client is the sole classification path; it does not fall
back to the hosted provider on failure. The hosted TypeSafe provider is the
default. SystemOneSDK 0.6.0, which this extension's lockfile resolves, also
provides a generic System One v1 HTTP endpoint provider and an in-process
provider contract for native adapters; the SDK describes native execution
itself as an optional runtime still to come.

The SDK's current Pristine/Sinter dependency constraints require `jsv 0.21.2`
and `texture 1.2.1` in this extension's isolated lockfile. The Lemieux root
lockfile remains independent.

### System One compaction

[System One compaction](../../../dist/lmx/extensions/systemone_compaction/README.md), which
ships inside the `lmx` release, can shorten old read results before native
compaction. It does not require the browser extension.

The DOM reader returns at most 150 element actions, two scroll actions, and
6,000 characters of viewport text. It excludes password/file fields. Before
native WebDriver input, it checks document identity, URL, target identity, form
state, visibility, disabled state and occlusion. A stale observation can be
retried; a failure after input may have happened stops the run. Frames, shadow
DOM, canvas, uploads, multi-tab flows and authentication are outside this version.

Every crawl request, initial navigation and subsequent browser input crosses
the **effective invocation hooks**, including host overrides supplied after
extension assembly. The inner tool names are `web_search`, `web_fetch`, `web_fetch_render`,
`computer_use_open` and `computer_use_action`. Hooks may deny or park them using
the normal Lemieux approval contract. Action arguments include text for policy
inspection; the extension's retained action receipts omit that text. Host hooks
and approval transcripts still control their own retention. A rewritten browser
action is refused rather than executing a previously observed target.

The host owns policies for consequential actions and network isolation. An
allowed-host list and public-address preflight constrain selected navigations;
they do **not** sandbox browser subresources, redirects, script navigation or
DNS rebinding. Chrome runs in the host process environment, not through a
remote `Lemieux.Environment` adapter. Do not treat extension assembly, DOM
guards or a prompt telling Jev to ignore page instructions as a security boundary.

`DONE` returns `done_unverified` with `verified: false` until a host verifier
checks a fresh observation. The standalone `--expect-url`/`--expect-text` options
provide simple independent checks. Choose checks that actually establish the
task outcome. Only verified completion uses status `completed`.

When a fresh, permitted observation fails that check, one correction is allowed
by default. The next Jev request includes structured verification feedback and
current page state. A second rejected `DONE` stops as `verification_failed`.
Set `max_verification_retries: 0` (or `--max-verification-retries 0`) to stop at
the first rejection; host values from zero to three are accepted. Corrections
share the ordinary `max_steps` classification budget. A policy denial, failed
observation or uncertain native input never takes this correction path.

Structured results retain decisions, model version, token usage, elapsed times,
action outcomes and discovery receipts. `:on_event` receives ordered events;
`classifier_attempts` also counts calls rejected by the decoder or confidence
gate, which never appear in the accepted `decisions` list. Failed completion
checks appear as `verification_result` events and `verification_feedback`.
The standalone journal flushes each event, including intent before input.
Receipts contain no live browser handles or raw API requests. Browser state is
ephemeral: transcript resume does not resume or replay a browser action chain.
The opening worker owns the Wallaby session; cancellation terminates that worker
and Wallaby monitors it for cleanup.

Jev and helper calls occur inside this tool, so the session's outer inference
budget does not account for them. This version limits requests through
`max_steps` (default 30, maximum 100) and wall time (default 90 seconds, maximum
300 seconds). Each attempt makes at most one Jev call and one text-helper call;
provider-internal text retries remain governed by ReqLLM options. Classification
cost is **unknown**, represented as null, rather than inferred to be free.
Confidence is reported but is not authorization or proof of correctness.

Discovery defaults to three attempts, depth one, a 512 KiB successful-response
byte budget, and 256 KiB per response. Errors still consume page attempts;
failed-transfer bytes are not reported by the underlying fetcher. Set
`--crawl-pages 0` to compare against browser-only observation. The crawler uses
the existing DNS-pinned `web_fetch` tool. We did not add `fredwu/crawler`: the
reviewed release requires Req `~> 0.6.2`, conflicting with this tree's `~> 0.7`,
and its larger crawl runtime is unnecessary for this bounded experiment.

## Validate and compare

```sh
mise exec -- mix check
MIX_ENV=test mise exec -- mix test --include browser --warnings-as-errors
MIX_ENV=test mise exec -- mix run bench/compare.exs --allow-live \
  --env-file ../../../.env --text-model openai:gpt-4o-mini --repeats 3
```

The first command needs no browser or model keys. The second uses real Chrome
against local fixtures, without provider calls. The third makes billed Jev
(TypeSafe) and text-model calls, up to 3 repeats × 2 arms × 20 steps, and
refuses to start without `--allow-live`. CI runs the first command in an
isolated job. Run root `mise exec -- mix precommit` as well for the shared hook
context change. The comparison alternates crawl/no-crawl order, uses fresh
browser sessions and independent verification, and prints JSONL measurements.
Its timing includes discovery, session creation, navigation and verification,
but excludes starting the shared Wallaby runtime and closing the session.
It compares discovery cost on one exposed fixture; it does not establish a
speedup over a general-purpose browser agent or generalization to unknown sites.

Retain new comparison journals in an ignored `tmp/` directory or a host-owned
artifact store. Historical qualification reports are not kept in the repository. The
grouped-choice, observed-control design and portions of `priv/browser.js` are
adapted from [jev-ultrafast](https://github.com/browser-use/jev-ultrafast) at
1231850a; the attribution and its MIT license are in [NOTICE](NOTICE).
