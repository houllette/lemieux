# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
Before 1.0, a minor release may change public APIs; each such change is listed
with migration notes. [Support](docs/support.md) says what counts as public
API.

## Unreleased

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
