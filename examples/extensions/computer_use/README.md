# Experimental computer use

- **What it shows:** experimental headless **browser** use (not desktop
  control): a bounded crawl, then actions on the live page chosen by a
  System One model — TypeSafe's hosted Jev, or any provider serving
  `POST /v1/systemone`, a model on your own machine included — and carried
  out through Wallaby.
- **Runs offline?** Yes, for its checks: `mise exec -- mix check` needs no
  browser and no key, and `mix test --include browser` drives a real Chrome
  against local fixtures without model calls.
- **Needs:** Chrome and a matching ChromeDriver, a System One provider for
  any task that acts on a page (a local one such as Ollama costs nothing;
  TypeSafe, through `JEV_API_KEY`, and other hosted ones bill), and a text
  model with its key (`--text-model`) for tasks that type text.

A separate Mix extension for Lemieux: optional search → bounded deterministic
crawl → current DOM observation → System One operation/target choices →
Wallaby input → a fresh observation. It operates a headless browser through
ordinary HTML and ARIA controls. This is browser use, not desktop or
screenshot-based control.

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
Each step's choice comes from a System One provider: TypeSafe's when the env
file sets `JEV_API_KEY`, or a model on your own machine
([Choose a System One provider](#choose-a-system-one-provider)).

`--env-file` explicitly loads the file into this process; existing
environment values win. No credentials are put in extension configuration,
reports, or source. Keep `.env` and journals out of Git.

The System One model selects among offered actions; it does not generate
field text. A task that needs typing requires `--text-model` and that ReqLLM
provider's credentials. The demo above therefore also needs `OPENAI_API_KEY`.
Hosts can instead provide a `:text` callback that supplies deterministic field
values, or choose any suitable ReqLLM structured-output model. There is no
automatic fallback provider.

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

### Choose a System One provider

Each step asks one System One provider which operation to take, and on which
of the page's targets. Providers are declared once, by name, under
`"systemone_providers"` in the lmx config file (`~/.lmx/config.json`, or the
file `LMX_CONFIG` names) — the list `lmx` itself uses for System One
compaction ([System One providers](../../../docs/configuration.md#system-one-providers)).
A model Ollama serves on this machine needs no key:

```json
{
  "systemone_providers": {
    "local": {"base_url": "http://127.0.0.1:11434", "model": "clef-flash"}
  }
}
```

```sh
ollama pull clef-flash
mise exec -- mix lmx.browser --demo --systemone-provider local \
  --env-file ../../../.env --text-model openai:gpt-4o-mini
```

`--systemone-provider NAME` selects an entry by name; `typesafe` and `ixway`
are built in. Without the flag (or with `auto`) the task takes the automatic
choice `lmx` makes: an Ixway gateway when its endpoint and a model are
configured, otherwise TypeSafe when `JEV_API_KEY` (or
`systemone_providers.typesafe.api_key`) is set — so a `JEV_API_KEY` alone
still runs every step on TypeSafe's `jev-1.13.0`, as before. A declared
provider is used only when named. A provider that cannot be used stops the
task before Chrome starts, with a sentence saying what is missing, and
nothing falls back to another provider: one you pointed at your own machine
is where page content goes. A config file holding a key must be private
(`chmod 600`).

## Fetch a page without model calls

With the browser paths configured as above:

```sh
MIX_ENV=test mise exec -- mix lmx.browser --fetch-only \
  --url https://docs.typesafe.ai/introduction --allow-host docs.typesafe.ai
```

No System One provider or text-model key is needed for fetching. The HTTP request first asks
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

# The provider that chooses each action. Lemieux.CLI.SystemOne.provider/3
# resolves one from the lmx config file; a host can also write it out.
provider = %{name: "local", type: :endpoint, base_url: "http://127.0.0.1:11434",
             api_key: nil, api_key_header: nil, headers: %{}, model: "clef-flash"}

{:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(), [
  {LemieuxComputerUse,
   allowed_hosts: ["example.com", "iana.org", "www.iana.org"],
   systemone: [provider: provider],
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

A System One model answers typed questions with calibrated probabilities over
`POST /v1/systemone` ([TypeSafe documents the contract](https://docs.typesafe.ai/api));
it is not OpenAI chat completions. This extension uses
[SystemOneSDK](https://github.com/nshkrdotcom/system_one_sdk) for the request
and response contract — its TypeSafe provider for TypeSafe's hosted service,
its generic Endpoint provider for any other — and neither registers a core
provider nor substitutes for ReqLLM text generation. Each browser step
disables SDK retries, while the extension's Pristine transport disables
`:httpc` redirects and automatic Retry-After retries. This preserves the
one-request budget and prevents a redirect from forwarding the credential. A
single request asks for the operation and a compatible target for each
offered operation; only the chosen operation's target answer is consumed. It
does not predict and blindly replay future pages.

The questions are portable: one request shape serves every provider.
Servers differ in what they accept — TypeSafe takes a one-option choice,
Ollama (0.35) refuses a choice with one option or more than 26, and its
nimble model refuses an object as an option's description — so
`LemieuxComputerUse.Decision` follows the strictest rules. A target's
description is its attributes as one JSON string. An operation the page
offers through one target gets no target question: choosing the operation
chooses that target, recorded with a null target confidence. An operation
with more than 26 targets is asked in groups of at most 26 — a
question for the group, one per group for the target, all in the same
request — and the target's confidence is the product of the two answers.
The adapter uses SystemOneSDK's raw `system_one/4`, and `Decision.decode/4`
validates the chosen operation, target, distribution and confidence against
the current observation; an answer must also name the model that was asked.

Hosts pass `systemone: [provider: provider]` (the map
`Lemieux.CLI.SystemOne.provider/3` returns) or `systemone: [client: client]`
(a SystemOneSDK client they built), with an optional `timeout_ms:`. This is a
host-code option, not an extension JSON setting. The selected provider is the
sole classification path: it does not fall back to another on failure, and
with none the run stops before discovery or the browser starts. The
extension's own code reads no key; `mix lmx.browser` resolves the provider
from the lmx config file. The former `jev:` option and its `api_key:` are
refused with a sentence naming their replacement, not ignored.

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
guards or a prompt telling the System One model to ignore page instructions as a security boundary.

`DONE` returns `done_unverified` with `verified: false` until a host verifier
checks a fresh observation. The standalone `--expect-url`/`--expect-text` options
provide simple independent checks. Choose checks that actually establish the
task outcome. Only verified completion uses status `completed`.

When a fresh, permitted observation fails that check, one correction is allowed
by default. The next System One request includes structured verification feedback and
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

System One and helper calls occur inside this tool, so the session's outer
inference budget does not account for them. This version limits requests
through `max_steps` (default 30, maximum 100) and wall time (default 90
seconds, maximum 300 seconds). Each attempt makes at most one System One call
and one text-helper call; provider-internal text retries remain governed by
ReqLLM options. Classification cost is **unknown** to the extension,
represented as null rather than computed: a provider on your own machine
costs nothing, while TypeSafe and other hosted providers bill each call.
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
LOCAL_SYSTEM_ONE_URL=http://127.0.0.1:11434 LOCAL_SYSTEM_ONE_MODEL=clef-flash \
  MIX_ENV=test mise exec -- mix test test/system_one/local_server_test.exs
MIX_ENV=test mise exec -- mix run bench/compare.exs --allow-live \
  --env-file ../../../.env --text-model openai:gpt-4o-mini --repeats 3
```

The first command needs no browser or model keys. The second uses real Chrome
against local fixtures, without provider calls. The third sends two
classification requests to a System One server you run (Ollama with
`clef-flash` or `nimble` above; `LOCAL_SYSTEM_ONE_KEY` if it wants a bearer
token), without Chrome, and checks that its answers decode to offered
actions; it is skipped unless `LOCAL_SYSTEM_ONE_URL` is set. The fourth makes
System One calls (billed when the provider is hosted; `--systemone-provider`
selects it as for `mix lmx.browser`) and text-model calls, up to 3 repeats ×
2 arms × 20 steps, and refuses to start without `--allow-live`. CI runs the
first command in an isolated job. Run root `mise exec -- mix precommit` as
well for the shared hook context change. The comparison alternates crawl/no-crawl order, uses fresh
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
