# Configuration

`lmx` takes its settings from flags, from `LMX_*` environment variables and
from an optional JSON file, `~/.lmx/config.json`. For a new session, flags
beat environment variables, and both beat the file. This page is the
reference for the file and for the defaults `lmx` turns on. [CLI and terminal
UI](cli.md) lists the flags and environment variables, and the [trust
model](../SECURITY.md#what-lmx-trusts-by-default) says what runs without
asking.

An application that embeds Lemieux (a *host*, in these docs) has the same
mechanisms as Elixir options; see [Embedding Lemieux](embedding.md). For a
first change, start with [Customizing Lemieux](customization.md).

## Settings at a glance

Every key `~/.lmx/config.json` accepts, and what applies when it is absent.

**Models and routing**

| Key | Default | What it does |
| --- | --- | --- |
| `model` | none | The model new sessions start on; see [Which model lmx starts on](#which-model-lmx-starts-on) |
| `providers` | none | Per provider (`anthropic`, `openai`, `ollama_cloud`, …): an optional `api_key`, `model` and `effort` |
| `base_url` | none | A provider-compatible API gateway ([API gateways](#api-gateways)) |
| `ixway` | off | The Ixway route: `enabled`, `endpoint`, `api_key`, `model`, `effort` and routing `headers` ([Ixway](ixway.md)) |
| `system` | the library's default prompt | The base system prompt for new sessions ([System prompts](#system-prompts)) |
| `scout_model` | the session's model | The model the repository scout runs on ([Delegated investigations](#delegated-investigations)) |
| `version` | `1` | The file's schema version |

**Limits** ([Session limits](cli.md#session-limits))

| Key | Default | What it does |
| --- | --- | --- |
| `max_turns` | `400` | Model turns per prompt |
| `max_requests` | none | Provider requests per session, retries and compaction included |
| `max_cost_usd` | none | A dollar ceiling; an unknown cost stops the session rather than counting as zero |

**Context and compaction**

| Key | Default | What it does |
| --- | --- | --- |
| `context_window` | none | The model's window in tokens, for a model nothing knows about; without it, compaction plans against 128,000 tokens |
| `auto_compaction` | `true` | `false`: the session never compacts on its own; `/compact` still works |
| `keep_recent_tokens` | none | About how many tokens of recent conversation a compaction keeps ([Choosing a cut](compaction.md#choosing-a-cut)) |
| `summary_model` | the session's model | A different model for compaction summaries |
| `compaction_price_tiers` | none | Price bands per model, so compaction happens before a price cliff ([A price cliff](compaction.md#a-price-cliff)) |
| `systemone_compaction` | `{"mode": "auto"}` | A System One model shortens old file reads before a request; `provider` chooses which, and it is on only when that provider is complete ([System One compaction](#system-one-compaction)) |
| `systemone_providers` | none | System One providers declared once, by name, for every feature that asks one: `{"local": {"base_url": "http://127.0.0.1:11434", "model": "clef-flash"}}`, or `typesafe` and `ixway` settings ([System One providers](#system-one-providers)) |

Embedding hosts can configure preflight, price-aware and advisory compaction
through the session API. See [Compaction and price-aware
preflight](compaction.md) for the options and an Ixway timing-signal example.

**Tools and safety**

| Key | Default | What it does |
| --- | --- | --- |
| `permissions` | off | Ask before tools change things ([Permissions](#permissions)) |
| `sandbox` | off | Run commands in an operating-system sandbox ([The sandbox](#the-sandbox)) |
| `scrub_credentials` | `true` | Withhold credential-shaped variables from commands, hooks and MCP servers ([Credential scrubbing](#credential-scrubbing)) |
| `credential_allowlist` | none | Variable names, or `NAME_*` patterns, passed through anyway |
| `hooks` | none | Command hooks, in `lmx`'s format or Claude Code's ([Hooks](#hooks-and-approval-policy)) |
| `verify` | on | The project's check after a turn that edited files: `false`, or `{"command", "max_continuations", "timeout_ms"}` ([Checks after edits](#checks-after-edits)) |
| `delegate` | `true` | `false` withholds the repository scout |
| `web_search` | on when a Brave key is set | `"brave"`, or `"none"` to turn search off ([Web search](#web-search)) |
| `web_search_providers` | none | Search keys by provider: `{"brave": {"api_key": "…"}}` |
| `web_fetch` | on when web search is on | `false` turns page reading off |
| `input_modalities` | the model catalog's | `["text", "image", "pdf"]`, for a local vision model the catalog does not know |

**Workspace, MCP and extensions**

| Key | Default | What it does |
| --- | --- | --- |
| `project_mcp` | starts once trusted | `false` never starts the repository's `.mcp.json` ([Repository MCP servers wait for trust](#repository-mcp-servers-wait-for-trust)) |
| `mcp_servers` | none | Your own MCP servers, shaped like `.mcp.json` ([MCP servers](#mcp-servers)) |
| `mcp_discovery` | `"auto"` | `"auto"` hides large MCP tool schemas behind `mcp_discover` while they would crowd a request; `"on"` or `"off"` |
| `plugin_dirs`, `marketplaces`, `plugins` | none | Saved plugin selections; `lmx plugin install` adds one ([Plugins](#claude-compatible-plugins-and-marketplaces)) |
| `extensions` | none | Your own extensions to load every time, by name ([Your own extensions](#your-own-extensions)) |
| `extension_options` | none | `{"NAME": {...}}`, merged over an extension's own options |
| `disabled_extensions` | none | Shipped extensions to leave out ([Defaults](#defaults-lmx-turns-on-and-the-keys-that-change-them)) |
| `skills` | Omarchy's skills read, none disabled | `{"omarchy": false}` stops reading Omarchy's skills; `{"disabled": ["NAME"]}` leaves skills out by name ([Agent Skills](#agent-skills-and-legacy-commands)) |
| `a2a_peers` | none | Other agents `lmx` may ask, through `/a2a` and the `ask_agent` tool ([A2A](a2a.md#ask-a-configured-peer-from-lmx)) |
| `sessions_dir` | `~/.lmx/sessions` | The transcript directory; `~` is expanded |

**Terminal UI** ([Customizing the terminal UI](terminal-ui.md))

| Key | Default | What it does |
| --- | --- | --- |
| `theme` | detected | `"dark"`, `"light"`, `"mono"` or a name from `themes`, used from the first frame without asking the terminal anything. Without it, a terminal that reports a light background starts in `light`, any other in `dark` |
| `themes` | none | Palettes of your own ([Adding a theme](terminal-ui.md#adding-a-theme)) |
| `keys` | the shipped bindings | Key bindings of your own, such as `{"ctrl-j": "submit"}` ([Rebinding keys](terminal-ui.md#rebinding-keys)) |
| `processing` | the shipped word list | The words the live row calls a running turn; a list of one keeps a single word |
| `mouse` | `true` | `false` gives the mouse back to the terminal |
| `notifications` | `true` | `false` stops the notification when a turn ends or needs you |

## Personal configuration

The first `lmx` command that needs settings creates `~/.lmx/config.json` when
it is missing:

```json
{
  "version": 1,
  "providers": {},
  "ixway": {
    "enabled": false
  }
}
```

The directory is created with mode `0700` and the file with `0600`; an
existing file is never replaced. The file is JSON data and never runs code.
A file that holds keys must be readable only by you, and no config file may
be writable by other users: `lmx` refuses to start otherwise. If the default
file cannot be created (a read-only home directory, a container), `lmx` runs
on built-in defaults and says so (`Could not create PATH (REASON); using
built-in defaults for this run.`). Set `LMX_HOME` and `LMX_SESSIONS_DIR` to
writable directories to give it somewhere to keep state and transcripts.

An example that pins OpenAI's model and effort, keeps the key in the
environment and caps requests:

```json
{
  "version": 1,
  "providers": {
    "openai": {"model": "openai:gpt-6-sol", "effort": "high"}
  },
  "max_requests": 20
}
```

Each provider section takes an optional `api_key`, `model` and `effort`;
`"providers": {"openai": {"api_key": "YOUR_OPENAI_KEY"}}` saves a key. The
first-run panel of the terminal UI (the TUI, which bare `lmx` opens) writes the
key and model for you. Gateway routing is separate and optional; see
[Ixway](ixway.md) for a complete gateway example.

**Another file, or none.** `--config PATH` or `LMX_CONFIG=PATH` reads another
file, which must exist. `--config none` (or `LMX_CONFIG=none`) reads no file
and creates none ([Running with no configuration](#running-with-no-configuration)).
The directory the config file is in is also the state directory, where `lmx`
keeps history, checkpoints and decisions, unless `LMX_HOME` names another.

**Precedence.** Flags beat environment variables, which beat the file.
Provider keys follow the same rule: a key in the environment (or in
`req_llm`'s own configuration) wins over one saved under `providers`, and a
variable set to an empty value switches the saved key off. An `LMX_*`
variable that is empty or blank is different: it counts as unset, so the
file's value applies, except that the switches `LMX_WEB_FETCH`,
`LMX_PROJECT_MCP` and `LMX_DELEGATE` read an empty value as off. `IXWAY_API_KEY`
overrides `ixway.api_key`, `JEV_API_KEY` overrides
`systemone_providers.typesafe.api_key`,
the variable a System One provider's `api_key_env` names overrides that
provider's `api_key`, and `BRAVE_SEARCH_API_KEY` overrides
`web_search_providers.brave.api_key`. Which System One provider compaction
uses is chosen in the file alone (`systemone_compaction.provider`);
there is no flag or variable for it.
Keys stay in host state: they are never written to transcripts or request
snapshots.

**`.env` files.** The installed `lmx` never reads a `.env` file, so keys
belong in your shell's environment or in this file. A source run reads the
checkout's own `.env` ([Environment variables](cli.md#environment-variables)).

**Mistakes.** Malformed JSON, a missing file you named, or unsafe permissions
stop startup. An unknown key is named at startup, with a suggestion, and
ignored, except a likely misspelling of a routing or credential field
(`model`, `providers`, `base_url`, `ixway`, `systemone_compaction`,
`systemone_providers`) and the retired `api_keys`,
`preferred_models`, `jev_compaction` and `jev_compaction_providers`, which
stop startup with a sentence saying where their contents moved. Inside a section such as
`providers`, `ixway` or `permissions`, any unknown key stops startup. So does
a value a field cannot take, and the message names the field down to its key
and what it takes: `Invalid lmx config field: ixway.enabled. It must be true
or false.` An `api_key` left empty (`"api_key": ""`) is a placeholder, not a
mistake: it is named at startup (`Empty field "ixway.api_key" in the lmx
config; it is ignored`) and read as no key, so the file loads and the panel
that saves a real key can open. Supply the key, or remove the placeholder.

**Routing** is chosen at the highest layer that makes a choice: `--router`,
`--ixway` or `--base-url`; then `LMX_ROUTER`, `LMX_IXWAY_URL` or
`LMX_BASE_URL`; then the file. Conflicting choices in one layer are an error.
`--router` takes `direct`, `ixway`, or the name of a model route an
extension registers ([Adding a model route](extensions.md#adding-a-model-route)):
`--router relay` sends `lmx run` through that route alone and starts on its
advertised default, or on `"model"`/`providers.relay.model` when the file
names one of its models; a name no loaded extension registers stops the
start with a sentence. For example, `--router direct` turns a saved Ixway
route off for one command:

```sh
lmx --router direct --model anthropic:claude-sonnet-5
lmx --router ixway
lmx --config /private/path/config.json
lmx --config none
```

With `ixway.enabled: true`, Ixway is the default inference route. The TUI also
offers direct providers with configured credentials, and switching to one
selects its own connection. `lmx run` keeps Ixway as its sole
route until `--router direct` is selected. Set `ixway.enabled` to `false` to
retain the connection for later without enabling it. If `ixway.model` is
omitted, an `ixway:` top-level `model` applies; otherwise Lemieux asks for the
gateway's advertised default. A saved direct-provider model does not interfere
with enabling Ixway. See [Ixway](ixway.md) for selection, capability,
accounting, and failure behavior.

**On resume.** The file's model, effort and system prompt apply to new
conversations. A resumed one keeps its transcript's unless a flag or a
command in the session changes them; current credentials and routing always
apply ([Resume precedence](#resume-precedence)).

**Data, not code.** Three keys stand in for something the screen would
otherwise decide, and all three are data: `themes` is colours, `keys` maps key
names to actions, `processing` is words. The status line, the follow-up hint,
tool receipts, slash commands and the screen layout are code; they reach the
screen as an embedding host's options or through an extension
([Customizing the terminal UI](terminal-ui.md)), because a config file that
named a module would be a config file that loads code.

## Defaults lmx turns on, and the keys that change them

A new session in `lmx` (the terminal UI and `lmx run`) gets, beside the
library's four tools (`read`, `write`, `edit`, `bash`):

- `grep` and `glob` (`Lemieux.Extensions.Search`), and the `todo` plan tool
  (`Lemieux.Extensions.Planning`). A resumed session keeps the tools its
  transcript recorded.
- `apply_patch` instead of `edit` on GPT-5-family models
  (`Lemieux.Extensions.ApplyPatch`).
- `ask_user`, in the terminal UI.
- The read-only repository scout ([Delegated investigations](#delegated-investigations)).
- Web search and page fetch, when a Brave key is set ([Web search](#web-search)).
- Credential scrubbing ([below](#credential-scrubbing)).
- Your MCP servers, the plugins you selected, and the repository's
  `.mcp.json` once you trust it.
- With a state directory (`LMX_HOME`, or the config file's directory,
  `~/.lmx`): an environment block in the prompt (date, platform, shell,
  directory, git state), the [check after edits](#checks-after-edits), and
  checkpoints for `/undo`, `/rewind` and `/redo`. Checkpoints keep the
  earlier contents of every file the agent's file tools changed (up to 10 MB
  a file, `.env` files included) in `~/.lmx/checkpoints` until you delete
  them; nothing prunes them. What commands changed is kept as unreferenced
  objects in the repository's own `.git/objects` until `git gc` prunes them;
  the snapshots run git in a private git directory, so nothing the
  repository configures (a hook, a filter, `core.fsmonitor`) runs.
  [Taking changes back](everyday.md#taking-changes-back) says what `/undo`
  can and cannot put back.
- [System One compaction](#system-one-compaction), when its provider is set up.

Off by default: [permissions](#permissions) (every tool call runs without
asking, which the startup banner calls "full auto"), [the
sandbox](#the-sandbox), and hooks.

`"disabled_extensions"` leaves shipped extensions out by name: `planning`,
`verify`, `search`, `apply_patch`, `checkpoints`, `environment_context`,
`mcp_discovery`, `mcp`, `interactive`, `web`, `elixir`, `workspace`,
`delegation`, `a2a` and `systemone_compaction`. Your own extensions and an
embedding host's policy are not affected.

### Running with no configuration

`--config none` (or `LMX_CONFIG=none`) runs `lmx` without your settings, for
a script, a test or a clean comparison. It reads no config file and keeps no
state: no input history, checkpoints, log file, MCP trust, permission rules
or remembered model. It also skips the environment block and the check after
edits, picks no model from your keys or a local Ollama (it starts on
`anthropic:claude-sonnet-5` unless `--model` or `LMX_MODEL` names another),
reads no personal instruction files or skills (nor Omarchy's), and starts the
repository's MCP servers only with `--project-mcp`.

It is not write-free. The transcript is still written, to `~/.lmx/sessions`
unless `--sessions-dir` or `LMX_SESSIONS_DIR` names another directory; a
remote marketplace is still fetched into the user cache; an MCP server that
signs in still keeps its token in `~/.lmx/mcp-credentials.json`
(`--credentials` or `LMX_CREDENTIALS` moves it); and a crash dump still goes
to `~/.lmx/crash` (`ERL_CRASH_DUMP` moves it). With `LMX_HOME` set, the run
has a state directory again, and with it the remembered model and the
choice of a model from your keys or a local Ollama; only the config file is
left unread.

### System One providers

A System One model answers typed questions about a state (`noul` yes/no,
`choice` among options, `score` on a scale) with calibrated probabilities
over `POST /v1/systemone`. Several features ask one: the bundled compaction
step below, and the computer-use and research examples. Their providers are
declared once, in `"systemone_providers"`, and each feature selects its own
by name, so they can differ — a small local model for compaction, a stronger
one for browser actions — and two entries can point at one server with
different models. An entry nobody selects receives nothing.

### System One compaction

`lmx` bundles an extension that asks a System One model whether old, long
file reads in the conversation are still needed, and shortens the ones it
marks as not needed in the next request to the model. It sends nothing until
the selected provider is complete.

`"systemone_compaction"` holds the choice and the budget (`mode`, `provider`,
`max_evaluations`, `max_cost_usd`, `reservation_per_call_usd`), and
`"systemone_providers"` holds what each provider needs, the way
`"web_search"` and `"web_search_providers"` divide search. Two providers are
built in:

- **`typesafe`**, TypeSafe's hosted Jev: `JEV_API_KEY` in the environment
  `lmx` runs in, or `systemone_providers.typesafe.api_key` in
  `~/.lmx/config.json`.
- **`ixway`**, an Ixway gateway: an endpoint (the entry's `base_url`, or the
  Ixway route `lmx` uses), the entry's `model` and the Ixway key
  (`IXWAY_API_KEY` or `ixway.api_key`). The same request then goes to that
  endpoint, never to TypeSafe.

Any other name is a provider you declare: a service that implements
`POST /v1/systemone`, with a `base_url`, a `model`, and if it wants one a key
(`api_key`, or `api_key_env` naming a variable in your shell, with
`api_key_header` when the service wants it in a header rather than as a
bearer token), plus `headers` and a tariff. An open model served by Ollama on
your own machine needs only that:

```json
{
  "systemone_compaction": {"provider": "local"},
  "systemone_providers": {
    "local": {"base_url": "http://127.0.0.1:11434", "model": "clef-flash",
              "input_per_million": 0.0, "output_per_million": 0.0}
  }
}
```

With the selected provider complete, the default `"mode": "auto"` switches
the step on with no other setting. With no `provider`, `lmx` chooses between
the built-in two: Ixway when its endpoint and a model are set, TypeSafe when
its key is; a declared provider is never chosen that way, and its entry
sends nothing until `provider` names it. There is no fallback from one
provider to another, and a provider without a declared tariff makes no
evaluation under a dollar cap. [Declaring a
provider](compaction.md#declaring-a-provider) lists each entry's keys. The
installed `lmx` never reads a working directory's `.env`, so a repository
you open cannot supply a key or an endpoint.

**When it sends something.** Before a model request, and only when all of
this holds: the request contains successful `read` results of at least 1,000
characters that are older than its six most recent entries (and are not
`AGENTS.md` or `SKILL.md`); there are at most 20 of them; the session has made
fewer than three evaluations; and the request is not a retry and has not
been evaluated before. Each evaluation is one HTTP request,
`POST /v1/systemone` under the selected provider's URL, with the provider's
key as a bearer token (or in its `api_key_header`) if it has one, no
retries, no redirects and a 15-second timeout.

**What it sends**, in a body of at most 60 KB (a larger one is not sent):

- the model name and a fixed instruction;
- the text of every user and assistant message in the request, each longer
  than 500 bytes cut to its first and last 250 characters, with the last
  three user messages repeated as the goal;
- the summary of the earlier conversation, if compaction wrote one, cut the
  same way;
- for each candidate result: the tool name, its arguments as JSON (at most
  500 characters, usually a file path) and the result's length.

It does not send tool results, nothing else from the system prompt, and no
credential other than its own key. The abridged messages and summary can
still quote files or code that were pasted into the conversation.

**What it changes.** A result the scorer scores below 0.1 is cut, in the
outgoing request only, to its first 160 characters and a note telling the
model to run the tool again if it needs the contents. The transcript keeps
the full output and records each evaluation (entry ids, digests, scores,
estimated savings, usage and latency), never tool output or credentials. The
provider bills each evaluation, and the known cost counts toward
`--max-cost-usd`; a provider with no declared tariff makes no evaluation
under a cap.

**Turning it off.** `"systemone_compaction": {"mode": "off"}`, or
`"disabled_extensions": ["systemone_compaction"]`, or no complete provider.
`"mode": "shadow"` still sends the same data but never shortens anything.
From a source checkout it is included only when you run from `dist/lmx`, a
Mix project with its own dependencies:
`cd dist/lmx && mise exec -- mix deps.get && mise exec -- mix lmx`
([From a source checkout](cli.md#from-a-source-checkout)). That run reads no
`.env`, so keep keys in your shell or in `~/.lmx/config.json`. At the
repository root, a `systemone_compaction` setting other than `"mode": "off"`
stops the start with a message saying so.

**Moving from Jev compaction.** The step was called Jev compaction, under
`"jev_compaction"`; that key now stops the start with a sentence naming the
new ones. The TypeSafe key moves to
`systemone_providers.typesafe.api_key`, the Ixway endpoint to
`systemone_providers.ixway.base_url`, and a model or tariff to the
selected provider's entry; [Compaction](compaction.md#moving-from-jev-compaction)
has the whole table. The
[extension's README](https://github.com/houllette/lemieux/blob/main/dist/lmx/extensions/systemone_compaction/README.md)
and [Compaction](compaction.md#optional-system-one-projection-before-compaction)
cover its remaining settings.

### Checks after edits

After a turn that edited files, `lmx` runs the project's own check and sends a
failure back to the model, at most twice per prompt. The check is found from
the project's conventions (`tests/run.sh`, a `Makefile` `test` or `check`
target, `mix test`, the `package.json` test script, `cargo test`,
`go test ./...`, `pytest -q`, Gradle or Maven), or set with
`"verify": {"command": "make check"}`. `"verify": false` turns it off, and
`/verify off` turns it off for the session. A project with no convention gets
no check.

The check is a command the repository chose, so it runs under the same rules
as a command the model runs: it goes to the session's hooks and permission
policy as `Bash(<command>)` first.

- With permissions off (the default), it runs without asking.
- In `ask` or `accept_edits` mode it asks, and the approval card shows the
  command. `"allow": ["Bash(make test)"]` lets it run unasked, and a `Bash`
  deny rule refuses it.
- In `lmx run`, where nobody can answer, a check that would ask is refused.
- A hook that rewrites the command runs the rewritten one.

A refused check is not a failure: the turn ends as it would have, and
`/verify` shows `last: <command> denied`. The check runs inside the turn's
checkpoints, so `/undo` takes back what it changed in a git repository along
with the turn's edits, as far as it would for a command, and names it as not
undone where it could not record it. A file you save while the check runs
goes back with that undo too; `/redo` takes the undo back.

### Permissions

Off by default: every tool call runs without asking. To be asked first:

```sh
lmx --permission-mode ask
```

or, for every session:

```json
{
  "permissions": {
    "mode": "ask",
    "allow": ["Bash(npm test:*)"],
    "deny": ["Bash(rm:*)"]
  }
}
```

| Mode | What runs without asking |
| --- | --- |
| `ask` | Reading, the todo list, `ask_user`, and whatever an allow rule names |
| `accept_edits` | The above, plus file edits in the working directory |
| `auto` | The above, plus commands, when commands run in [the sandbox](#the-sandbox); otherwise like `accept_edits` |
| `full_auto` | Everything except what a deny rule names |
| `read_only` | Reading only; anything that changes things is refused unless a rule names it |

Claude Code's mode names (`default`, `acceptEdits`, `bypassPermissions`,
`plan`) are accepted too. Rules use Claude Code's syntax (`Bash(npm test:*)`,
`Edit(src/**)`, `Read`, `mcp__server__tool`), and deny always wins. On an
approval card, `a` remembers the suggested rule for this repository, under
`~/.lmx/permissions`; `/permissions` lists and edits them. `lmx run` cannot
ask, so a call that would ask is refused (`"non_interactive": "allow"` lets
it run). In the terminal UI, Shift-Tab cycles the mode once permissions are
on. [Permission modes](hooks.md#permission-modes) has the details.

### The sandbox

Off by default. `--sandbox`, or `"sandbox": true`, runs every command the
agent starts inside the operating system's sandbox: Seatbelt (`sandbox-exec`)
on macOS, bubblewrap (`bwrap`) on Linux. A sandbox that was asked for and
cannot start stops `lmx` rather than running without it.

```json
{
  "sandbox": {
    "enabled": true,
    "network": false,
    "writable": ["~/scratch"],
    "hidden": ["~/.npmrc"]
  }
}
```

Inside it:

- **Writes** go only to the working directory, the temporary directories, the
  common tool caches (`~/.cache`, `~/Library/Caches`, `~/.npm`, `~/.hex`,
  `~/.mix`, `~/.cargo/registry`, …) and the paths in `"writable"`.
- **Network** is off, apart from loopback. `"network": true` allows it;
  `"localhost": false` blocks loopback too.
- **Hidden paths** can be neither read nor written, by commands or by the
  file tools: `read`, `write` and `edit` say "permission denied", searches
  skip them, and the directory around a hidden path stays listable.

The hidden paths are exactly these, plus the ones in `"hidden"`
(`lmx help sandbox` prints the same list):

- `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.git-credentials` and
  `~/.config/git/credentials` (git's credential store, in either place),
  `~/.pypirc`, `~/.config/gh`, `~/.config/gcloud`, `~/.azure`, `~/.docker`,
  `~/.kube`, `~/.codex/auth.json` and `~/.claude/.credentials.json`;
- `~/.lmx` and `~/.lemieux`;
- wherever this run keeps its own files: the config file (`--config`,
  `LMX_CONFIG`), the state directory (`LMX_HOME`), the transcript directory
  (`--sessions-dir`, `LMX_SESSIONS_DIR`, `"sessions_dir"`) and the MCP token
  file (`--credentials`, `LMX_CREDENTIALS`).

Several of these are single files, so what sits beside them stays readable:
git's own `~/.config/git/config` and `ignore`, and the settings, skills and
instructions in `~/.codex` and `~/.claude`. `~/.pypirc` holds the token
`twine upload` publishes with; installing Python packages never reads it.

That is not every credential a machine can hold. Everything else stays
readable, including `~/.npmrc` and `~/.hex/hex.config`, which builds such as
`npm install` and `mix deps.get` read; add those to `"hidden"` if your
builds do not need them. Only paths that exist when the sandbox starts are
hidden: a credential file created during a session is hidden from the next
start on. Under bubblewrap a hidden file is covered with `/dev/null` and a
hidden directory with an empty one; Seatbelt denies each path.

For the run's own files, a directory is hidden whole only when it is
`lmx`'s own (`~/.lmx`, a separate `LMX_HOME`, the transcript directory, a
directory holding nothing but `lmx`'s own files, or one `lmx` creates for
the purpose, mode `0700`); elsewhere `lmx` hides its own files in it one by
one. Of those run locations, nothing that is, or contains, the working
directory, your home directory, a temporary directory or `/` is hidden.
When the state directory is one of those, as with `--config ./lmx.json` and
no `LMX_HOME`, only the config file, the history, MCP trust and
permission files, and lmx's own log files (`logs/lmx.log`, `lmx.log.0` to
`.2`) and crash dump (`crash/erl_crash.dump`) are hidden there. The remembered model, checkpoints and
cloned plugins stay readable, and writable in the working directory or a
temporary directory; set `LMX_HOME` to keep them out of the agent's reach.
The fixed list and `"hidden"` are not filtered that way: a session working
inside `~/.lmx` (in `~/.lmx/extensions/NAME`, say) has its own working
directory hidden.

The sandbox covers commands and the file tools. The Elixir evaluation node,
MCP servers, hooks and the web tools run from `lmx` itself, outside it, and
so do the git snapshots behind `/undo`, which run git in a private git
directory so that nothing the repository configures runs
([Checkpoints](tool-contracts.md#checkpoints)). A sandboxed command can
still write the working repository's `.git/config` and `.git/hooks`: `lmx`'s
own git ignores what it writes there, but the `git` you run afterwards does
not, so after a sandboxed session in a repository you do not trust, check
them before you use git in it. `--permission-mode auto` pairs with the
sandbox: commands then run unasked only inside it.

### Credential scrubbing

Commands, hooks, the Elixir evaluation node and MCP stdio servers do not
receive environment variables whose **names** contain `KEY`, `TOKEN`,
`SECRET`, `PASSWORD` or `PASSWD`, in any letter case.
`"credential_allowlist": ["GH_TOKEN", "NPM_*"]` passes some through, and
`"scrub_credentials": false` turns the scrub off.

It is a name rule: it never reads values. These pass, for example:

- a connection string with a password in it (`DATABASE_URL=postgres://user:pass@host/db`);
- `MYSQL_PWD`, `GITHUB_PAT` and `SLACK_WEBHOOK`;
- variables that point at credential files (`GOOGLE_APPLICATION_CREDENTIALS`,
  `KUBECONFIG`, `SSH_AUTH_SOCK`).

`PAT` and `PWD` are not markers, because they are part of `PATH` and `PWD`.
Keep such secrets out of the environment `lmx` starts in, or use
[the sandbox](#the-sandbox) to hide the files they point at. The same name
rule decides which variables a repository's `.mcp.json` may not expand
without your approval.

### What commands inherit

Commands the agent runs, `!COMMAND`, command hooks and MCP stdio servers
inherit the environment you started `lmx` in, less what credential
scrubbing withholds. The editor Ctrl-G opens inherits it unscrubbed: it is
your own program, started by you.

Under the installed `lmx` that is your environment exactly, not the release
runtime's:

- your `PATH` as it was, so your own `erl`, `elixir`, `mix` and `iex` are
  the ones that run, and an MCP server's command is looked up on it too;
- none of the variables the release sets for its own runtime: `BINDIR`,
  `ROOTDIR`, `EMU`, `PROGNAME`, `RELEASE_*`, the `ERL_CRASH_DUMP` and
  `ELIXIR_ERL_OPTIONS` it chose, and the launcher's own `LMX_*` bookkeeping
  (`LMX_RELEASE_ROOT`, `LMX_ARGV_FILE`, `LMX_LAUNCHER_PID`, `LMX_LEASE_FILE`,
  `LMX_INSTALL_HOME`, `LMX_PARENT_*`).

A variable you set yourself before starting `lmx` is passed on unchanged:
`ERL_FLAGS`, `ERL_LIBS`, `ERL_CRASH_DUMP`, `ELIXIR_ERL_OPTIONS`, a
`RELEASE_*` of your own application, `LMX_HOME`, `LMX_CONFIG`. The Elixir
evaluation node (`--elixir`) is the exception: it runs on `lmx`'s own
runtime. A source run (`mix lmx`) passes on the environment its VM runs
with: the one it was started in, the `ERL_CRASH_DUMP` that `lmx` sets
([Crash dumps](cli.md#crash-dumps)) and, from the repository root, what the
checkout's `.env` set.

## Models and providers

Models are named `PROVIDER:MODEL`, as `req_llm` names them:

```text
anthropic:claude-sonnet-5
openai:gpt-6-sol
google:gemini-3.8-flash
ollama:qwen3.8:27b-mxfp8
```

Choose one for a command with `--model`, and for new sessions with
`LMX_MODEL` or `"model"`. `lmx help models` lists the providers `lmx` picks a
model for, with each one's key variable. `req_llm` reads other providers' keys
too, usually from `PROVIDER_API_KEY`. A new session whose provider has no key
stops before any request and names the variable or setting to fill in.

### Which model lmx starts on

When no `--model`, `LMX_MODEL`, `"model"` or Ixway route names a model,
`lmx` tries, in order:

1. **The model you last chose**, if it can still be reached. That is the
   model a terminal UI session last started on because you named it: with a
   flag, `LMX_MODEL`, the config file or an Ixway route, or with `/model` or
   `/provider` after a start that failed. A model you switch to in a running
   session is not remembered, and `lmx run` records nothing. Reached means
   its provider has a key or, for an `ollama:` model, the daemon serves it.
   Names compare as Ollama compares them, so `ollama:llama3.2` is the
   `llama3.2:latest` the daemon lists.
2. **The first provider whose key is set**, in the order of the table below,
   on its recommended model. A key counts from the environment, `req_llm`'s
   configuration or `"providers"` in the config file. A variable set to empty
   counts as no key, and also switches off a key saved in the file.
3. **A local Ollama model that can call tools.** `lmx` asks the daemon at
   `http://localhost:11434` what it serves, keeps the models whose
   capabilities include tools (never an embedding model), and prefers the one
   it used most recently, then the most recently pulled. The start says so:
   `Using ollama:TAG, a model the local Ollama serves, as no API key was found;
   set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended) for the
   Ollama server, or long sessions silently lose their task · --model or
   /model chooses another`. Read [Use a local
   model](providers.md#use-a-local-model) first.
4. **Nothing usable.** The terminal UI opens its *Choose a model provider*
   panel with no provider selected, and `lmx run` exits 3 with a sentence
   listing your choices.

| Provider | Key | Model |
| --- | --- | --- |
| Anthropic | `ANTHROPIC_API_KEY` | `anthropic:claude-sonnet-5` |
| OpenAI | `OPENAI_API_KEY` | `openai:gpt-6-sol` |
| Google Gemini | `GOOGLE_API_KEY` | `google:gemini-3.8-flash` |
| xAI | `XAI_API_KEY` | `xai:grok-4.7` |
| OpenRouter | `OPENROUTER_API_KEY` | `openrouter:anthropic/claude-sonnet-5` |
| DeepSeek | `DEEPSEEK_API_KEY` | `deepseek:deepseek-v4-pro` |
| Z.AI Coding Plan | `ZAI_API_KEY` | `zai_coding_plan:glm-5.3` |

A model picked in steps 2 to 4 is never remembered as your choice, so a key
you set later wins. If Ollama no longer serves a local model you chose, or
does not answer, that start moves to a provider with a key, another local
model or step 4, and a notice says so; your choice stays remembered for when
Ollama is back.

`--config none` without `LMX_HOME` skips all of this: it starts on
`anthropic:claude-sonnet-5` unless `--model` or `LMX_MODEL` names another,
and guesses nothing from your keys or a local daemon. If the default config
file cannot be created, keys and Ollama still decide; only step 1 is
skipped. `lmx explain` reports the model and what chose it
(`model_source`).

### Choosing and switching models

In the terminal UI, `/provider` shows the providers that have compatible
models and credentials, and `/model` lists the selected provider's models:
preferred and recently used models first, then active catalog models by
release date, with deprecated ones labelled in red and still selectable. An
exact `/model` search wins over that order. `/effort` lists the reasoning
levels the model advertises. A provider key permits listing a catalog; it
does not prove your account can use every model in it.

You can pin a model and effort for each provider:

```json
{
  "providers": {
    "openai": {"model": "openai:gpt-6-sol", "effort": "high"},
    "anthropic": {"model": "anthropic:claude-sonnet-5"}
  },
  "ixway": {
    "enabled": true,
    "endpoint": "https://ixway.example.com",
    "model": "ixway:team/coding",
    "effort": "medium"
  }
}
```

Switching providers uses the pinned model when it is available, otherwise a
model a recent session used with that provider, otherwise the provider's
first compatible model, and applies the provider's effort when the model
supports it; `/model` then opens so you can check. When direct routing starts
a new session, a sole provider `model` is the default; with several, set
`"model"` or `LMX_MODEL` to choose. Ixway uses its own model and effort when
that route is selected. An explicit `--model` or `LMX_MODEL` takes its effort
from its provider's section. When several `req_llm` provider names
share one environment key, a `providers` entry with an `api_key` makes that
name the terminal UI's choice; add the others explicitly to offer them too.
With Ixway enabled, the terminal UI lists both Ixway's key-scoped catalog and
the direct providers', and Ixway's picker opens on its own tab; Shift-Tab
cycles its qualified route tabs, and selecting a route keeps its exact
qualified id.

### Use a local model

`lmx` runs models that [Ollama](https://ollama.com) serves on your machine,
with no API key. Raise the Ollama server's context window first: unless told
otherwise, Ollama can serve as few as 4,096 tokens and silently drops what
does not fit, your task first. [Use a local
model](providers.md#use-a-local-model) has the recipe, how `lmx` picks and
switches to a local model, and what it does with one.

### Ollama Cloud

Direct Ollama Cloud access uses its own provider name and Ollama's standard
key variable:

```sh
export OLLAMA_API_KEY=your_api_key
lmx --model ollama_cloud:gpt-oss:120b
```

`ollama_cloud:` models go to Ollama's OpenAI-compatible
`https://ollama.com/v1` endpoint with bearer authentication. With the key
set, the terminal UI also lists Cloud models from `https://ollama.com/api/tags`
under `/provider ollama_cloud`; a saved `providers.ollama_cloud.api_key` does
the same when the variable is absent. Local `ollama:` models are unaffected.
To use a cloud model through a locally signed-in daemon instead, run
`ollama signin`, pull the `:cloud` tag and select its exact local tag as an
`ollama:` model; the daemon handles authentication then.

### API gateways

```sh
lmx --base-url https://llm-gateway.example --model anthropic:MODEL
export LMX_BASE_URL=https://llm-gateway.example
```

The gateway must expose the selected provider's API; `req_llm` still chooses
the wire format and appends the provider's path. The URL is not stored in
transcripts or request snapshots, because it belongs to the current host.
`--base-url` is not an HTTP proxy, and `lmx` does not read `HTTP_PROXY`,
`HTTPS_PROXY` or `SSL_CERT_FILE` today; see [Proxies and private certificate
authorities](troubleshooting.md#proxies-and-private-certificate-authorities).

## Workspace discovery

The *workspace* is what `lmx` reads from the repository and your home
directory to add to the system prompt: instructions, persona and memory
files, Agent Skills, legacy slash commands, the plugins you selected and a
learned overlay. The terminal UI and ordinary `lmx run` sessions load it;
`lmx run --bare` (or `--system`) leaves it out. An embedding host decides for
itself.

The directory `lmx` starts in (or `-C DIR`) decides which repository and which
nested files apply, so start it in the checkout or subtree the agent should
work on. `lmx` finds the git root and reads applicable files from the root
down to that directory; nearer files come later in the prompt, so they are
more specific. The model is also told to look for a nearer file before it
works below the starting directory. The same directory is the boundary for
the file tools and where commands and hooks start.

### Instructions and imports

Your own instruction files come first:

- `~/.claude/CLAUDE.md`;
- `~/.lmx/AGENTS.md`;
- `~/.codex/AGENTS.override.md`, or `~/.codex/AGENTS.md` when there is no
  override.

Then, for every directory from the repository root to the starting directory:

- `CLAUDE.md`;
- `CLAUDE.local.md`;
- `AGENTS.override.md`, or `AGENTS.md` when there is no override.

Identical `CLAUDE.md` and `AGENTS.md` content is included once, which covers
the common symlink. Each instruction, persona and memory file is capped at
32 KiB: a longer one is cut at a line boundary, the model is told, and the
terminal UI names the file. Your own files are read only where `lmx` has a
state directory, so `--config none` without `LMX_HOME` reads none of them.
`/init` asks the agent to draft an `AGENTS.md`, and `/memory TEXT` appends a
line to your memory file (`/memory --project TEXT` to the repository's).

**`@path` imports.** A `CLAUDE.md` or `CLAUDE.local.md` can import other files
with `@path`, as Claude Code reads them: up to five levels deep, relative to
the importing file, `@~/…` from your home directory, `\ ` for a space in a
name, and never inside fenced or inline code. An `@word` that names no
existing file stays text. What an import may reach depends on whose file it
is:

- A repository's file (any `CLAUDE.md` or `CLAUDE.local.md` in it, and
  anything it imports) may import only files whose real path, with symlinks
  resolved, is inside the repository.
- Your own files (`~/.claude/CLAUDE.md`, `~/.lmx/AGENTS.md`,
  `~/.codex/AGENTS.md`) may also import from your home directory, which is how
  `@~/.claude/my-project-instructions.md` works.
- Nobody's file reaches a credential location, in any letter case:
  `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.netrc`, `~/.config/gh`, `~/.docker`,
  `~/.kube`, `~/.lmx`, `~/.lemieux`, `~/.config/gcloud`, `~/.azure`,
  `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`,
  `~/.claude/.credentials.json` and `~/.codex/auth.json`. This holds even when
  your home directory is itself a git repository.

Claude Code asks before following an import outside the repository; `lmx`
refuses it, with one notice such as `<file>: import @<ref> was not followed:
it is outside the repository, and a repository's instructions may import only
files inside it`.

**Symlinks.** A repository's `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`,
`AGENTS.override.md`, `SOUL.md`, `MEMORY.md`, skills, legacy commands, agent
definitions and `.lmx/harness.json` are skipped when they resolve outside the
repository or into a credential location, each with one notice (`<path> is a
symlink to a file outside the repository and was not read`). Links inside the
repository, such as `CLAUDE.md -> AGENTS.md`, still work, and your own files
may link anywhere. `/memory --project` will not write through a `MEMORY.md`
that resolves outside the repository.

### Persona and memory

- Persona: `~/.lmx/SOUL.md`, then the repository root's `SOUL.md`.
- Durable memory: `~/.lmx/MEMORY.md`, then the repository root's `MEMORY.md`.

These are prompt files, read when a session starts. `lmx` never writes them
on the model's behalf; `/memory` is how you add a line.

### Agent Skills and legacy commands

Skills (`SKILL.md` files, the [Agent Skills](https://code.claude.com/docs/en/skills)
format) are discovered under these roots, in this order, a later root winning
a name clash:

```text
the skills bundled with lmx
OMARCHY/default/agents/skills/*/SKILL.md     on Omarchy, see below
~/.codex/skills/*/SKILL.md
~/.agents/skills/*/SKILL.md
~/.claude/skills/*/SKILL.md
~/.lmx/skills/*/SKILL.md
APPLICABLE_DIRECTORY/.agents/skills/*/SKILL.md
APPLICABLE_DIRECTORY/.claude/skills/*/SKILL.md
--skill-dir ROOT/*/SKILL.md
```

`APPLICABLE_DIRECTORY` is each directory from the repository root to the
starting directory. `~/.lmx/skills` comes after the other personal
directories because it is `lmx`'s own: a skill there replaces one of the same
name that Claude Code or Codex also reads. Legacy Markdown commands are
discovered recursively under `~/.claude/commands`, then `~/.lmx/commands`,
then each applicable `.claude/commands`, and a skill wins over a legacy
command with the same name. A plugin's skills are named `PLUGIN:NAME`, so
they clash with nothing outside the plugin. Your own skills and commands are
read only where `lmx` has a state directory, like your instruction files.

**Omarchy.** On [Omarchy](https://omarchy.org), `lmx` reads the skills
Omarchy ships for coding agents, such as `omarchy` (customizing the desktop)
and `diagnose-crash`, from the first of these that exists:
`$OMARCHY_PATH/default/agents/skills`,
`/usr/share/omarchy/default/agents/skills` and
`~/.local/share/omarchy/default/agents/skills`. They are read in place and
never copied, so an Omarchy update reaches the next session, and `lmx` never
writes there. They are read wherever your personal skills are. To stop
reading them, set `"skills": {"omarchy": false}` in `~/.lmx/config.json`.
The links Omarchy makes in `~/.claude/skills` and `~/.codex/skills` are
personal skills and are still read; `disabled`, below, leaves a skill out
whichever directory it is in.

**One skill, several paths.** A skill reachable through several roots, such
as Omarchy's skill linked into `~/.claude/skills` and `~/.codex/skills`, is
offered once, from the root that wins. `lmx skills` shows the copies it hid,
and whether each is the same file or a different one it overrides.

**Turning skills off.** `"skills": {"disabled": ["diagnose-crash",
"plugin:review"]}` leaves skills out by name (`PLUGIN:NAME` for a plugin's),
whichever root they come from: they are not in the catalog, the `skill` tool
or the slash commands. Any other key under `"skills"` stops startup.

**Seeing what was found.** `lmx skills` lists every skill a session started
in the current directory (or `-C DIR`) finds: where it came from, whether it
is enabled, disabled in the config, user-only (`disable-model-invocation`) or
model-only (`user-invocable: false`), its path, its real path when a link
points elsewhere, and the copies it hid. It says whether Omarchy's skills
are on and where it looked, prints the notices about skills, and takes
`--skill-dir`, `--plugin-dir`, `--marketplace`, `--plugin` and `--config` as
`lmx run` does. `--json` is for scripts.

Every skill needs YAML frontmatter:

```markdown
---
name: release-check
description: Validate a release candidate and report blockers.
---

# Release check

Run the repository's release validation ...
```

The name uses lowercase letters, digits and hyphens. At first the model sees
only each model-invocable skill's name and description; when a task
matches, it loads the body with the `skill` tool, which takes a discovered
name, never a path. That is how your own, Omarchy's and plugin skills
outside the repository are readable without opening the `read` tool to them.
Skill files up to 1 MiB are read, and a long one is returned in parts no
larger than the session's tool-output cap (at most 60 KB). `allowed-tools`
is informational: the session's tools and hooks decide what a skill may do.
A malformed skill is a startup notice and does not hide its neighbours.

**A skill's directory and its files.** A loaded skill names its directory:
the directory its `SKILL.md` really is in, with symlinks resolved, so a
`SKILL.md` that is itself a link still finds the files beside its target.
`${CLAUDE_SKILL_DIR}` expands to the same directory. The loaded skill then
lists the files in that directory (two levels down, at most 50, no
dotfiles), and the model loads one with the same tool, as
`{"name": "omarchy", "file": "hyprland.md"}`. The path is relative to the
skill's directory. Refused: an absolute path; a path that leaves the
directory, through `..` or a symlink; a file in a [credential
location](#instructions-and-imports), unless the skill itself is in that
location, as `~/.lmx/skills` is in `~/.lmx`; and a file that is not text,
which the refusal says to run with `bash` if it is a script. A plugin's skill
may load any file in its plugin, which is where its `${CLAUDE_PLUGIN_ROOT}`
references point, and a repository's skill only files inside the
repository, checked again when the file is loaded. A file is loaded up to
1 MiB, in parts like a long skill, and `$ARGUMENTS` is substituted in the
skill's instructions only. A legacy command is a single file and has no
files to load.

User-invocable skills and legacy commands are slash commands in the terminal
UI:

```text
/release-check api production
/quality:review lib/example.ex
```

A bare `/` lists `lmx`'s own commands, the bundled skills among them. Skills
from anywhere else sit on the completion menu's tabs, one per place they came
from: Project (the repository's), Personal (`~/.lmx`), Claude, Codex and
Agents (the other harnesses' personal directories), System (Omarchy's),
Plugins, and `--skill-dir`. Shift-Tab or a click switches tabs, and typing a
skill's name from the default tab jumps to the tab that has it. With no skill
outside `lmx`'s own, the menu has no tabs.

`$ARGUMENTS`, `$ARGUMENTS[N]` and `$N` are substituted when one is invoked;
`argument-hint`, `user-invocable` and `disable-model-invocation` are honoured;
`${CLAUDE_SKILL_DIR}` is expanded for every skill and `${CLAUDE_PLUGIN_ROOT}`
for a plugin's. The typed command stays in the transcript, and the expanded
instructions go to the model.

### Learned harness overlay

A learned overlay is a file of changes to the harness, the settings a session
runs with: text added to the system prompt, and descriptions for tools.
[Harness learning](harness-learning.md) produces them, and you decide whether
to use one. `lmx` reads two:

- `~/.lmx/harness.json`, your own, which may add system-prompt text and
  re-describe tools;
- `.lmx/harness.json` at the repository root, which may only add
  system-prompt text.

The repository's overlay is named in a notice on every start: `.lmx/harness.json:
this repository's learned overlay (<qualification>, <first 12 characters of
its sha256>) adds text to the system prompt; delete or revert the file to stop
it`. Its tool descriptions are dropped with a notice (`.lmx/harness.json: a
repository overlay may not re-describe tools, so its descriptions of <tools>
were not applied; only your own ~/.lmx/harness.json may`), because a tool's
description is what the model believes the tool does. An overlay left with
nothing to apply is not applied.

The text both add is appended to the system prompt, yours first, under one
`## Learned harness (QUALIFICATION, SHA12)` heading. QUALIFICATION is
`confirmed` only when every overlay in force is; a file whose qualification
is neither `confirmed` nor `unconfirmed` is ignored with a notice. SHA12
starts the digest of what applied. The file's digest is computed from the file
itself, so it shows the file is intact, not who wrote it. The overlay in force
is recorded in every request's snapshot, re-read on resume and subject to the
symlink checks above; an unreadable file is a startup notice.

`lmx harness export` writes an overlay from a confirmed candidate, to
`.lmx/harness.json` unless `--to` names another file; learned tool
descriptions apply only from `--to ~/.lmx/harness.json`, and an export that
writes them anywhere else says so on standard error
([CLI](cli.md#harness-learning-inspection)). Review the file like any other
change, and delete or revert it to roll back.

### The host contract

| Concern | `lmx` / `lmx tui` | `lmx run` | Embedded host |
| --- | --- | --- | --- |
| Base prompt | CLI default or `--system` | CLI default or `--system` (which runs bare) | Exact `:system` option |
| Workspace instructions | Discovered | Discovered unless `--bare` | Host decides |
| Persona and memory | Discovered | Discovered unless `--bare` | Host decides |
| Skills and plugin prompt assets | Discovered and invocable | Discovered unless `--bare` | Host decides |
| Learned overlay | `.lmx/harness.json` and `~/.lmx/harness.json` | The same, unless `--bare` | Host decides; a discovered `:workspace` passed to the CLI runtime applies it |
| MCP servers | Your `mcp_servers`, `--mcp-config`, selected plugins' servers, and the repository's `.mcp.json` once trusted (the terminal UI asks) | The same, but the repository's file only if already trusted or with `--project-mcp` | Host policy |
| Executable hooks | `--hooks`, the config's `"hooks"`, selected plugins' hooks | The same | Host policy |
| Tools | Coding tools (`read`, `write`, `edit` or `apply_patch`, `bash`, `grep`, `glob`, `todo`, the scout) plus `ask_user` | The same coding tools | Exact host catalog |

Saved plugins and discovered skills reach `lmx run` through the same
workspace the terminal UI composes, so a script and the terminal answer from
the same context. An embedder that wants the same profile applies
`Lemieux.Extensions.Workspace` to its harness;
`Lemieux.Extensions.Workspace.Discovery.discover/2` is the reading half, for a
host that wants the files without the composition.

### Discovery is an extension

Everything `lmx` layers onto a session is a `Lemieux.Extension`, applied to a
`Lemieux.Harness` through the same callback an embedder's code uses:
`Lemieux.Extensions.Interactive` adds `ask_user` because somebody is
attached, `Lemieux.Extensions.Workspace` composes the files above into the
prompt, `Lemieux.Extensions.Delegation` adds the scout,
`Lemieux.Extensions.Web` and `Lemieux.Extensions.Elixir` answer their flags,
and `Lemieux.Extensions.Hooks` and `Lemieux.Extensions.MCP` read the files
they are pointed at. `Lemieux.CLI.Runtime` holds the one list of what each
mode applies, in order; a host embedding the CLI appends its own with
`extensions:`, and someone who dislikes workspace discovery replaces that
extension rather than forking the screen. Which extensions shaped a session
is recorded in every request's snapshot. [Extensions](extensions.md) is the
contract.

### Compatibility and trust boundary

`lmx` reads much of a Claude Code or Codex setup, within limits. What works:

- Instruction files: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md` or
  `AGENTS.override.md`, `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, with
  `@path` imports confined as [above](#instructions-and-imports).
- Agent Skills in `.agents/skills`, `.claude/skills`, `~/.lmx/skills`,
  `~/.claude/skills`, `~/.agents/skills`, `~/.codex/skills` and, on
  Omarchy, Omarchy's own, with the files beside them; and legacy slash
  commands in `.claude/commands`.
- Subagent definitions in `.claude/agents`, used as read-only delegation
  targets.
- Plugins from a local directory (`--plugin-dir`,
  `lmx plugin install PATH|GIT-URL`) or from a marketplace: a local
  directory, GitHub `OWNER/REPO[@ref]`, any Git URL, or a direct https URL to
  a `marketplace.json`. A selected plugin's skills, commands, agents, hooks
  and MCP servers are loaded.
- The repository's `.mcp.json`, once you trust it, and `lmx mcp import
  claude|codex` (user-scope servers only, from Claude Code).
- Hooks in Claude Code's settings format, from `--hooks`, the config's
  `"hooks"` and plugins, for `PreToolUse`, `PostToolUse`, `UserPromptSubmit`,
  `Stop`, `SessionStart`, `SessionEnd` and `Notification`. This includes the
  exec form (`args`), `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT`,
  `CLAUDE_PLUGIN_DATA`, and `SessionStart` output added to the first prompt.

What is not supported, or ignored:

- In hooks: the fields `if`, `async`, `asyncRewake`, `once` and `shell`, and
  comma matchers such as `Edit, Write` (write `Edit|Write`). JSON output is
  read only on exit 0; exit 2 blocks, and any other status warns and lets the
  call go ahead. Hook input has no `transcript_path`, `permission_mode` or
  `last_assistant_message`. The default timeout is 60 seconds (Claude Code's is
  600). Events with no `lmx` equivalent (`SubagentStart`, `SubagentStop`,
  `PreCompact`, `PermissionRequest` and others) and `prompt`, `http` and
  `mcp_tool` hooks are skipped with a warning. `SessionStart` fires for
  startup and resume only. A hook's `systemMessage` is logged, not shown. See
  [Claude Code settings files](hooks.md#claude-code-settings-files).
- A repository's own `.claude/settings.json` hooks never run on their own
  (pass the file with `--hooks` if you trust it), and `.claude/rules` is not
  imported; a startup notice names either when it is there.
- Plugin options (`userConfig`, `CLAUDE_PLUGIN_OPTION_*`); plugin LSP
  servers, monitors, output styles, themes, executables and settings, which
  are reported as unsupported; plugin sources from npm, archives or commands;
  and plugin manifests that declare hooks or MCP servers as an array, skills
  as `"."` or commands as an object: such a plugin is not loaded, with a
  notice, and the session starts without it.

| Feature | `lmx` behaviour |
| --- | --- |
| Skill metadata and progressive disclosure | Supported |
| Manual and model invocation controls, and arguments | Supported |
| Personal, project and plugin skills, and legacy commands | Supported |
| Plugin marketplaces and pinned Git checkouts | Supported when you select them; a pinned `sha` is always checked out at that commit |
| Marketplace strict mode | Supported, with an older rule than Claude Code's: with `strict: false`, a plugin whose `plugin.json` declares components is refused |
| `allowed-tools` | Read as information; `lmx`'s own policy decides |
| `context: fork` | Named in a notice and run inline |
| Skill `model`, `agent` or `hooks` overrides | Named in a notice, not applied |
| Skill ``!`command` `` interpolation | Named in a notice and left as written |
| Plugin agents, hooks and MCP servers | Activated when the plugin is selected or installed; selecting it is the trust decision. MCP servers are named `plugin_<plugin>_<server>`, as in Claude Code |
| Plugin LSP servers, settings, output styles, themes, channels, monitors, experimental components or executables | Named in a notice, not activated |
| Repository `.mcp.json` | Started once you trust the file (the terminal UI asks; `lmx mcp trust`); `--no-project-mcp` never starts it |
| Repository and personal `.claude/agents` | Read-only delegation targets beside the scout; tools that could change things are refused, with a notice |
| Repository `.claude/rules`, or hooks in `.claude/settings*.json` | Named in a startup notice; not imported or run |

The rule underneath: instructions and skills are text, and `lmx` reads them;
hooks, MCP servers and plugins run code, and only run after a decision you
made. A repository's `.mcp.json` asks once per file (the answer is
remembered by its path and digest, so an edited file asks again). Hooks get
no such question, because a hook is a command a repository chose to run on
every tool call; pass them with `--hooks` or the config's `"hooks"`. The
whole model is in [SECURITY.md](../SECURITY.md#what-lmx-trusts-by-default).

The terminal UI shows these notices in the transcript, the finding marked
`⚠` and the remedy on its own `↳` row under it, with paths relative to the
repository. A notice whose remedy you took is not repeated: pass `--hooks`
and the settings notice goes away. The settings notice asks whether the file
declares a hook, not whether it exists; a file nobody can parse still warns.

The conventions come from the
[Claude Code features overview](https://code.claude.com/docs/en/features-overview),
[Agent Skills documentation](https://code.claude.com/docs/en/skills),
[Claude plugin reference](https://code.claude.com/docs/en/plugins-reference),
the portable [AGENTS.md specification](https://agents.md/), and OpenClaw's
[agent workspace conventions](https://docs.openclaw.ai/concepts/agent-workspace),
from which `SOUL.md` and `MEMORY.md` compatibility is drawn.

### Resume and embedding

The workspace layer is marked inside the recorded system prompt. When the
terminal UI or `lmx run` resumes a conversation that recorded one, it keeps
the original base prompt and replaces that layer with today's persona,
instructions, memory, skill list and learned overlay, and supplies today's
host tools; the overlay is read from the current files, not restored from the
transcript. That keeps the prompt from advertising skills the current host
cannot load. A session that started without a workspace layer (`--bare`, or
an embedded session) restores its recorded system prompt exactly.

Host tools are deliberately not recorded: they may hold closures,
credentials, tenant decisions or paths valid only in the current runtime. A
host supplies them again through `:host_tools`; ordinary configured tools
remain transcript configuration. So `Lemieux.Session` owns the conversation
and its recorded configuration; the current host owns `:host_tools`, hooks,
credentials, the environment and the workspace; and `Lemieux.CLI.TUI` is one
complete host built from the extensions under `Lemieux.Extensions`. On a
resume it seeds the harness with the recorded prompt and tools so those
extensions compose over what the transcript says; `Lemieux.Harness` explains
why the host has to do that.

## Claude-compatible plugins and marketplaces

A plugin bundles skills, slash commands, agents, hooks and MCP servers.
Selecting one is the decision to trust it: its agents become read-only
delegation targets beside the scout, its hooks run (with
`${CLAUDE_PLUGIN_ROOT}` substituted, and `CLAUDE_PLUGIN_ROOT`,
`CLAUDE_PLUGIN_DATA` and `CLAUDE_PROJECT_DIR` in their environment), and its
MCP servers start, named `plugin_<plugin>_<server>`.

**From a local directory**, for one session or for all of them:

```sh
lmx --plugin-dir /path/to/plugin          # this session only
lmx plugin install /path/to/plugin        # every session, saved in "plugin_dirs"
lmx plugin install https://github.com/OWNER/PLUGIN.git   # cloned into ~/.lmx/plugins/NAME
lmx plugin list
lmx plugin remove NAME
```

**From a marketplace**, a catalog that lists plugins: name the catalog with
`--marketplace`, and the plugin with `--plugin NAME@MARKETPLACE`, where
`MARKETPLACE` is the catalog's `name` field:

```sh
lmx --marketplace anthropics/claude-plugins-official \
    --plugin commit-commands@claude-plugins-official
```

A catalog may be a local directory, a GitHub `OWNER/REPO` (optionally with
`@ref`), any Git URL, or a direct https URL to a `marketplace.json`. Only the
plugin you name is fetched. Plugin sources may be relative paths, `github`,
`url` or `git-subdir`; npm, archive and command-based sources are reported as
unsupported rather than run. A direct `marketplace.json` URL cannot anchor a
relative plugin path; use the catalog's Git repository then. You can always
install a plugin some other way and pass its directory with `--plugin-dir`.
`"marketplaces"` and `"plugins"` in the config file save a selection.

**Fetching and caching.** Git work uses your installed `git`, with its
credential helper or SSH agent. Checkouts are cached under the platform's
user cache: `~/Library/Caches/lemieux/plugins` on macOS,
`~/.cache/lemieux/plugins` on Linux. A plugin pinned to a commit (`sha`) is
always checked out at that commit, and once cached it is reused without the
network. Catalogs and unpinned plugins are reused for an hour after a fetch,
then fetched again. If a refresh fails, the last copy is used with a notice
(`marketplace NAME: SOURCE could not be refreshed (REASON); using the copy
fetched TIME`). There is no command to refresh within the hour; delete the
cache directory to force one. A plugin, marketplace or selection that cannot
be loaded is a notice (`plugin NAME was not loaded: REASON`), and the session
starts without it.

**Which runs load saved plugins.** The terminal UI, `lmx run`, `lmx explain`
and resumed sessions. A `--bare`, `--system`, `--build-ext` or
`--extension-profile` run leaves them out and names them (`saved plugins are
not loaded in a --bare run, so their hooks and MCP servers are off for it:
NAMES`). The plugin and skill flags typed on a command line need a workspace,
so those runs refuse them.

**Plugin data.** `CLAUDE_PLUGIN_DATA` is `~/.lmx/plugin-data/ID`, where ID is
the plugin's name, or `NAME@MARKETPLACE`, with characters other than letters,
digits, `_` and `-` replaced by `-`. It is created private (`0700`) when a hook
or stdio MCP server that uses it first starts. With `--config none` and no
`LMX_HOME` it is a temporary directory for the run.

**What loads from a plugin.** `.claude-plugin/plugin.json` when present; the
default or manifest-declared skill paths, which add to the default; legacy
command files or directories, which replace the default; and a root
`SKILL.md`. Skills are named `PLUGIN:SKILL`, and component paths may not leave
the plugin directory. A marketplace entry's `skills` and `commands` are merged
with the plugin's manifest; with `strict: false` the entry is the authority,
and a plugin whose `plugin.json` also declares components is refused rather
than guessed at. What is not supported is in [Compatibility and trust
boundary](#compatibility-and-trust-boundary).

## MCP servers

MCP servers give the agent tools from other programs; [MCP tools and
authorization](mcp.md) covers the protocol. `lmx` reads the usual
`mcpServers` JSON shape:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/workspace"]
    },
    "docs": {
      "url": "https://example.com/mcp"
    }
  }
}
```

Servers come from four places:

| Source | When it starts |
| --- | --- |
| `--mcp-config FILE` | Every run that names it |
| `"mcp_servers"` in `~/.lmx/config.json` | Every session; your own, so nothing asks. `lmx mcp import claude\|codex` and `/mcp add` fill it |
| The repository's `.mcp.json` | Only once you trust the file ([below](#repository-mcp-servers-wait-for-trust)) |
| A selected plugin's `.mcp.json` or manifest `mcpServers` | Every session while the plugin is selected; named `plugin_<plugin>_<server>` |

A server of your own replaces the repository's server of the same name: the
repository's is neither started nor asked about, and `lmx mcp list` marks it.
A session runs one server per name; if two still share one, the first in the
table's order is kept and a notice names the other.

Servers connect in the background. `/mcp` shows each as connecting,
connected, needs sign-in or failed, and a prompt sent while one is still
connecting waits for it until 15 seconds after the session started. Each
server takes `startup_timeout`, `timeout` (one request) and `tool_timeout`
(one tool call, restarted by the server's progress notifications), in
milliseconds; the defaults are one minute, 30 seconds and ten minutes. A
tool name a provider would refuse is offered under a valid hashed name, which
`/mcp` shows. A resumed session keeps the servers its transcript recorded.

A `url` means HTTP and a `command` means stdio; Claude Code's `"type"`
(`stdio`, `http`, `streamable-http`) is read and written, and an explicit
`"transport"` wins. Legacy SSE servers (`"type": "sse"`) are refused with a
message saying to use their streamable HTTP endpoint. `${VAR}` and
`${VAR:-default}` are expanded only when connecting, and never saved
expanded. Stdio servers inherit the environment commands do ([What commands
inherit](#what-commands-inherit)), with the [credential
scrub](#credential-scrubbing) applied, and get `CLAUDE_PROJECT_DIR` unless
their configuration sets it.

`lmx mcp import claude` copies only Claude Code's user-scope servers, the
top-level `mcpServers` of `~/.claude.json`. Local-scope servers, which
`claude mcp add` creates per project by default, often with that project's
credentials, are named and left out; add one to the repository's `.mcp.json`
or pass `--mcp-config` to use it there. `lmx mcp import codex` copies the
servers in `~/.codex/config.toml`. Servers already in your file keep what you
wrote.

In the terminal UI, `/mcp` opens a server panel. `a` adds a server through a
short questionnaire, saved to your `"mcp_servers"` by default or to the
repository's `.mcp.json`; a header or environment value that looks secret is
saved as a `${NAME}` reference, never as written. `r` reconnects the selected
server, `o` turns it on or off for the session, `d` twice removes it from the
session, and Shift-D twice deletes it from its file.

### Repository MCP servers wait for trust

A repository's `.mcp.json` does not start when `lmx` opens the checkout,
because a stdio server is a command the repository chose. The terminal UI
asks once, showing each server's command or URL and the variables it reads,
and remembers the answer by the file's digest, so a declined file stays
quiet and an edited one asks again. From a shell, `lmx mcp trust` shows what
would run and `lmx mcp trust --yes` records trust; `--project-mcp` trusts the
file for one run; `lmx mcp untrust` forgets the decision. `--no-project-mcp`,
`LMX_PROJECT_MCP=0` and `"project_mcp": false` never start it. Under
`--config none` without `LMX_HOME` there is nowhere to remember trust, so
only `--project-mcp` starts it.

A repository's file may not expand variables whose names contain `KEY`,
`TOKEN`, `SECRET`, `PASSWORD` or `PASSWD` unless they were shown when you
trusted it. Servers you trusted at the prompt start without another notice;
ones nobody showed you (a file named with `--mcp-config`, or the repository's
under `--project-mcp`) are announced when the session starts.

### MCP OAuth

A remote server that needs your consent does not stop a session from
starting: it shows as needing sign-in, and reconnecting it from `/mcp` (`r`)
opens your browser. `lmx` follows the server's protected-resource metadata,
uses PKCE, and listens for the browser on `localhost` port 8642
(`--oauth-callback-port`). Tokens are kept in `~/.lmx/mcp-credentials.json`
(mode `0600`, in a private directory) unless `--credentials` or
`LMX_CREDENTIALS` names another file.

Earlier builds kept them in `~/.lemieux/credentials.json`. The first time
`lmx` uses its default file, it moves the old file there (moved, not copied)
and never reads the old path again. A file named with `--credentials` gets
nothing moved into it, and an old file that does not parse is left where it
is, so its servers ask you to sign in again. Another program on the same
machine that relied on the old path, the library's default, finds the file
gone and must sign in again.

On a machine with no browser, forward the callback port before opening the
printed URL locally:

```sh
ssh -L 8642:localhost:8642 devbox
```

Some authorization servers need a client you registered by hand:

```sh
lmx --mcp-config ./mcp.json \
  --oauth-client-id https://issuer.example=CLIENT_ID
```

The error names the issuer to use. [MCP OAuth](mcp.md#oauth-ownership-and-security)
has the details.

## Hooks and approval policy

Command hooks are programs `lmx` runs at points in a session: when it starts
and ends, when you submit a prompt, before and after a tool call, when the
model stops, when a turn needs you and when a provider request fails. A hook
can allow, deny, ask about or rewrite a tool call.

`lmx` loads hooks only from places you chose: `--hooks FILE`, the `"hooks"`
object in `~/.lmx/config.json`, or a plugin you selected. It never runs hooks
a repository declares on its own, because opening an untrusted checkout must
not run code; pass a repository's `.claude/settings.json` with `--hooks` if
you trust it.

```sh
lmx --hooks ./hooks.json
lmx --hooks .claude/settings.json
```

Both places take `lmx`'s versioned format or Claude Code's settings format.
Claude Code's `permissionDecision` (top level or inside `hookSpecificOutput`)
is honoured, and `"ask"` parks the call on the terminal UI's approval card; in
`lmx run` such a call is refused. After a tool call, a hook's feedback is
added to the result the model reads. Hooks get the same scrubbed environment
as `bash`; Claude-format hooks also get `CLAUDE_PROJECT_DIR`, and plugin
hooks `CLAUDE_PLUGIN_ROOT` and `CLAUDE_PLUGIN_DATA`. A hook that runs past its
timeout (60 seconds by default) has its whole process group killed.
[Hooks](hooks.md) defines the file, the protocol, matchers and exit statuses,
and lists [the Claude Code fields lmx does not
support](hooks.md#claude-code-settings-files).

For approval without writing hooks, use [permissions](#permissions). An
embedding host can park calls with `:pending` and draw its own approval
screen.

## Tool profiles and execution authority

The library's default tools are `read`, `write`, `edit` and `bash`. A new
`lmx` session adds `grep`, `glob` and `todo`, uses `apply_patch` instead of
`edit` on GPT-5-family models, and adds `ask_user` in the terminal UI; web
search adds `web_search`, `web_fetch` and `research_check`. A resumed session
keeps the tools its transcript recorded. `--elixir` replaces the built-in
tools with the Elixir evaluator, keeping `ask_user` in the terminal UI; MCP
tools you configured stay.

`read`, `write` and `edit` refuse paths outside the session's working
directory, whether through `..`, an absolute path or a symbolic link.
Confinement is by path, so a hard link inside the tree to a file elsewhere is
written through. `bash` runs locally as you, non-interactively, in its own
process group, without credential-shaped variables. `lmx` bounds and cleans
its output, enforces its timeout, and kills its whole process group when it
times out, is cancelled or `lmx` stops, but `bash` is not sandboxed unless you
ask for [the sandbox](#the-sandbox). On Windows (experimental), commands run
in Git for Windows' bash, never WSL's `bash.exe`.

An embedding host can replace the environment tools run in
(`Lemieux.Environment`) with a container, a microVM, a remote workspace or a
policy service, keeping provider credentials and the transcript in the host
while only tool execution moves.

## Web search

When a Brave Search key is set, a new session gets `web_search`, `web_fetch`
(read one public page as bounded text) and `research_check` (check quoted
passages against pages fetched in the session), with a short instruction on
researching claims. Nothing is requested at startup, and the agent decides
whether to search. A search sends its query terms to Brave and uses your
Brave quota.

Keep the key in the environment (`export BRAVE_SEARCH_API_KEY='your-token'`)
or in the config file:

```json
{
  "web_search_providers": {
    "brave": {
      "api_key": "YOUR_BRAVE_SEARCH_KEY"
    }
  }
}
```

The environment variable wins, and setting it to empty ignores the saved key.
`"web_search": "brave"` saved with no key for it is a warning at startup and
no search, so a half-finished file still opens the screen; `--web-search
brave` or `LMX_WEB_SEARCH=brave` without a key is an error that names the
key. Search keys are kept apart from model `providers`, and Brave is the only
shipped search backend. `--web-search none`, `LMX_WEB_SEARCH=none` or
`"web_search": "none"` turns search off without deleting the key;
`--no-web-fetch`, `LMX_WEB_FETCH=0` or `"web_fetch": false` keeps search but
turns off page reading and the research check. `web_fetch` refuses loopback,
private and link-local addresses, and search results are labelled untrusted.
`--elixir` leaves the web tools out while it is on. [Web search and page
fetch](web-tools.md) has the rest, including how an embedder supplies its own
search backend.

## Delegated investigations

`lmx` gives a new session a `delegate` tool with one definition, the read-only
repository scout; [CLI](cli.md#delegated-repository-investigation) has its
limits and how to decline it. `"scout_model"` runs scouts on another model, and
`"delegate": false` withholds the tool. Claude Code agent definitions
(`.claude/agents/*.md` in the repository and `~/.claude/agents`, and a selected
plugin's `agents/`) are offered beside the scout, but only as read-only
investigators: a tool that could change things is refused, with a notice
naming it. Definitions are not restored from a transcript, so pass
`--delegate` when you resume. An embedding host builds its own with
`Lemieux.Subagent.Delegate.new/2`; see [Delegated
investigations](subagents.md).

## Your own extensions

The installed `lmx` loads a `Lemieux.Extension` you built, from a directory
holding an `extension.json` and compiled code. `--extension NAME` selects
`~/.lmx/extensions/NAME`; `--extension-dir PATH` selects any directory, and is
the only way a directory inside a checkout is loaded: like `--hooks`, it takes
your say-so, never the repository's. The persistent form:

```json
{
  "version": 1,
  "extensions": ["audit", "review"]
}
```

Each entry is a directory name under your extensions root
(`~/.lmx/extensions`, or `LMX_EXTENSIONS_DIR`): letters, digits, `-` and `_`.
A path or a module name is refused, because the manifest that names code has
to live in a directory you populated, not in this file. Names from the config
load first, then the flags in the order typed; each directory loads once. A
name with no directory, a manifest that does not validate, or a build that
does not fit this runtime stops startup with a sentence, rather than starting
a session without what you asked for.

An extension may offer **model routes** instead of, or beside, shaping the
harness: a module exporting `routes/1` has them registered under the names
its models carry, selected with `--model NAME:ID`, `--router NAME` or
`/provider NAME`, and `providers.NAME.model` and `providers.NAME.effort`
apply to them as to any provider. [Adding a model route](extensions.md#adding-a-model-route)
has the contract and the rules.

A script extension only has to satisfy its declared `lemieux` requirement,
because it compiles in the running VM. A compiled bundle from a current
`mix lmx.extension.build` records an extension API version and loads when
the extension API and the OTP major version are the same as `lmx`'s, and
the Elixir it was built with has the same major version as the one `lmx`
runs and is no newer; a bundle built before API versions existed needs
exactly the versions it was built with. `lmx extension new NAME`
writes a one-file script extension to start from, and `lmx extension list`
shows what is installed. An extension's options live in
`"extension_options": {"NAME": {...}}`, merged over its manifest's, so
rebuilding keeps them. [Extensions](extensions.md#installing-an-extension-into-lmx)
has the layout, the manifest and what the transcript records.

## Resume precedence

For a **new session**, the practical precedence is:

1. an explicit flag;
2. an `LMX_*` environment variable, where one exists;
3. the config file;
4. the built-in default.

For a **resumed session**, the conversation's identity wins:

- the model, system prompt, tools, reasoning settings and MCP servers are
  restored from the transcript;
- an explicit flag overrides the restored value;
- an ambient `LMX_MODEL` does not quietly switch an existing conversation;
- an explicit `--elixir` replaces the restored built-in tools;
- web search is equipped again only when the current host selects it;
- the base URL, provider credentials, hooks, credential store and execution
  environment come from the host doing the resume;
- `/resume` in the terminal UI does not carry the previous session's tool
  profile into the one it opens.

That is why Lemieux records configuration but leaves credentials and routing
out of the transcript.

## System prompts

Lemieux has one general session default and a few deliberately separate
prompts, because a host, the `lmx` CLI, a compaction request and a delegated
child do not have the same authority or job.

### Library sessions

When an embedder omits `:system`, `Lemieux.Session` uses
`Lemieux.Prompt.default/0`. The short default tells the model to inspect
before editing, follow the repository's conventions, make changes it can
verify, read failures instead of retrying blindly, treat the current tool
list as authoritative, and report results directly and honestly. It names no
tools and includes no repository instructions: tools are sent with each
request and can change during a session, and repository policy belongs to
the host. The exact, versioned wording lives in `Lemieux.Prompt`.

An embedder replaces the default by passing a string:

```elixir
Lemieux.start_session(
  supervisor: MyApp.Agents,
  provider: provider,
  store: store,
  model: model,
  system: "You maintain an OTP library. Prefer focused ExUnit tests."
)
```

Passing `system: nil` turns the general prompt off, which is different from
omitting the option.

### The full-screen `lmx` TUI

A new session starts with `--system TEXT`, or `Lemieux.Prompt.default/0`, as
its base:

```sh
lmx --system "You are maintaining an OTP library. Prefer focused ExUnit tests."
```

`lmx` then appends the workspace, in this order:

1. your own and the repository's `SOUL.md` persona files;
2. `CLAUDE.md` and `AGENTS*.md` instructions, yours first, then from the
   repository root to the starting directory;
3. your own and the repository's `MEMORY.md`;
4. the model-invocable skills' names and descriptions, with instructions to
   load a skill's body through the `skill` tool only when it applies;
5. the learned overlay's text, under `## Learned harness (QUALIFICATION,
   SHA12)`.

`--system` replaces only the base; it does not suppress the workspace. This
composition belongs to `Lemieux.Extensions.Workspace.Discovery`, not to the
embeddable library, and another host may build its prompt from entirely
different sources. The overlay's tool descriptions change the tool list
rather than the prompt. The effective prompt is recorded with its workspace
layer marked, and a resume replaces that layer with the current workspace
([Resume and embedding](#resume-and-embedding)).

### Bare CLI hosts

An ordinary new `lmx run` session discovers and composes the same workspace
as the terminal UI. `--bare` skips discovery and uses the base prompt
verbatim, and so do an explicit `--system TEXT`, `--extension-profile` and
`--build-ext`, so a supplied prompt or profile is not mixed with repository
context. A resume of a session that started bare restores its recorded system
prompt exactly; see [Resume precedence](#resume-precedence) for overrides.

### Compaction

Compaction makes a separate request with no tools. Its system prompt comes
from the session's `:compaction` module, `Lemieux.Compaction.instructions/2`
by default: keep the person's request, decisions and their reasons, completed
changes, expensive discoveries, outstanding work, failed attempts and any
earlier summary, and leave out detail that can be reproduced and the recent
conversation that stays verbatim.

That prompt does not replace the session's. After compaction, ordinary
requests use the session's prompt followed by an `<earlier-conversation>`
section holding the summary (`Lemieux.Compaction.with_summary/2`). If a
session was started with `system: nil`, the summary section becomes its only
system content. A host that passes `compaction: MyApp.Compaction` (or
`{module, state}`) to `Lemieux.start_session/1` supplies both its own
summariser instructions and its own framing, and the session still decides
when to compact and records the same `:compaction` entry. See
`Lemieux.Compaction`.

### Delegated investigators

A delegated child does not inherit the parent's system prompt or
conversation. Its host-supplied `Lemieux.Subagent.Definition.system_prompt` is
wrapped in a fixed envelope saying the child is a read-only investigator one
level deep, the parent owns decisions and writes, missing context must be
reported rather than invented, and the result must match the configured JSON
schema. The envelope also carries the definition and lineage ids and the
inherited policy. There is no fallback prompt: `system_prompt` is required, so
a child's role is always an explicit host decision.

### What does not change a prompt

Changing the model, the reasoning effort or the enabled tools does not rewrite
the session prompt; the next request carries the new parameters or tool list
beside the same prompt. That is why the default prompt's rule to trust the
current tool list stays accurate when a host or a command changes which tools
are available.

## Storage locations

The paths below are the defaults. A row whose override begins with
`LMX_HOME` is in the state directory: `LMX_HOME` when set, otherwise the
directory the config file is in, `~/.lmx` by default. `--config none`
without `LMX_HOME` has no state directory, so nothing in those rows is read
or written. Every other `~/.lmx` path is in your home directory whatever the
config file says; crash dumps move only when `LMX_HOME` is set.

| Data | Default | Override |
| --- | --- | --- |
| Personal configuration | `~/.lmx/config.json` (mode `0600`, in a `0700` directory) | `--config`, `LMX_CONFIG` |
| Session transcripts | `~/.lmx/sessions/SESSION.jsonl` | `--sessions-dir`, `LMX_SESSIONS_DIR`, `"sessions_dir"` |
| Transcript locks | `SESSION.lock` beside the transcript | Follows the sessions directory |
| Session index (last activity, directory, preview) | `index.json` in the sessions directory | Follows the sessions directory |
| The model you chose, and recently used models | `~/.lmx/state.json` | `LMX_HOME` |
| Input history (Ctrl-R) | `~/.lmx/history.jsonl` | `LMX_HOME` |
| Checkpoints for `/undo`, `/rewind` and `/redo` | `~/.lmx/checkpoints/` (file contents saved before a file tool changed them, up to 10 MB a file, `.env` included; kept until you delete them). The git snapshots' private git directories are made under each session's `git/` there and removed when the snapshot or undo is done | `LMX_HOME`; `"disabled_extensions": ["checkpoints"]` |
| Command snapshots for `/undo` | Unreferenced objects in the repository's own `.git/objects` | Kept until `git gc` prunes them |
| Repository MCP trust decisions | `~/.lmx/trusted-mcp.json` | `LMX_HOME`; `lmx mcp untrust` |
| "Always allow" permission answers | `~/.lmx/permissions/REPO-DIGEST.json` | `LMX_HOME` |
| Log file | `~/.lmx/logs/lmx.log` (rotated at 1 MB, three old files kept) | `LMX_HOME`; none with `--config none` and no `LMX_HOME` |
| Crash dumps | `~/.lmx/crash/erl_crash.dump` (directory `0700`), whatever the config file says, `--config none` included | `ERL_CRASH_DUMP`; `LMX_HOME` moves it to `crash/` there |
| MCP OAuth tokens | `~/.lmx/mcp-credentials.json` (mode `0600`) | `--credentials`, `LMX_CREDENTIALS` |
| OAuth callback port | `8642` | `--oauth-callback-port`, `LMX_OAUTH_CALLBACK_PORT` |
| Your own extensions | `~/.lmx/extensions/NAME/` | `--extension-dir`, `LMX_EXTENSIONS_DIR` |
| Installed Git plugins | `~/.lmx/plugins/NAME`, written by `lmx plugin install` | `LMX_HOME` |
| Plugin data (`CLAUDE_PLUGIN_DATA`) | `~/.lmx/plugin-data/ID` | A temporary directory with `--config none` and no `LMX_HOME` |
| Marketplace and plugin checkouts | `~/Library/Caches/lemieux/plugins` (macOS), `~/.cache/lemieux/plugins` (Linux) | Delete it to force a fresh fetch |
| Feedback ledger | `feedback/` beside the sessions directory | `--feedback-dir` |
| Learned harness overlay | `~/.lmx/harness.json`, and `.lmx/harness.json` in a repository | `lmx harness export --to PATH` writes elsewhere |
| `/export` transcripts | `exports/` beside the sessions directory, `~/.lmx/exports/` by default | `/export PATH` |
| Pasted images | `.lmx/pastes/` in the working directory (ignored by its own `.gitignore`) | None |

Transcripts hold prompts, source snippets, command output, model thinking
metadata and host metadata: protect them as project data. Each transcript is
created with mode `0600`, and a looser one is tightened at its next write. A
sessions directory `lmx` creates is `0700`; one that already exists keeps its
mode, because it may be shared (`/tmp`, a project, a volume), so make it
private yourself. These modes apply on macOS and Linux, not on Windows. A
session lock records the host and process holding it; a lock left by a
process that is provably gone is taken over, and one held on another host is
never taken over, so delete it yourself if that host is gone.

The JSONL store suits a single user on one machine. An embedder supplies its
own access control, encryption, retention, backups and tenant isolation.
