# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0, a minor release may change public APIs; each such change is listed
with migration notes. [Support](docs/support.md) says what counts as public
API.

## Unreleased

### lmx

- Ctrl-U in the input box deletes back to the start of the line, as it does
  at a shell prompt, instead of undoing the last edit. Most macOS terminals
  (iTerm2, Ghostty, Alacritty, VS Code) send Ctrl-U for Cmd-Backspace, so
  Cmd-Backspace took back one typed character per press and, held after
  deleting, brought the deleted text back. A Cmd-Backspace the terminal
  reports as itself does the same, rather than deleting one character. Undo
  moves to Ctrl-Z. (#23)
- A key the screen and the input box both pass over types nothing. The input
  box typed any character pressed without Ctrl or Alt, so a Command, Hyper
  or Meta key the terminal reported (Cmd-K, Cmd-C) typed its letter, and a
  control character such as ESC went into the draft as an invisible byte.

### Experimental

- A live `mix lemieux.eval` refuses a selected case tagged `safety` before
  anything runs, and names it. A live candidate's `bash` runs on the host
  with your authority, and `refuse-destructive-request` — in the `smoke` tag
  — asks the model to delete every file outside the repository; nothing but
  the model's own refusal stood between that prompt and your home directory.
  Select a live smoke run's other cases by their own tags. (#26)
- `mix lemieux.eval` checks `--baseline` before it runs anything: a blessed
  baseline whose task ids differ from the selected cases, or a name that is
  none of the runtimes, is refused at the start. Both were found by the gate
  after the run, and the error discarded it unwritten — eight minutes of
  live work in the run that reported it. (#30)

## 0.9.1 — 2026-10-07

0.9.0, signed. 0.9.0 was published without `SHA256SUMS.sig` and
`update.json.sig`, so `install.sh` refused to install it and installed copies
of `lmx` reported it as not signed yet; a published release is immutable, so
the signatures could not be added to it afterwards. 0.9.1 changes nothing
else: everything listed under 0.9.0 is in it, and an `lmx` 0.8.1 updates to
it by restart.

## 0.9.0 — 2026-10-07

### lmx

- An extension `lmx` loads can register a **model route**: a module that
  exports `routes/1` (`Lemieux.Extension.Routes`) offers named
  `Lemieux.Provider.Route`s, and `lmx` registers them beside Ixway
  (`Lemieux.CLI.Routes`) and runs them through the same host code — the
  prefetch before the terminal UI opens, `NAME:@default` resolving to the
  route's advertised default, `/provider NAME` and `/model` listing its
  models, the start model readied and checked on its route for a new
  session and a resume, and a request under one name never reaching another
  connection. Until now that code named `Lemieux.Ixway`, and a second route
  meant another binary. `--router` and `LMX_ROUTER` take a registered
  route's name beside `direct` and `ixway`: `lmx run` then sends through
  that route alone, as `--ixway` always has, and the file's `"model"` or
  `providers.NAME.model` chooses the start model when it names one of the
  route's. A name nobody registered, a route that would shadow a `req_llm`
  provider or another route, a malformed registration, and a `routes/1`
  that cannot build its routes (a credential not set) each stop the start in
  a sentence naming the extension, and so does resuming a transcript whose
  route's extension is no longer selected, before a session exists and with
  the flags that bring the route back. `lmx explain` reports the route under
  `diagnostics.route` and a route's credential as `route_managed`. The
  loader accepts a module exporting `apply/2`, `routes/1` or both, and
  records `"routes": true` for one that offers routes.
  [`examples/extensions/relay`](examples/extensions/relay/README.md) is a
  one-file route to an OpenAI-compatible server, and
  [Adding a model route](docs/extensions.md#adding-a-model-route) is the
  guide. (#14)
- **Jev compaction is now System One compaction**, and it reaches any
  System One provider named in the config file, the way `"web_search"`
  chooses a search backend. `"systemone_providers"` declares each System
  One provider once, shared by every feature that asks such a model, and
  `"systemone_compaction"` holds this step's choice (`provider`), its `mode`
  and its budget. An entry holds, under the provider's name, its `base_url` (any service that speaks
  `POST /v1/systemone`), key (`api_key`, `api_key_env`, and `api_key_header`
  for a service that wants it in a header rather than as a bearer token),
  extra `headers`, `model` and tariff. The built-in `typesafe` and `ixway`
  take an entry too, for TypeSafe's key and model or the Ixway gateway's
  address and model. An open decision model on your own machine, or a
  vendor's decision API, now needs only config: no TypeSafe or Ixway key,
  and nothing reaches either. This was verified end to end against two open
  models that Ollama 0.35 serves on `/v1/systemone`, Bespoke Labs' Nimble
  and Cloudflare's Clef-flash, and the extension's suite keeps that as a
  live test you run by naming the server. A provider entry that is not
  selected neither switches the step on nor receives anything; there is no
  fallback from one provider to another; a provider without a declared
  tariff makes no evaluation under a dollar cap, and TypeSafe alone keeps
  its default model and published rates. In `apply` and `shadow` mode an
  incomplete provider stops the start naming the missing piece, and
  `lmx explain` reports the mode and the provider's name under
  `diagnostics.systemone_compaction`. Ixway now goes through the SDK's
  generic endpoint client rather than TypeSafe's, so a request to a gateway
  carries the SDK's own user agent and no `X-TypeSafe-*` headers.
  ([System One projection](docs/compaction.md#optional-system-one-projection-before-compaction), #6)

  **Breaking:** `"jev_compaction"` and `"jev_compaction_providers"` are
  refused at startup with a sentence naming the new keys, and so is
  `"disabled_extensions": ["jev_compaction"]`; nothing is read from the old
  spelling, since ignoring it would quietly switch the step off.
  `jev_compaction.api_key` moves to
  `systemone_providers.typesafe.api_key`, `jev_compaction.endpoint`
  to `systemone_providers.ixway.base_url`, and a model or tariff
  to the selected provider's entry ([the whole
  table](docs/compaction.md#moving-from-jev-compaction)). `JEV_API_KEY` is
  unchanged. The bundled extension is now `LemieuxSystemOneCompaction`
  (`:lemieux_systemone_compaction`, in
  `dist/lmx/extensions/systemone_compaction`); a host passes it `provider:`
  or `client:`. The older `route:`, `api_key:`, `ixway_endpoint:`,
  `ixway_api_key:` and `model:` options are refused with a sentence saying
  where each value now goes, rather than ignored, and the extension no
  longer reads `JEV_API_KEY` itself. It records its decisions under the
  `systemone_compaction` namespace, so a session recorded before the rename
  is resumed without its earlier projections, which sends those reads in
  full again, and with the step's own evaluation count and cap starting
  over. The Ixway entry's `base_url` is an origin, as `ixway.endpoint` is.
  In the paired trial, the projection arm is `projection` (was `jev`), its
  option `typesafe_api_key` (was `jev_api_key`) and its report field
  `extension_attached` (was `jev_extension_attached`); the dated reports in
  `eval/v1/results` keep the old names.
- **The computer-use and research examples ask any System One provider**,
  chosen from the same `"systemone_providers"` list: `mix lmx.browser
  --systemone-provider NAME` for browser actions, `discovery: [provider:
  NAME]` for research's source selection, and the automatic choice
  (TypeSafe when `JEV_API_KEY` is set) when neither names one. Their
  classifiers are now `LemieuxComputerUse.SystemOne` and
  `ResearchExtension.SystemOne`, take a provider rather than a TypeSafe key,
  and refuse their old `jev:` and `api_key:` options. Their questions are
  portable: every `choice` has string descriptions and 2 to 26 options,
  which System One servers other than TypeSafe's require. A single target
  or source is taken without asking, and a browser operation with more than
  26 targets is asked as a choice of group and then a choice within it,
  for TypeSafe too. Both examples' live tests pass against Clef-flash and
  Nimble served by Ollama, for `choice` questions over real page and source
  fixtures. The research example now needs this checkout or Lemieux 0.9.

- **A long task keeps going.** A model that ends its turn while the plan it
  wrote with `todo` during the prompt still has open tasks is sent back to
  them with a message listing what is left, at most five times a prompt; an
  answer that calls no tool is taken as its decision to stop (you asked it to
  stop there, or it is blocked or needs something only you can give). A plan
  left from an earlier prompt does not count, and asides such as a reflection
  are never sent back. An answer cut off at the output-token limit is picked
  up again, at most three times, and a file write the limit cuts short is no
  longer run with empty arguments: the model is told it was cut off and to
  write the file in smaller parts, where it used to be told "needs a path and
  content", send the same oversized call again and be stopped by the repeat
  guard. It runs before the check after edits, so the check runs once the plan
  is finished, and `--config none` keeps it. `"continuation"` sets the
  allowances, `"continuation": false` or `"disabled_extensions":
  ["continuation"]` turns it off ([Continuing unfinished
  work](docs/configuration.md#continuing-unfinished-work)). Messages a stop
  hook sends the model are drawn as `lmx` speaking (`↻`, or `✓` for the
  check), live and in a resumed session, and `lmx log` and `/export` label
  them the same way, where a resumed session drew them as lines you had typed.
  The default system prompt now says that ending a turn hands control back to
  you, and to keep working until the task is done, and the `todo` tool's
  description that a plan with open tasks means the work is not done, unless
  you asked the model to stop sooner. Neither wording change is measured yet.

### Installing and updating

- Release builds pin Erlang/OTP 29.1.1 and Elixir 1.20.4; 0.8.1 was built on
  29.0.2 and 1.20.2. The runtime components Erlang/OTP vendors (PCRE2, AsmJit,
  zlib, Zstandard, Ryu, the Unicode Character Database) are the same versions
  in both OTP releases, so `THIRD_PARTY_NOTICES` is reviewed for 29.1.1 with
  the entries it had. A new ERTS means the next release updates 0.8.1 by
  restart rather than a hot swap.

### Library

- `Lemieux.CLI.SystemOne.provider/3` resolves a System One provider from
  `"systemone_providers"` for any feature that asks one: a selection by
  name (or the automatic choice between TypeSafe and Ixway), the field or
  flag that made it for refusals, and a provider description out — never a
  client, since the library has no System One SDK dependency.
  `Lemieux.CLI.SystemOne.rates/2` reads a provider's declared tariff. (#6)
- `Lemieux.Provider.Route` has two optional callbacks for the host that
  starts a session, `ready/1` and `default_model/1`, and `prepare/2`, the
  one sequence every host runs them in: ready the route, resolve
  `NAME:@default` (`Lemieux.ModelSpec.default_selection?/1`) through the
  default, check the model. `Lemieux.Providers.ReqLLM.prepare/2`,
  `ready/1` and `route/1` do the same for a routed provider;
  `Lemieux.Ixway.prepare/2` is now that sequence for the shipped route,
  which implements both callbacks, and `Lemieux.Ixway.ready/1` is public.
  `Lemieux.Extension.Routes` is the behaviour an extension implements to
  offer routes to a host, with `validate/1` for what it returned.
  `Lemieux.CLI.ProviderMux.new/3` takes a list of `{name, provider}` routes
  in place of one Ixway provider; a host that built one passes
  `[{"ixway", ixway}]`. (#14)
- `Lemieux.Provider.Error.category/1` files an HTTP `408` under `:timeout`.
  `retryable?/1` and `transient?/2` already treated it as transient, but the
  category a host's retry policy sees was `:other`, so a CDN that answered
  seven streaming requests in one benchmark run with a bare `408` had each
  one recorded as the model failing. The `:error` transcript entry carries
  the failure's `http_status` beside `category` and `reason` when there was
  one, and the `provider_error` of a benchmark observation always has the
  key (`null` when there was none), so a `retry: [when: ...]` predicate can
  decide on the status itself. (#15)
- A `200` stream that carried nothing at all and ended `:incomplete` — the
  adapter's `{:unanswered, model, :incomplete}` failure — is classified
  `:server`, so `transient?/2` is true and the session's bounded retry asks
  again, the same as for a stream cut mid-answer. It was `:other`, because
  OpenAI refuses a request on an account with no credit in the same shape;
  nothing in the response tells the two apart, and that refusal still fails
  every retry with the sentence naming credit, quota and request validity,
  while a gateway that dropped the stream before the first token is answered
  on the next try instead of being recorded as the model failing. Under a
  dollar cap the session's own retry still refuses when the failed attempt
  left spend unknown, as a stream that reported no usage does; there a
  host's category-based retry is what fires. `lmx run` exits 6 (provider)
  rather than 1 for this failure, and `lmx log` labels it `error (server)`.
  (#16)
- A session under `max_cost_usd` runs against a model whose catalog tariff
  ReqLLM cannot resolve. Under the default pricing context that is 34 of the
  catalog's priced models — the current Anthropic frontier
  (`claude-fable-5-1`, `claude-opus-5-5`, `claude-sonnet-5`), OpenAI's
  gpt-5.6 and gpt-6 families, `google:gemini-3.1-pro-preview`, xAI's grok-4.3
  and later, DeepSeek v4, MiniMax M3, Alibaba's qwen3.6/3.7 — because each
  carries a data-residency, flex or priority modifier that resolves under no
  context, and ReqLLM's billing calculator then answers no price. On 0.8.1
  every metered session on one of them stopped before its first request with
  `its cost cannot be estimated`, and dropping the cap lost the measured cost
  column too. The estimate, and the cost of the usage a direct request
  reports, now fall back to the model's flat list rates, and the usage says
  so (`pricing.status` is `"list_rates"`); a pricing context the tariff
  cannot be resolved for (`pricing_context: %{}`) is priced the same way,
  where it used to answer `nil`. [Cost estimates](docs/providers.md#cost-estimates)
  says what list rates assume. A model with no usable list rates — none,
  negative, or not in USD — still stops, and the message names it (`no price
  is known for openrouter:openrouter/auto`); usage that is not whole stays
  unpriced. The `{:budget, payload}` finish carries `model`. (#17)

- `Lemieux.Extensions.Continuation` is the stop hook behind the above, and
  `Lemieux.Extensions.coding/3` takes `continuation: true` (or its options,
  `:max_continuations`, `:max_output_continuations`, `:enabled`), placed
  before `verify`. It reads the plan through `Lemieux.Extensions.Planning`
  and its counts from the transcript, so they survive resume.
- A stop hook's feedback is written as a `:user` entry marked
  `"stop_hook" => true`, an additive field within transcript schema 2, and
  `Lemieux.Transcript.stop_hook?/1` asks whether an entry is one. Stop hooks
  receive `aside:` in their context, the running aside's kind or `nil`.
  `Lemieux.Extensions.Verify` no longer takes another stop hook's message for
  the person's prompt: it did, so edits made before such a message were never
  checked. A command hook in Claude Code's `Stop` format that sent the model
  back could do that before this release.

  **Migration:** a host that compares a stop hook's `:user` entry payload
  exactly (`payload == %{"text" => text}`) now sees the extra
  `"stop_hook" => true` key. Match on `"text"` instead, and use
  `Lemieux.Transcript.stop_hook?/1` to tell the hook's words from the
  person's.
- A response that ended at the output-token limit (`:length`) with tool calls
  no longer runs its last call as it arrived when that call's arguments did
  not come whole: `Lemieux.Turn` marks it `argument_error: :output_limit`, and
  `Lemieux.Tools.run/5` answers it as `:invalid_arguments` without running it,
  telling the model to split the work. A last call whose arguments arrived
  whole still runs. `Lemieux.Providers.ReqLLM` now carries ReqLLM's
  `args_lost` mark as `argument_error`; the call used to arrive with empty
  arguments that decoded, and ran.

## 0.8.1 — 2026-10-06

The first update to the public release: four fixes from the first week of
reports, and a way to update from a terminal.

### lmx

- A config file with an empty `api_key` placeholder (`"api_key": ""`) under
  `providers`, `ixway`, `jev_compaction` or `web_search_providers` now loads:
  the field counts as no key, is named in the startup notices (`Empty field
  "ixway.api_key" in the lmx config; it is ignored`), and the terminal UI
  opens so a real key can be saved. It used to stop every command with
  `Invalid lmx config field: web_search_providers.` A value a field cannot
  take now names the field down to its key and what it takes
  (`Invalid lmx config field: ixway.enabled. It must be true or false.`),
  where the sentence used to name only the section. `"web_search": "brave"`
  saved with no Brave key is a startup warning and no search rather than a
  refused start; `--web-search brave` and `LMX_WEB_SEARCH=brave` without a
  key stay errors. An Ixway route without a key says where the key goes in
  both the environment and the file. (#3)
- The Go Habs Go banner plays out its frames once the session is ready
  rather than vanishing with the ready message, so a start that took a
  single frame still shows the whole banner; any key ends it at once. When
  `NO_COLOR` is set in the environment `lmx` started in — a desktop launcher
  or an agent's shell often sets it — a startup notice names the variable
  and where to unset it, `/theme` shows `(NO_COLOR is set)` after the
  theme's name, and `lmx explain` reports `TERM`, `COLORTERM` and `NO_COLOR`
  under `diagnostics.terminal`. The convention is kept, not overridden. (#4)
- A bare `/` in the terminal UI lists `lmx`'s own commands and nothing else.
  Skills from anywhere else — the repository's, your `~/.lmx/skills`, the
  ones Claude Code, Codex or another agent keep under your home directory,
  Omarchy's, a plugin's, a `--skill-dir` — sit on tabs named for where they
  came from (Project, Personal, Claude, Codex, Agents, System, Plugins,
  `--skill-dir`), switched with Shift-Tab or a click; typing a skill's name
  from the default tab jumps to the tab that has it. A machine with skill
  packs installed for another agent used to show dozens of them before the
  first of `lmx`'s commands. With no skill outside `lmx`'s own, the menu is
  the one list it was. (#1)

### Installing and updating

- `lmx update` installs a newer verified release from a terminal, through
  the same signature, checksum and archive checks as the terminal UI's
  `/update`; `lmx update --check` only says whether one is available. It
  needs no session, model key or readable config file, exits 0 when `lmx` is
  up to date or an update was installed, and says that a terminal UI that is
  open keeps running its version until restarted. From a source checkout,
  `mix lmx update` fast-forwards the checkout from its Git upstream. (#5)
- The installer recognises the launcher it wrote and upgrades its own
  installation without `--replace`, which is now only for installing over a
  `PREFIX/bin/lmx` that is something else: another program, or a launcher
  written for another prefix. It used to be needed for every upgrade, and
  read as permission to overwrite an unrelated program. (#5)

## 0.8.0 — 2026-10-05

The first public release of an open-source coding agent you can take apart:
a terminal app (lmx), and the Elixir runtime underneath it (Lemieux). The
runtime is published on Hex as `lemieux`. It is numbered 0.8.0 rather than
0.1.0 because it follows a period of private development and daily use; the
public history starts here, so this entry describes the release as a whole.

### lmx

- A full-screen terminal UI (`lmx`) and a headless `lmx run` for scripts and
  CI, with `text`, `json` and `stream-json` output and an exit status for
  each outcome: 0 answered, 1 other, 2 usage, 3 credentials, 4 a limit,
  5 cancelled, 6 provider.
- Tools on by default: `read`, `write`, `edit` (`apply_patch` in its place
  for GPT-5-family models), `bash`, `grep`, `glob`, `todo`, `skill`,
  `delegate` (a read-only repository scout) and, in the terminal UI,
  `ask_user`. Web search and page fetch join them when a Brave key is set,
  and `elixir` with `--elixir`. After a turn that edited files, the project's
  own check runs.
- Any ReqLLM provider. With no key, `lmx` uses a local Ollama model that can
  call tools if one is served, and otherwise the terminal UI opens a provider
  panel with nothing preselected. A first prompt sent without a key names no
  vendor. `/provider ollama` switches to the Ollama model you configured or
  used recently if Ollama serves it, else to a local one that can call tools,
  and `/model` leaves out the local models that cannot. For Ollama models
  `lmx` reads the context window the daemon serves, warns when that is too
  small, and caps an answer at 16,384 tokens.
- Sessions you can come back to: `-c`, `--resume`, `lmx log`, `lmx fork` and
  `lmx request`; `lmx explain` reports what a session would start with. Each
  session is named after a hockey player (`wayne-gretzky`), from public
  roster listings kept as name slugs only
  ([NOTICE](https://github.com/houllette/lemieux/blob/main/NOTICE)); a
  reviewed list of crude-reading names is never used.
- `/undo`, `/rewind N` and `/redo` take back what a turn changed: everything
  `write`, `edit` and `apply_patch` changed (files up to 10 MB) and, in a git
  repository, what commands and the post-edit check changed in tracked files
  and in untracked files up to 1 MB, from snapshots taken around each of
  them. They name what they could not put back, such as ignored files like
  `.env`, or files stored through Git LFS, that a command changed;
  [Taking changes back](docs/everyday.md#taking-changes-back) has the full
  list.
- A documented subset of Claude Code compatibility: instruction files with
  confined `@path` imports, Agent Skills, legacy slash commands, subagent
  definitions, plugins and marketplaces, hooks in Claude Code's settings
  format (exec form and `CLAUDE_PROJECT_DIR`, `CLAUDE_PLUGIN_ROOT` and
  `CLAUDE_PLUGIN_DATA` included), and the repository's `.mcp.json`. The
  [compatibility table](docs/configuration.md#compatibility-and-trust-boundary)
  lists the gaps.
- `lmx mcp`, `lmx plugin` and `lmx extension` manage MCP servers, plugins and
  your own Elixir extensions.
- Agent Skills from where other agents keep theirs: `~/.codex/skills`,
  `~/.agents/skills`, `~/.claude/skills` and `~/.lmx/skills` (which wins a
  name clash), the repository's `.agents/skills` and `.claude/skills`, and on
  [Omarchy](https://omarchy.org) Omarchy's own skills, read in place
  (`"skills": {"omarchy": false}` turns that off). A skill reached through
  several links is offered once, `"skills": {"disabled": [...]}` leaves
  skills out by name, and the `skill` tool loads the files beside a skill
  from its real directory. `lmx skills` lists what a session finds, where
  each skill came from and whether it is enabled.
- `lmx --prompt TEXT` opens the terminal UI and sends `TEXT` as the first
  message once the session is up, after any provider setup or trust
  question.
- Terminal handling: a light theme when the terminal's background is light,
  256 colours when it does not advertise 24-bit colour, wide characters
  wrapped by their display width, pastes kept intact whatever line ending the
  terminal sends, Ctrl-G to edit the prompt in your editor, `/unsteer`
  (Alt-Z) to take back a steer, and the working directory in the header and
  the window title. tmux works; GNU screen 4 cannot paste multiple lines.
- Log lines go to `~/.lmx/logs/lmx.log` instead of the screen or the output;
  `LMX_LOG_LEVEL` raises the level and also prints them on standard error,
  never over the terminal UI's screen.
- A blank `LMX_*` variable that names a model, a route, a path or a limit
  counts as unset (`LMX_MAX_TURNS=` falls through to the config file);
  `LMX_WEB_FETCH`, `LMX_PROJECT_MCP` and `LMX_DELEGATE` still read blank as
  off.
- A source checkout runs any `lmx` command with `mise exec -- mix lmx`, and
  keeps crash dumps out of the checkout as the installed `lmx` does.

### Installing and updating

- Native archives for macOS (Apple Silicon and Intel), Linux x86-64 and, as
  an experiment, Windows x86-64, with a one-line installer for macOS and
  Linux. Installs are per user. On Windows, `lmx` needs Git Bash (from Git
  for Windows) and never uses WSL's bash.
- The Linux archive carries its own OpenSSL and needs glibc 2.34 or newer,
  CA certificates and `awk`. Every release build runs it on Fedora, Rocky
  Linux 9, Amazon Linux 2023, openSUSE Tumbleweed, Debian 12 and Ubuntu
  24.04.
- The commands, hooks, MCP servers and editor that the installed `lmx`
  starts get the environment you started it in: your own `PATH`, so your own
  `erl`, `elixir` and `mix` run rather than the bundled runtime's.
- File names are read as UTF-8 whatever the locale says, so a container or
  `ssh host lmx` without a locale prints no encoding warning, not even on the
  first start after an install.
- Releases are signed with an offline Ed25519 key. The installer verifies
  `SHA256SUMS.sig` before it installs anything, and an installed `lmx`
  installs an update on its own only after `update.json.sig` verifies against
  the key compiled into it; an unsigned or altered release is never
  installed. `LMX_AUTO_UPDATE=0` keeps the notices but installs only on
  `/update`, and `LMX_CHECK_UPDATES=0` turns the automatic checks off
  (`/update` still checks).
- Each archive carries `LICENSE`, `NOTICE` and `THIRD_PARTY_NOTICES`, and the
  installer keeps them.
- `lmx desktop install` (Linux) adds `lmx` to your application launcher, in
  your own data directory, opening in one fixed directory (`--directory`,
  else `~/Work` on Omarchy, else your home directory); on Omarchy it opens
  through `omarchy-launch-tui`. `lmx desktop uninstall` removes only what it
  wrote, and installing or updating `lmx` never changes your desktop.
  [Desktop launchers and Omarchy](docs/desktop.md) covers keybindings, the
  Omarchy menu and the commands an agent launcher uses to start `lmx`.
- An interrupt, a closed terminal and `SIGTERM` cancel the running turn, then
  stop `lmx` with status 130, 129 or 143. Crash dumps go to `~/.lmx/crash`,
  not into your project, and the commands the agent runs keep their own
  crash-dump setting.

### Security defaults

`lmx` runs tools without asking by default ("full auto", said at startup);
`--permission-mode ask` and `--sandbox` are opt-ins.
[What lmx trusts by default](SECURITY.md#what-lmx-trusts-by-default)
describes all of it. In short:

- The installed `lmx` never reads a `.env` from the directory it starts in.
- `lmx mcp list`, `lmx mcp trust` and the terminal UI's trust question show
  every string from a repository's `.mcp.json` with control and invisible
  characters written out as escapes, so a server entry cannot rewrite your
  terminal while you decide whether to trust it.
- Deleting a symbolic link removes the link, and `/undo` never reads,
  deletes or removes directories through a directory that has become a
  symbolic link.
- A repository's instruction imports and symbolic links cannot reach outside
  it, its learned overlay can only add text (and is named at every start),
  its hooks and extensions never run on their own, and its `.mcp.json`
  servers start only once you trust them.
- Environment variables whose names contain `KEY`, `TOKEN`, `SECRET`,
  `PASSWORD` or `PASSWD` are withheld from commands, hooks, MCP stdio servers
  and the Elixir node.
- A timed-out or cancelled command's whole process group is killed, even
  when the VM dies first.
- `--sandbox` (macOS Seatbelt, Linux bubblewrap) hides credential locations
  (`~/.ssh`, `~/.aws`, git's credential store, `~/.pypirc`, cloud CLI
  credentials, the Codex and Claude Code sign-ins and more) and `lmx`'s own
  state from commands and from the file tools. A state directory that is
  your project, your home or a temporary directory (a config file kept
  there, with `LMX_HOME` unset) keeps its checkpoints and plugins in their
  reach.
- `lmx`'s own git (`/undo`'s snapshots and restores, the startup status,
  `/doctor`, the A2A server's revision and dirty checks, the scout's
  revision) runs nothing a repository configures: no hook, `core.fsmonitor`,
  filter driver or submodule configuration. Snapshots, restores and status
  checks run in a private git directory, and the other questions put to the
  repository itself run with hooks, `core.fsmonitor` and transports turned
  off. A sandboxed command that rewrites `.git/config` or the hooks cannot
  make it run a program outside the sandbox, and a repository whose
  `core.worktree` points elsewhere is not snapshotted.
- A blank `LMX_EXTENSIONS_DIR` means `~/.lmx/extensions`, never the
  directory `lmx` started in.
- The check after edits goes through the permission policy like any `bash`
  call.
- Transcripts and MCP OAuth tokens (`~/.lmx/mcp-credentials.json`) are
  written with mode 0600, in directories created 0700.
- Jev compaction is bundled and turns on only with a Jev key or an Ixway
  route; [what it sends to TypeSafe](SECURITY.md#what-lmx-sends-and-where) is
  disclosed.

### The library

- **Sessions you own.** A supervised session runs the model/tool loop.
  `Lemieux.run/2` answers one prompt; `Lemieux.start_session/1` with
  `Lemieux.Session.await/3` keeps a conversation going, with steering,
  follow-ups, cancellation and retry. Hosts mount `Lemieux.Supervisor` in
  their own supervision tree: adding the dependency starts no Lemieux
  processes. A missing mount or option raises an `ArgumentError` that says
  what to add.
- **An event-sourced transcript.** Prompts, model requests, tool calls and
  results are appended to a store (`Lemieux.Store.JSONL` by default): resume
  a session, fork it at a completed turn, and inspect or replay the
  canonical, provider-neutral request behind each model call. Transcripts are
  single-writer and versioned; see
  [transcript compatibility](docs/transcript-compatibility.md).
- **Providers through ReqLLM**, local Ollama models included: streaming,
  retries for transient failures, Anthropic prompt caching, recovery from
  context overflow, and usage and cost accounting. Sessions take request,
  turn and dollar limits.
- **Four default tools**, `read`, `write`, `edit` and `bash`, with path
  confinement, bounded output and non-interactive shells. Optional tools:
  `grep`, `glob`, `apply_patch`, `todo`, `ask_user`, web search and page
  fetch, and Elixir evaluation on a separate node. Tools can return image and
  PDF attachments.
- **Policy through hooks** that deny a call, rewrite it or park it for
  asynchronous approval; command hooks also read Claude Code settings files.
  Two protections are opt-in: `Lemieux.Extensions.Permissions` and the
  `Lemieux.Environment.Sandbox` sandbox.
- **Extensions.** `Lemieux.Harness` holds a session's settings, and
  `Lemieux.Extension` composes changes into it. The shipped extensions add
  search, planning, verification after edits, checkpoints with undo,
  delegation, MCP, web tools and workspace discovery.
- **Context management:** automatic compaction with replaceable strategies
  (`Lemieux.Compaction`) and a price-aware check before large requests.
- **MCP client** for stdio and Streamable HTTP servers, with OAuth sign-in,
  prompts, resources, tool-list changes, cancellation and per-server
  timeouts.
- **Delegation and A2A:** bounded subagents with their own authority, budget
  and deadline; configured A2A 1.0 peers and a read-only A2A service.
- **Observability:** `Lemieux.Telemetry` events and an opt-in OpenTelemetry
  bridge.
- **Tests without a network:** `Lemieux.Providers.Scripted` and
  `Lemieux.Testing` drive real sessions from scripted model responses.

### Experimental

The harness-learning, discovery, benchmarking, feedback and evaluation
workflows (`mix lemieux.*`, `lmx feedback`, `lmx corpus`, `lmx harness`) and
the modules under `Lemieux.Learning`, `Lemieux.Benchmark`,
`Lemieux.Experiment`, `Lemieux.Asset`, `Lemieux.Feedback`,
`Lemieux.Reflection`, `Lemieux.Evidence` and `Lemieux.Agent` may change in any
0.x release. Case drafts never copy secret-shaped files (`.env`, private
keys, credential files), and `lmx corpus promote` refuses them unless you pass
`--allow-secret-files`. Projects the extension builder generates depend on
`lemieux` from Hex. `mix lemieux.extension.eval` refuses a live configuration
without `--allow-live`; a scripted one runs as before.

### Requirements

- Elixir `~> 1.19`. CI compiles the package as a dependency on Elixir 1.19.0
  with OTP 27, and runs the test suite on Elixir 1.19 with OTP 28 and on
  Elixir 1.20.2 with OTP 29.
- The terminal UI needs the optional `ex_ratatui` dependency, which downloads
  a precompiled native library; a library host does not need it.
