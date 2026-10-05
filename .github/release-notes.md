# Lemieux 0.8.0

An open-source coding agent you can take apart: a terminal app (lmx), and the Elixir runtime underneath it (Lemieux).

This is the first public release. `lmx` runs the agent loop itself and
records every request and tool call in an append-only transcript, so you can
resume a conversation, fork it at an earlier turn, and inspect the canonical
request behind each model call. The runtime underneath is the
[`lemieux`](https://hex.pm/packages/lemieux) package on Hex, which you can
embed in any OTP application.

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
| macOS, Apple Silicon | `lmx_macos_silicon.tar.gz` | macOS 15 or later (tested on macOS 27.2). Not signed by Apple: install it with `install.sh`, not by unpacking it in Finder. |
| macOS, Intel | `lmx_macos.tar.gz` | As above |
| Linux x86-64 | `lmx_linux.tar.gz` | glibc 2.34 or newer (Ubuntu 22.04+, Debian 12+, Fedora, RHEL 9+, openSUSE, Amazon Linux 2023), CA certificates and `awk` |
| Windows x86-64 | `lmx_windows.tar.gz` | Experimental: verify it, unpack it and run `bin\lmx.cmd`. Needs Git Bash, which Git for Windows installs; under WSL2, install the Linux build inside WSL |

Linux arm64 and musl distributions such as Alpine have no build yet; use the
source checkout. To check this release yourself before you run anything,
follow
[Verify a download](https://github.com/houllette/lemieux/blob/v0.8.0/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout.

**As a library**, add `{:lemieux, "~> 0.8"}` to your dependencies and start
with [First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key.

## Before your first session

- `lmx` runs tools **without asking** by default, and `bash` runs as your
  user, not sandboxed; the startup notice says "full auto". Use
  `--permission-mode ask` to approve each action and `--sandbox` to confine
  commands.
  [What lmx trusts by default](https://github.com/houllette/lemieux/blob/v0.8.0/SECURITY.md#what-lmx-trusts-by-default)
  has the whole trust model.
- Your provider bills the requests `lmx` makes; `--max-requests` and
  `--max-cost-usd` set limits. With no key set, `lmx` uses a local Ollama
  model that can call tools if Ollama serves one; otherwise the terminal UI
  asks you to choose a provider.
- Your personal instruction files (`~/.claude/CLAUDE.md`,
  `~/.codex/AGENTS.md` and others) and skills go to the model together with
  the repository's.
- The installed `lmx` never reads a `.env` from the directory it starts in;
  keep keys in your environment or in `~/.lmx/config.json`.
- A repository's `.mcp.json` servers start only after you trust them.
- Jev compaction is bundled and stays off until you give it a key
  (`JEV_API_KEY`) or an Ixway route. With a key, it sends abridged
  conversation excerpts to TypeSafe, which bills each evaluation.
- The installed `lmx` checks for updates hourly and installs one only after
  its signature verifies. `LMX_AUTO_UPDATE=0` keeps the notices but installs
  only on `/update`; `LMX_CHECK_UPDATES=0` turns the automatic checks off,
  and `/update` still checks.

## Highlights

- A full-screen terminal UI with steering, a prompt queue, `/undo`,
  `/rewind` and `/redo`, and a headless `lmx run` with `text`, `json` and
  `stream-json` output for scripts and CI.
- Every model call goes through ReqLLM: Anthropic, OpenAI, Google Gemini,
  xAI, OpenRouter, DeepSeek, Z.AI, or a local Ollama model, whose served
  context window `lmx` reads.
- Sessions you can come back to: `lmx -c`, `--resume`, `lmx log`,
  `lmx fork`, and `lmx request` for the canonical request behind each model
  call.
- Tools on by default: `read`, `write`, `edit`, `bash`, `grep`, `glob`,
  `todo`, `skill`, a read-only repository scout, and `ask_user` in the
  terminal UI.
- A documented subset of Claude Code compatibility: instruction files, Agent
  Skills, slash commands, subagent definitions, plugins and marketplaces,
  hooks in Claude Code's settings format, and `.mcp.json`; the
  [compatibility table](https://github.com/houllette/lemieux/blob/v0.8.0/docs/configuration.md#compatibility-and-trust-boundary)
  lists the gaps.
- An opt-in sandbox (macOS Seatbelt, Linux bubblewrap) that hides credential
  locations from commands and file tools.
- For Elixir developers: mount `Lemieux.Supervisor` in your own supervision
  tree and run agents with your own tools, approval hooks, storage and
  budgets, with extensions, an MCP client with OAuth, A2A peers and
  telemetry.

The [changelog](https://github.com/houllette/lemieux/blob/v0.8.0/CHANGELOG.md)
has the full list.

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
