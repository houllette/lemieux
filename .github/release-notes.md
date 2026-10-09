# Lemieux 0.10.0

Agents can draw diagrams, tables and charts directly in the transcript. Startup
shows the work being done, changed files have a tree and patch view, and copying
an answer preserves the diagrams you saw. This is a restart release on every
platform.

## What changed

- **Drawings in the conversation.** Mermaid flowcharts, sequence, C4, state and
  ER diagrams render alongside bounded, read-only A2UI tables, charts, progress
  bars and file trees. The terminal fits them and applies its theme; a narrow
  pane shows the complete relationships as text. Agents can use Mermaid directly,
  with an optional `diagram_preview` tool to check syntax, fit or native schemas.
  [Agent visualizations](https://github.com/houllette/lemieux/blob/v0.10.0/docs/terminal-ui.md#agent-visualizations)
  explains the supported elements and layout controls.
- **A Drawing receipt while the agent works.** A streamed diagram shows one
  captioned Drawing placeholder, followed by the validated result. A failed
  drawing sends its errors to the agent for one repair continuation per prompt;
  the allowance survives resume and respects request, spending and cancellation
  limits. Valid drawings add no request. Failed source stays available through
  `/copy source`.
- **Copy the rendering.** `/copy` keeps diagram connectors, indentation and
  interior blank rows in monospace text fences across the whole latest answer.
  `/copy source` copies the original Markdown, Mermaid or A2UI source.
- **Startup and progress.** The boot log appends real extension-loading and
  initialization steps and hands over as soon as everything is ready. The Habs
  marquee remains the default; `startup_animation` customizes it or turns it off.
  The startup info box sits within the transcript and dismisses after five
  seconds. A spinner accompanies working verbs, and context and plan progress
  use measured bars.
- **Review changed files.** `/diff` shows a file tree with per-file patches.
  Exit messages name the session that was actually saved and offer its short
  player name to `--resume`, including sessions with a custom `/name` caption.
- **Input and provider fixes.** Ctrl-U and a reported Cmd-Backspace delete to the
  start of the input line; undo moves to Ctrl-Z. Stray modified keys type nothing.
  Policy refusals are classified without retries, bash waits fit the session's
  tool deadline, and OpenAI requests keep a stable session cache key. Streaming
  preserves HTTP error metadata with ReqLLM 1.27.
- **Budgets and completion.** Models see notices as request or host time budgets
  are used. An optional completion check asks the model to verify the request's
  concrete requirements against its result. Evaluation checks reject mismatched
  baselines before a run and keep missing safety attestation distinct from a
  verified safety result.

The [changelog](https://github.com/houllette/lemieux/blob/v0.10.0/CHANGELOG.md)
contains every change and migration note. The UI includes `ascii` 0.4.1 and
ExRatatui 0.17; diagram labels wrap at word boundaries.

## Updating from 0.9.1

An installed `lmx` on macOS or Linux stages this release after its signed
manifest is published, or when you run:

```sh
lmx update
```

Save an unsent draft, quit and start `lmx -c` to resume. The exit message also
prints `lmx --resume PLAYER-NAME` for the session you just left. The updated
native terminal library, new modules and TUI state require a fresh process;
this release does not load into a running screen.

`LMX_AUTO_UPDATE=0` keeps notices but installs only on `lmx update` or `/update`.
Windows updates by downloading and unpacking the new archive.

Script extensions naming a bare 0.9 version or a patch-line requirement such as
`~> 0.9.0` need their code reviewed and manifest updated for 0.10. Compiled
bundles retain extension API 1 and load when their API, OTP and Elixir checks
pass. Run `lmx extension list` and rebuild any bundle it refuses.

## Library migration

Add `{:lemieux, "~> 0.10.0"}` to your dependencies. The library still starts no
Lemieux processes and requires no terminal dependency in an embedding host.

- `Lemieux.Providers.ReqLLM.new/1` now defaults to an unlimited HTTP receive
  timeout and a five-minute stream idle timeout. To keep the previous HTTP
  bound, pass `receive_timeout: :timer.minutes(2)`; explicit host settings win.
- Hosts matching provider error categories exhaustively need a `:refused`
  clause. A policy refusal is not retried.
- `Lemieux.Session.budget/1` returns additional request and deadline keys; match
  the fields you use rather than comparing the whole map.
- Experimental evaluation runtimes must report `safety_violations` for a
  safety-scoped observation (`[]` when none were observed). Missing attestation
  cannot pass a safety gate.

## Install lmx

On macOS and Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
lmx --version
```

The installer needs `curl` and Python 3.8 or newer. It checks the signature
on `SHA256SUMS` against the release key pinned in it, checks every download
against those checksums, installs for your user only (under `~/.local`), and
runs nothing from the archive while it installs.

| Platform | Archive | Notes |
| --- | --- | --- |
| macOS, Apple Silicon | `lmx_macos_silicon.tar.gz` | macOS 15 or later. Not signed by Apple: install it with `install.sh`, not by unpacking it in Finder. |
| macOS, Intel | `lmx_macos.tar.gz` | As above |
| Linux x86-64 | `lmx_linux.tar.gz` | glibc 2.34 or newer (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, openSUSE, Amazon Linux 2023), CA certificates and `awk` |
| Windows x86-64 | `lmx_windows.tar.gz` | Experimental: verify it, unpack it and run `bin\lmx.cmd`. Needs Git Bash, which Git for Windows installs; under WSL2, install the Linux build inside WSL |

Linux arm64 and musl distributions such as Alpine have no build yet; use the
source checkout. To check this release yourself before you run anything,
follow
[Verify a download](https://github.com/houllette/lemieux/blob/v0.10.0/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, and
`mix lmx update` fast-forwards it from its Git upstream.

**As a library**, add `{:lemieux, "~> 0.10.0"}` and start with
[First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key. See
[Library migration](#library-migration) for changes to existing hosts.

## Before your first session

- `lmx` runs tools **without asking** by default, and `bash` runs as your
  user, not sandboxed; the startup notice says "full auto". Use
  `--permission-mode ask` to approve each action and `--sandbox` to confine
  commands.
  [What lmx trusts by default](https://github.com/houllette/lemieux/blob/v0.10.0/SECURITY.md#what-lmx-trusts-by-default)
  has the whole trust model.
- Your provider bills the requests `lmx` makes; `--max-requests` and
  `--max-cost-usd` set limits. A task with open items in its plan sends the
  model back to them, which is more requests; `"continuation": false` turns
  that off. With no key set, `lmx` uses a local Ollama model that can call
  tools if Ollama serves one; otherwise the terminal UI asks you to choose a
  provider.
- Your personal instruction files (`~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md` and others) and skills go to the model together with
  the repository's; the slash menu keeps the skills on tabs named for where
  they came from.
- The installed `lmx` never reads a `.env` from the directory it starts in;
  keep keys in your environment or in `~/.lmx/config.json`.
- A repository's `.mcp.json` servers start only after you trust them.
- The installed `lmx` checks for updates hourly and installs one only after
  its signature verifies; `lmx update` does the same from a terminal.
  `LMX_CHECK_UPDATES=0` turns the automatic checks off.

## Known limitations

- Pre-1.0: a minor release may change library APIs, and the changelog says
  how to migrate.
- The macOS and Windows archives are not signed by Apple or Microsoft.
- Windows is experimental: no installer and no automatic updates.
- No Linux arm64 or musl build yet.
- `/undo` cannot put back everything a command changed (ignored files, files
  stored through Git LFS or another git filter, work outside a git
  repository, commits); it names what it could not.
- Harness learning, benchmarking and feedback workflows are experimental.

## Assets

The four archives, `install.sh` and `install.py`, `SHA256SUMS` and its
signature `SHA256SUMS.sig`, `update.json` (what installed copies read) and
`update.json.sig`, `LICENSE`, `NOTICE`, these notes and the upgrade plan.
`SHA256SUMS` lists every asset except the signatures.
