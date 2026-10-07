# Providers and models

`lmx` and every embedded session talk to models through one adapter,
`Lemieux.Providers.ReqLLM`, built on [ReqLLM](https://hex.pm/packages/req_llm).
A model is named `provider:model`, for example `anthropic:claude-sonnet-5` or
`ollama:gemma4:12b`. Any provider ReqLLM supports goes through the same code.
Provider-specific authentication, streaming, message encoding, tool calling,
thinking blocks and model catalogs belong to ReqLLM; Lemieux has no
hand-written vendor adapters, and adding one is not an extension point.

The first half of this page is for `lmx` users: how to choose a model, which
one `lmx` starts on, and how to run a local model. The rest describes the
adapter for a host, the application that embeds Lemieux: gateways,
discovery, failures, caching and cost estimates.

## Choosing a model in lmx

Name a model in any of these places. The first one that says wins:

1. `--model PROVIDER:MODEL` (or `-m`) on the command line;
2. `LMX_MODEL`;
3. an [Ixway](ixway.md) route, when one is configured, which names its own
   model;
4. `"model"` in `~/.lmx/config.json`.

In the terminal UI, `/model` switches the session's model and `/provider`
switches to another provider. A specification `lmx` cannot parse, such as a
bare `gpt-4o`, or one naming a provider it does not know, is refused with a
sentence saying how to write it.

Each provider reads its API key from its own environment variable, such as
`ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. `lmx help models` lists the
providers `lmx` recommends, the variable each one reads and the model it
starts on. A key can also live in `~/.lmx/config.json`:

```json
{
  "providers": {
    "openai": {"api_key": "sk-..."}
  }
}
```

Keep that file readable only by you (`chmod 600 ~/.lmx/config.json`): `lmx`
refuses to read a config file that holds a key when anyone else has access
to it. The terminal UI writes it that way when it saves a key for you. A key
in the environment wins over a saved one. A variable set to an empty value
counts as no key, and it also switches off a key saved in the file.

The installed `lmx` never reads a `.env` file from the directory it starts
in, so a repository you open cannot supply a key or change where requests
go. A source checkout run (`mise exec -- mix lmx`) still loads that
checkout's own `.env`.

### Which model lmx starts on

When nothing above names a model, `lmx` tries these in order:

1. **The model you last chose**, if it can still be reached. That is the
   model a terminal UI session last started on because you named it, in one
   of the places above or with `/model` or `/provider` after a start that
   failed. A model you switch to in a running session is not remembered,
   and `lmx run` remembers nothing. "Reached" means its provider has a key,
   or, for an `ollama:` model, the local Ollama daemon serves it. Names are
   compared the way Ollama compares them: `ollama:llama3.2` is
   `llama3.2:latest`.
2. **The recommended model of the first provider whose key is set**, in the
   order `lmx help models` lists: Anthropic, OpenAI, Google Gemini, xAI,
   OpenRouter, DeepSeek, Z.AI Coding Plan. A key counts whether it comes
   from the environment, ReqLLM's configuration or `"providers"` in the
   config file.
3. **A model the local Ollama daemon serves that can call tools.** `lmx`
   prefers the local model it used most recently, then the most recently
   pulled or updated one, and says which it chose in a startup notice. See
   [Use a local model](#use-a-local-model).
4. **The placeholder `anthropic:claude-sonnet-5`.** The terminal UI opens
   its provider panel so you can paste a key; `lmx run` exits with status 3
   and a sentence listing your choices.

A model `lmx` picked in steps 2 to 4 is recorded as used, never as your
choice, so a key you set later still wins. If a remembered local model is no
longer served, or Ollama does not answer, that start moves to the next step
and a notice says so; your choice stays remembered for when Ollama is back.

`--config none` (or `LMX_CONFIG=none`) without `LMX_HOME` skips all of
this: it starts on `anthropic:claude-sonnet-5` unless `--model`, `LMX_MODEL`
or an Ixway route names another, and never picks a model from your keys or a
local Ollama. If the default config file cannot be created, as on a
read-only home directory in CI, steps 2 to 4 still apply. Set `LMX_HOME` to
give `lmx` a writable state directory.

### Starting without a key

With no key and no local model, bare `lmx` opens a panel titled "Choose a
model provider". No provider is preselected. Pick one, paste its key, and
`lmx` saves it in plain text to `~/.lmx/config.json`, readable only by you,
together with the model; under `--config none` the key lasts for that sitting
only. Requests are billed by that provider. When the local Ollama serves a
model that can call tools, the panel's last row starts it with no key.

Esc leaves the panel without saving anything: `no key saved · set one in
your environment, or paste it here at the next start`, followed by the
`/provider` switches that work now, such as `/provider ollama`. The panel
opens again at the next start. `/provider` saves no key, and `/model`
chooses only within the current provider, so on a keyless start
`/provider ollama` is the way to a local model.

The panel also opens for a model you named, or a session you resumed
(`lmx --resume ID`, `lmx -c`), whose provider has no key. That provider is
then preselected, and the panel says `No API key was found for MODEL. Paste
one (requests are billed by that provider), choose another provider, or Esc
to look around first.`

`lmx run` never asks. Without a usable key it exits with status 3 before any
session or transcript exists, and its message names what to set. [Your first
session](getting-started.md) walks through the first run.

## Use a local model

`lmx` runs local models through [Ollama](https://ollama.com) with no key and
no account. One setting decides whether that works well: the context window
Ollama serves the model with.

Unless told otherwise, Ollama sizes the window by the machine's GPU memory
when it loads a model: 4,096 tokens with less than about 23 GiB, 32,768 with
less than about 47 GiB, and 262,144 above that. `lmx`'s own instructions and
tools take about 3,500 tokens before it has read a single file. A
conversation longer than the window is not refused: Ollama silently drops
its oldest part, your task first, and a session can end with an empty
answer. Measured on a 4,096-token window, the getting-started question did
exactly that; on a 32,768-token window it was answered in under a minute.

### The recipe

1. Set the window where the Ollama server runs, to 65,536 tokens (32,768 at
   the least); [Ollama's context length page](https://docs.ollama.com/context-length)
   describes the setting:

   ```sh
   OLLAMA_CONTEXT_LENGTH=65536 ollama serve
   ```

   - The Ollama desktop app has a context length slider in its settings. The
     app does not see a variable exported in a shell; on macOS,
     `launchctl setenv OLLAMA_CONTEXT_LENGTH 65536` and then restarting the
     app also works.
   - For the Linux service, run `sudo systemctl edit ollama.service`, add
     `Environment="OLLAMA_CONTEXT_LENGTH=65536"` under `[Service]`, then
     `sudo systemctl daemon-reload`.
   - On Windows, Ollama reads your user environment variables: set
     `OLLAMA_CONTEXT_LENGTH` there.
   - A Modelfile's `PARAMETER num_ctx N` (then
     `ollama create NAME -f Modelfile`) sets it for one model.

2. Restart Ollama.
3. Pull a model that can call tools. An agent that cannot call tools cannot
   read a file. [Ollama's model search](https://ollama.com/search?c=tools)
   lists the ones that can. For example, Gemma 4 12B, about an 8 GB
   download:

   ```sh
   ollama pull gemma4:12b
   ```

4. Start `lmx`. With no API key set, it picks the local model by itself and
   says so. With keys set, name the model with the full tag `ollama list`
   shows, quantization included: `lmx --model ollama:gemma4:12b`.
5. Once `lmx` has sent its first request, check the `CONTEXT` column of
   `ollama ps`. It shows the window the model really has.

A larger window costs memory, and a model that no longer fits on the GPU
runs slower. There is no switch to turn Ollama on and no key to set:
`req_llm` talks to the daemon at `http://localhost:11434/v1`, and `lmx run`
and `lmx explain` ask it too when no key is set. For an Ollama on another
machine, name the model and the address:
`lmx --model ollama:NAME --base-url http://HOST:11434/v1`.

In the terminal UI, `/model` and its completion, the provider panel and
`/provider ollama` offer only local models that can call tools, never an
embedding model such as `nomic-embed-text`; a tag the daemon lists without
its capabilities is offered too. Naming a model still selects it: `--model ollama:TAG`, or
`/model TAG` once the session is on Ollama. `/provider ollama` switches to
the Ollama model you pinned (`providers.ollama.model`) or used recently, when
the daemon serves it; otherwise to the model `lmx` would start on by itself:
one that can call tools, the most recently used, then the most recently
pulled. After a start that failed, it starts on the pinned model or that
pick, or says why it cannot (`Ollama did not answer; start it, then
/provider ollama tries again`). `ollama:llama3.2` and
`ollama:llama3.2:latest` name the same model.

### What lmx does with a local model

`lmx` talks to Ollama's OpenAI-compatible `/v1` endpoint, which cannot set
the window: Ollama ignores a per-request `num_ctx` there. So `lmx` asks the
daemon instead.

- Before a session's first request it reads `/api/ps` for a loaded model,
  else `/api/show` for a Modelfile `num_ctx`. After every answer it reads
  `/api/ps` again. It never loads a model or sends a prompt to ask, and each
  lookup gives up after 250 ms to connect and one second to answer.
- It plans compaction against the window the daemon serves, compacting at
  80% of it. That window replaces the 128,000-token guess `lmx` uses for a
  model nobody publishes a window for, and it caps a larger `--context-window`.
- Until Ollama has said, `lmx` says the session is planning against the
  128,000-token guess and that `ollama ps` shows the real window once the
  model is loaded. The terminal UI says it in a notice; `lmx run` prints it
  on standard error, like the two warnings below.
- When the served window leaves less than 8,192 tokens beyond the session's
  own instructions and tools, `lmx` warns once per model and window, and
  names the fix: set `OLLAMA_CONTEXT_LENGTH`, restart Ollama and check
  `ollama ps`.
- If the instructions and tools alone are over the compaction threshold,
  `lmx` does not try to compact on that threshold: no summary could get under
  it. If a summary leaves the next request still over the threshold, `lmx`
  stops summarising on its own for 32 requests and says so. `/compact` in
  the terminal UI still works, and a new window or model starts over.

`--context-window N` (or `"context_window"` in the config file) only tells
`lmx` how big the window is, for compaction planning. It cannot change what
Ollama serves, and a smaller served window wins anyway. Pass it only to match
what `ollama ps` shows.

### Long answers and long waits

Two limits differ for `ollama:` models, because a local model behaves
differently from a hosted API:

- **Answers are capped at 16,384 tokens** unless the request, the host or the
  model catalog sets another limit. A hosted API stops an answer at its
  model's own maximum; Ollama generates until the model stops, and a model
  that falls into repeating itself would otherwise never stop. The cap is a
  bound, not a cure: at the 18 tokens a second a 12B model managed on an
  M4 Pro, 16,384 tokens take about fifteen minutes. There is no `lmx` flag to
  change it yet.
- **A silence may last up to 15 minutes** before `lmx` calls the stream
  stalled; hosted models get 5 minutes. Ollama sends nothing while it reads a
  prompt, and reading is slow: measured prefill ran at 100–200 tokens a
  second, and a cold 32,000-token prompt took 324 seconds on a 27B model. A
  100,000-token request that misses Ollama's prompt cache can take 8 to
  16 minutes before its first token. The same limit applies between later
  tokens. On a machine with Ollama's 262,144-token default, `lmx` compacts at
  160,000 tokens, the same cap it applies to any large window
  ([Compaction](compaction.md)).

Neither applies to `ollama_cloud:` models or to a host that routes the
`ollama` provider elsewhere.

### Ollama Cloud

`OLLAMA_API_KEY` enables Ollama's hosted models under the logical provider
`ollama_cloud` (`ollama_cloud:MODEL`). The locked model
catalog publishes Ollama Cloud metadata before ReqLLM has a provider module
for it, so `Lemieux.ModelCatalog` keeps `ollama_cloud` as the logical
provider while routing requests through Ollama's documented
OpenAI-compatible `https://ollama.com/v1` endpoint, with `OLLAMA_API_KEY` as
the bearer token. Keeping the two providers apart means enabling Cloud never
sends an unauthenticated local `ollama:` model to the Cloud endpoint. The
terminal UI adds the models an authenticated `https://ollama.com/api/tags`
lookup returns.

### Local models in an embedding host

The adapter's local-model behaviour is three options of
`Lemieux.Providers.ReqLLM.new/1`. None of them applies when the `ollama`
provider is routed (`:route`, or a `:transport_routes` entry for `ollama`):

| Option | Default | What it does |
| --- | --- | --- |
| `:local_max_tokens` | `16_384` | The `max_tokens` an `ollama:` request carries when nothing else sets an output limit; `nil` sends none. Other uncatalogued models get no default: vLLM refuses a prompt plus `max_tokens` larger than its window, and OpenAI refuses `max_tokens` from reasoning models. |
| `:local_idle_timeout` | 15 minutes | The least an `ollama:` request's `:receive_timeout` and `:stream_idle_timeout` are raised to, for the whole answer. Never lowers them; `nil` leaves them alone. |
| `:ollama_window` | `true` | Whether to ask the daemon what window it serves (`Lemieux.Providers.OllamaWindow`). With `false`, `context_window/2` answers `nil` for `ollama:` models. |

After every `ollama:` answer the provider emits `{:context_window, tokens}`
before `{:done, _}`: the window the daemon served. A session plans against
it, replacing a window it discovered and capping one it was given, and
forgets it on a model change. The session events that report a window, a
small window and a summary that made no room are described in
[Compaction](compaction.md#how-much-room-there-is).

Embedders on hosted models keep the library's two-minute `:receive_timeout`
and should raise it for slow reasoning models.

## Gateways and routes

A host can send every model request through an API-compatible gateway with
`Lemieux.Providers.ReqLLM.new(base_url: url)`, or `--base-url URL`
(`LMX_BASE_URL`) in `lmx`. ReqLLM still chooses the wire protocol and appends
the provider's own path, so this is a provider API base, not an HTTP proxy.
Base URLs and credentials are runtime configuration: they are never written
into transcripts or benchmark artifacts.

[Ixway](ixway.md) is an optional gateway that owns all inference for a
session. Enable it with `--ixway`/`LMX_IXWAY_URL` or
`Lemieux.Ixway.provider(connection)`; its models are named `ixway:ID`.

### Routes

A gateway that owns discovery, selection and the destination is not a new
provider adapter; it is a `Lemieux.Provider.Route`. `Lemieux.Providers.ReqLLM`
takes `route: {module, state}` and asks the route which models exist, whether
a model may run with the session's tools, what the context window and the
reasoning-effort menu are, and what model specification and request options
each request goes out with. The adapter still encodes and streams every
request through `req_llm`. A route excludes direct credentials, base URLs and
transport routes, so a routed provider cannot fall back to a direct provider.
`Lemieux.Ixway` is the shipped route and builds the pair itself through
`Lemieux.Ixway.provider/2`; the adapter does not name it.

A route's failures are its own typed terms and pass through unchanged. One a
person will read should describe itself — an exception whose `message/1` is
the sentence, as `Lemieux.Ixway.Error` is — because `Lemieux.Provider.Error`
renders exceptions and knows no gateway's vocabulary.

Two optional callbacks are for the host that starts a session rather than
for the adapter: `ready/1` readies the route (discovery, a catalogue read)
and `default_model/1` names the model it advertises when nobody chose one.
`Lemieux.Provider.Route.prepare/2` runs them in the one order every host
uses — ready, resolve `NAME:@default`, check the model — and
`Lemieux.Providers.ReqLLM.prepare/2` does the same for a routed provider.
`Lemieux.Ixway.prepare/2` is that sequence for the shipped route.

In `lmx`, a route is **registered under a name** and the name is the
provider prefix of its models (`Lemieux.CLI.Routes`). Ixway is registered as
`ixway` when it is configured, and an extension `lmx` loads can register
routes of its own by exporting `routes/1` (`Lemieux.Extension.Routes`), with
no second binary: [Adding a model route](extensions.md#adding-a-model-route)
is the example. Both kinds then go through the same host code: the
terminal UI readies the start model's route before the screen opens,
`--model NAME:@default` resolves to the route's default, `--router NAME`
makes the route `lmx run`'s sole connection, `/provider NAME` and `/model`
list its models, and a request under one name never falls back to another
connection (`Lemieux.CLI.ProviderMux`). A route's credentials stay in its
own state; the transcript records which extension was loaded and nothing of
that state.

Lemieux does preflight deterministic provider rejection rules before handing
a request to `req_llm`. Anthropic custom-tool input schemas cannot use
top-level `oneOf`, `allOf` or `anyOf`, so an incompatible host or MCP tool is
rejected locally by its model-facing name. The schema is never rewritten, and
other wire providers continue to receive valid general JSON Schema unchanged.

## Validation matrix

Which provider paths the test suite exercises:

| Provider path | Automated fixtures | Opt-in live loop | Notes |
| --- | --- | --- | --- |
| Anthropic | Yes | Yes | The main development path; exercises tools, usage and thinking continuation |
| OpenAI | Yes | Yes | Same Lemieux provider module and transcript |
| Google | Yes | Yes | `GOOGLE_API_KEY` |
| Z.AI Coding Plan | Shared ReqLLM fixtures | Yes | `zai_coding_plan:glm-5.3` uses `ZAI_API_KEY` and ReqLLM's dedicated Coding Plan transport |
| Ollama | Yes | When a local server has a model | `lmx` asks the daemon for the window it serves; set `OLLAMA_CONTEXT_LENGTH` to 32768 or more (65536 recommended) |
| Ollama Cloud | Request and discovery fixtures | No | Logical provider `ollama_cloud`; bearer auth with `OLLAMA_API_KEY` against Ollama's OpenAI-compatible Cloud endpoint |
| xAI, OpenRouter, DeepSeek and other `req_llm` providers | Shared translation tests | No | Support is capability-based: a model needs tool calling to work as an agent. Validate the whole loop before relying on one |

`test/lemieux/live/providers_test.exs` drives a whole session against each
live row: prompt, tool call, tool result, answer and usage. It makes billed
requests, so it runs only when you ask for it on the command line:

```sh
LEMIEUX_ALLOW_SPEND=1 mise exec -- mix test --only live test/lemieux/live/providers_test.exs
```

A provider whose key is not exported skips rather than fails, so a green run
is not evidence that every row ran. The Ollama row uses the model
`LMX_OLLAMA_MODEL` names, else the first one the local server lists.

A model in the catalog proves neither that your account may use it nor that
it completes a tool loop. A long-lived deployment should also measure prompt
caching over a long session and watch cache-read tokens; that is too slow and
expensive for the package's CI.

## Pinning extraction transport and observing responses

A gateway that accepts Chat Completions should not inherit a model catalog's
choice of the Responses API. Pin its transport explicitly:

```elixir
provider = Lemieux.Providers.ReqLLM.new(
  api_key: gateway_key,
  api_key_provider: :openai,
  max_retries: 0,
  transport_routes: %{
    "openai" => [
      provider: "openai",
      base_url: gateway_url <> "/v1",
      wire_protocol: "openai_chat"
    ]
  },
  response_metadata: [
    headers: ["x-ixway-request-id", "x-ixway-resolved-backend", "retry-after"],
    model_header: "x-ixway-resolved-model"
  ]
)

Lemieux.start_session(
  provider: provider,
  model: "openai:gpt-5",
  tools: [],
  max_turns: 1,
  max_requests: 1,
  provider_retry: false,
  params: [output_validation: :strict],
  output_schema: [label: [type: :string, required: true]],
  subscriber: self()
)
```

The host must mount its supervisor and supply its ordinary store/environment
policy as usual. `output_schema` still uses ReqLLM's structured-output
implementation and model capabilities. Pinning the protocol does not certify
that an arbitrary model supports JSON Schema. `output_validation: :strict`
asks ReqLLM to reject invalid structured results; feature-specific business
validation still belongs to the host. `"openai_responses"` is the other
supported explicit pin; invalid pins fail without fallback. Unpinned routes
retain their previous behavior. Durable request parameters cannot replace the
host's transport route or its metadata disclosure configuration.

The native provider emits `{:response_metadata, metadata}` before a terminal
event or error return. Session subscribers receive it inside the usual
`{:lemieux, session_id, event}` envelope. It contains:

| Field | Meaning |
| --- | --- |
| `request_id` | Lemieux's request-entry id; nil when a direct provider caller supplied no correlation. |
| `requested_model` | The logical model specification in the request. |
| `resolved_model` | The configured response `model_header` value, or nil. |
| `status` | Observed HTTP status, or nil when unavailable. |
| `headers` | Selected lowercase names mapped to lists of values; empty by default. |

The resolved model is deliberately not copied from ReqLLM's model field:
the locked version can populate that field from the requested catalog model.
A gateway's explicit disclosure is needed to distinguish routing from a guess.
The model header need not also appear in `headers` unless the host selects it.

Metadata is ephemeral: Lemieux forwards it for ordinary attempts, retries and
compaction without adding transcript entries or treating it as model output.
Capture the gateway request id and resolved model in the host's existing audit
record. Error values remain typed and unchanged; metadata does not replace
them. HTTP rejections, including wrapped ReqLLM errors, retain their status and
selected headers. Request preparation failures before a transport attempt may
emit no response metadata.

The adapter reads ReqLLM's public metadata handle, with no global observer or
Finch internals. It waits at most 50 ms for a pending terminal metadata
reply after stream processing. A caller-only timeout can precede server
metadata availability; those fields stay unknown and the connection is still
closed. Server idle/total timeouts retain the terminal metadata when supplied.
Hard process cancellation cannot promise a final event. These limits keep
metadata observation from extending a failed request indefinitely.

`test/lemieux/providers/req_llm_response_test.exs` exercises the real local HTTP
path, schema-bearing Chat Completions, success, 429 and 503, host configuration
precedence and transcript privacy. The stream cleanup tests cover timeout
metadata and connection release. These fixtures make no paid provider calls.

## Credential-aware model discovery

`Lemieux.Provider.available_models/2` and the corresponding
`Lemieux.Session.available_models/1,2` functions return capability-compatible
models for credentials the provider can actually resolve. An ordinary `lmx`
provider reads ReqLLM's environment, application and OAuth configuration.
Discovery consults no vendor model-list endpoint, although an expired OAuth
credential may be refreshed by ReqLLM while it checks availability.

An embedding host that holds several API keys must keep their provider
identity. A scalar key has no such identity: ReqLLM treats it as the credential
for whichever provider is being queried, which would make unrelated catalog
providers appear configured and could spend the key against the wrong service
after an interactive model change. Use the map form instead:

```elixir
options =
  [api_keys: %{anthropic: tenant.anthropic_key, openai: tenant.openai_key}]
  |> Keyword.merge(Lemieux.ModelCatalog.provider_options())

provider = Lemieux.Providers.ReqLLM.new(options)
models = Lemieux.Provider.available_models(provider, require: [chat: true, tools: true])
```

The compatibility profile is opt-in. It currently carries transport routes
and no catalog fallbacks. A future fallback is valid only with any paired route
needed to make it usable; advertising one globally without that route would
claim support the provider path does not have.

An explicit map is also an authority boundary: a missing provider does not
fall through to an ambient process key. Provider state has a redacted inspect
representation, and discovery returns only model specifications—not keys,
sources, endpoints or headers. A gateway credential usable through several
logical provider protocols must be entered under each provider intentionally;
`:transport_routes` controls the wire encoder and endpoint, and may name an
existing credential identity for a logical catalog provider. It never contains
the credential itself.

A scalar `:api_key` suits an embedder fixed to one provider. Pair it with
`api_key_provider: :anthropic` if a model might change; a request for
another provider is then refused before it is sent. An unscoped scalar key
does not make every provider appear in discovery; a catalog query scoped to
one provider still works.

Catalog fallbacks are host-confirmed exceptions for models accepted upstream
before the locked llm_db snapshot includes them. They appear only when their
provider is credentialed, after canonical catalog choices so `/provider` does
not silently select an exceptional model as that provider's default. Installed
local models remain a separate host discovery concern: an LLMDB row cannot say
whether an Ollama tag is actually present on this machine.

Unknown USD cost is not evidence of a subscription plan. ReqLLM may use OAuth
or another unpriced path, but it currently exposes no stable session/weekly
allowance contract to Lemieux. The TUI reports provider tokens and `cost
unmeasured`; it does not fabricate a quota percentage. A quota display needs
provider- or host-supplied remaining/reset data first.

## Shared provider admission

Every mounted `Lemieux.Supervisor` includes a `Lemieux.ProviderLimiter` used by
ordinary sessions and subagent children. It bounds concurrent requests and can
enforce a token bucket per host-supplied rate-domain key. Queueing happens in
the supervised provider task, so sessions continue to answer cancellation and
inspection while waiting. Monitors release abandoned leases after a crash.

The limiter is the shipped implementation of `Lemieux.Provider.Admission`,
which owns admission and fairness and not retries. A host that meters
differently passes `provider_limiter: {MyAdmission, opts}` when mounting; the
module starts under the same child name and
`Lemieux.Supervisor.provider_admission/1` returns the `{module, ref}` pair
sessions call through. A keyword list still configures the shipped limiter.

Sizing `req_llm`'s shared HTTP stream pool is the host's call, made before
mounting: `Lemieux.ProviderPool.ensure/1` writes another application's
environment and may restart it, so the supervisor does not do it on mount.
`lmx` calls it from `Lemieux.CLI.configure/0`. A host that sets
`config :req_llm, stream_pool_size: N` (at least its concurrency) before
mounting needs no restart at all.

Lemieux cannot infer that two provider structs share a credential, account, or
gateway quota. A multi-tenant host must therefore choose the limiter process
and `:provider_limit_key` at its own credential boundary. The mount-local
default is appropriate for `lmx` and a single-tenant host; token rate remains
unlimited until the host supplies a measured `:tokens_per_interval`. Estimated
tokens are reserved before a call and reconciled from actual usage afterward;
a request larger than a finite bucket fails visibly instead of waiting forever.
When a typed provider failure carries `Retry-After`, the limiter delays later
requests in that same rate domain. The failed request itself remains failed;
Lemieux does not replay a possibly partial semantic stream.

## Typed failures and context overflow

Provider events keep the original failure term. `Lemieux.Provider.Error`
derives a display message, HTTP status, stable category and retry delay without
wrapping or flattening ReqLLM's exception. Subscribers and error hooks can
therefore make policy decisions from the typed value; persisted error entries
contain only its human-readable projection.

A context overflow may trigger one forced compaction and retry per prompt,
only when the provider emitted no semantic event. Most providers mark an
overflow with a code (`context_length_exceeded` and its relatives), which
`Lemieux.Provider.Error.context_limit?/1` reads wherever it appears. Anthropic
and Gemini give theirs no code, only a sentence in a generic `400`, so the
adapter recognises those sentences with
`Lemieux.Provider.Error.recognize_overflow/2`, scoped three ways so prose is
never classified at large: only for the provider the request actually went
to, only with the status that provider refuses with, and only in that
provider's own words (Anthropic's "prompt is too long", Gemini's "exceeds the
maximum number of tokens allowed", the OpenAI-compatible "maximum context
length is N", Z.AI's code `1261`, and a few more). A recognised failure is
`{:context_limit, original}` with the typed term whole inside it.

The refusal is often the only authoritative statement of a model's window a
session ever gets. `Lemieux.Provider.Error.stated_context_window/1` reads it
("… > 200000 maximum", "… tokens allowed (1048576)", "maximum context length
is 128000"), only from a failure already classified as an overflow. For a
model the catalog does not know at all — newer than the bundled `llm_db`, or
served under a name nobody published — `Lemieux.Provider.context_window/2`
still answers `nil`, and `Lemieux.Provider.planning_window/2` answers
`{128_000, :fallback}` for a host that would rather compact early than run
into a refusal, and wants to say that the number is a guess. A local Ollama
model is the exception: the adapter asks the daemon what window it serves
([Use a local model](#use-a-local-model)), because Ollama truncates silently
rather than refusing, so no overflow ever arrives to correct a guess.

How a failure that arrives after output has begun is handled — kept as a
checkpoint, retried or left to `/retry` — is the session's `:provider_retry`
policy, not the adapter's.

Which failures are worth a transport-level retry is
`Lemieux.Provider.Error.transient?/2`. Without a classifier it is the
built-in rule: a server error (a dropped connection and an interrupted stream
count as one), a rate limit, a stalled stream (an HTTP `408` is one, seen
from the server's end, and is classified `:timeout`), or a typed `retryable`
flag. A
host whose gateway means something else by a status passes a classifier,
`(reason -> :transient | :fatal | :default)`, through the session's
`:provider_retry` option as `classify:`; its verdict wins in either direction
and `:default` falls back to the built-in rule, so it only has to know the
cases it disagrees with. Timing — attempts and delays — stays with
`:provider_retry`.

### Streams that end badly

Two failures reach the adapter looking like success, and it reports both as
`Lemieux.Provider.Interrupted`, a retryable failure classified as `:server`:

- An OpenAI-compatible server that fails mid-answer sends an error event
  inside its `200` stream, which ReqLLM turns into finish reason `:error`. The
  provider's sentence is kept as the failure's `detail`.
- Anthropic sends `event: error` (`overloaded_error`) and closes the stream,
  which ReqLLM's decoder skips. A Claude stream that ends without the
  `message_delta`/`message_stop` every complete answer carries is therefore
  treated as cut off. The rule is limited to Claude's wire format, where the
  marker is known to arrive; elsewhere a missing marker proves nothing.

What did arrive is emitted first as `{:message, payload}` with
`"partial" => true`, plus any usage the provider reported: the fragment keeps
the signatures of thinking blocks that completed, and the tokens were billed
whether or not the answer finished. A dropped connection (`:closed`,
`:econnreset` and their kin) is classified `:server` too; a refusal arrives
with a status and a body, a reset does not.

A `200` stream that carries nothing at all — no content, no tool call, no
usage — and ends `:incomplete` is the same cut one step earlier, before the
first token. The adapter reports it as `{:unanswered, model, :incomplete}`
rather than a finished turn (a session would otherwise answer with a blank
line and go idle), and `Lemieux.Provider.Error` classifies it `:server`, so
the session's bounded retry asks again — unless the session is under
`:max_cost_usd` and the failed attempt left spend unknown, which a stream
that reported no usage does: the dollar gate refuses to retry on unknown
spend, and a host's category-based retry is what applies there. OpenAI
refuses a request on an
account with no credit in exactly this shape; that refusal repeats, and
after the retries the failure's sentence still says to check credit, quota
and request validity. An empty stream that ends `:length` or
`:content_filter` stays `:other`: the provider finished on purpose.

### Replaying a transcript

`Lemieux.Providers.ReqLLM.context/2` applies two rules on top of translating
entries:

- **An abandoned attempt is not the last word.** An assistant entry without
  tool calls that a provider failure followed (or that carries `"partial"`)
  is left out when nothing the person said came after it — a retry resends
  the conversation without its own half-answer, and a successful retry does
  not sit beside the fragment it replaced. Sent, that fragment would be a
  prefill Claude continues instead of answering (and refuses under extended
  thinking), or a final assistant message Mistral rejects. A fragment the
  person has since replied to stays, like a cancelled turn's checkpoint.
- **Claude receives no unsigned thinking.** Signed thinking travels in the
  entry's `reasoning_details`; thinking *content* — cut off mid-thought, or
  written by another provider before a model switch — has no signature, and
  Anthropic refuses the whole request over it. For Claude wires (Anthropic,
  and Claude on Bedrock, Vertex and Azure) it is dropped unless the turn's
  Anthropic details are signed. Other thinking models still receive it as
  their reasoning content.

An assistant turn left with only thinking and no tool calls is not sent: it
says nothing the conversation needs.

### Images and documents from tools

A tool result's `"attachments"` (see
[tool contracts](tool-contracts.md#images-and-documents)) are sent where each
wire expects them:

- **Inside the tool result** for Claude (Anthropic, and Claude on Bedrock,
  Vertex and Azure), Gemini, and Bedrock's Converse, which all accept image
  and document blocks there.
- **In one user message after the run of tool results** everywhere else. An
  OpenAI-compatible chat wire refuses an image in a tool message, and nothing
  may come between the results of one assistant turn's calls, so each run's
  attachments follow it together, each labelled with the call it came from.

An image for a model the catalog says cannot view images is replaced by a
sentence saying so, for a prompt's `@` attachments as well as a tool's.
Otherwise a `/model` switch to a text-only model would make every later
request fail. A model the catalog has no data for still receives what was
attached. `Lemieux.Providers.ReqLLM.input_modalities/2` is the catalog's
answer (`[:text, :image, :pdf]` or `:unknown`), and a session asks it before a
tool attaches anything. Routed models answer `:unknown`.

### Tool-call arguments

A model often fills an optional parameter it means to leave out with `null`
or `""`. The adapter drops those for properties the tool's schema declares
and does not require, so every tool sees the argument as absent instead of
each tool learning to ignore it. Required properties keep `""` (a real value
for `edit`'s `new`), and undeclared properties are left for the tool to
refuse.

## Prompt caching

An agent loop resends its whole prefix on every request. For every Claude
target the adapter sends directly — `anthropic:`, and Claude models on
`amazon_bedrock`, `google_vertex` and `azure` — it turns on ReqLLM's
`anthropic_prompt_cache` with a rolling `anthropic_cache_messages: -1`
breakpoint: the tools, the system prompt and the last message each carry
`cache_control`, so every request reads the prefix the previous one wrote,
at a tenth of the input price. Cache reads and writes appear in usage as
`cache_read_tokens` and `cache_write_tokens`. Pass
`anthropic_prompt_cache: false` in provider options or request params to turn
it off. Routed requests are left as the route shapes them, and no other
provider is sent the options, which it would reject as unknown.

## Cost estimates

The adapter's cost estimate (`Lemieux.Provider.estimate_cost/2`), which a
session's `:max_cost_usd` gate uses, is a realistic upper estimate rather than
a worst case:

- **Input** comes from the last request that reported usage — its measured
  input, plus the answer it produced, plus about a token per four bytes of
  whatever was added since — or, before any measurement, from the request's
  bytes. The cache share that request observed is priced at the cached rate.
- **Output** is the request's explicit `max_tokens`, or else twice the
  largest answer the conversation has produced, at least 8,192 tokens and
  never above the model's output limit.

Pricing every byte as a token and reserving the model's whole output limit
would cost about a dollar a request on a Sonnet-class model, which would stop
a `$5` session after two or three turns. Unknown pricing answers `nil`, and
the gate refuses rather than treating it as free.

When ReqLLM cannot resolve the model's catalog tariff for the request, the
estimate falls back to the model's flat list rates (`cost` in the catalog:
what the standard tier charges, and what the first tier of a long-context
tariff charges), and the usage a direct request reports is priced the same
way, with `pricing.status` set to `"list_rates"` so a host can tell it from
ReqLLM's own `"priced"`. This is not a corner case. A tariff with a
data-residency, flex or priority modifier that no pricing context answers is
one ReqLLM 1.26 refuses to price at all, and under Lemieux's default context
that is 34 of the catalog's priced models: the current Anthropic frontier
(`claude-fable-5-1`, `claude-opus-5`, `claude-opus-5-5`, `claude-sonnet-5`),
OpenAI's gpt-5.6 and gpt-6 families, `google:gemini-3.1-pro-preview`, xAI's
grok-4.3 and later, DeepSeek v4, MiniMax M3 and Alibaba's qwen3.6/3.7 among
them. The assumption is the standard tier: a request on a batch or priority
tier, past a long-context threshold, or writing a one-hour cache (twice the
five-minute rate the catalog's `cache_write` holds) is estimated at list
price rather than refused. Reasoning tokens are priced as ReqLLM prices them:
at the model's reasoning rate when it publishes one, at the output rate when
the provider bills them beside output (Gemini), and not again when they are
already inside `output_tokens` (OpenAI).

What is not a price is not a fallback. A model with no list rates, negative
ones (OpenRouter's routers carry a sentinel of -1,000,000) or rates not in
USD (Z.AI's coding plan is priced in credits) still answers `nil`, and the
budget stop names it (`no price is known for openrouter:openrouter/auto`).
Usage that is not whole — a count the provider did not report, or cache
counts that do not add up, which ReqLLM records as `usage_reported` and
`billing_usage_complete` — is left unpriced, so unknown spend stays unknown
and a capped session stops rather than spending against a wrong total
(`Lemieux.Providers.ReqLLM.price_at_list_rates/2` is the rule). Routed
requests are left as the route priced them.
