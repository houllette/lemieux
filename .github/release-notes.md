# Lemieux 0.12.0

This release adds native task and tool controls, scoped workspace experience,
and bounded verification replay. Installed copies need a restart on every
platform. Learning and qualification interfaces remain experimental; their
mechanical tests do not establish a general model-quality or cost advantage.

## What changed

- **One Tasks view.** Shift+Up, its clickable badge, or F6 opens a native tray
  for agents, background commands and external runs. It preserves the draft,
  shows live output and full command source, and supports steering and scoped
  cancellation. Session watches observe existing work without model polling.
  Completion can resume the idle owner under current policy and remaining
  limits; the tray can select notification only.
- **Native tool management.** `/tools` shows availability, descriptions and
  keyboard/mouse toggles without filling the transcript with switch receipts.
  Guidance reflects the tools and permissions actually available to the session.
- **Scoped experience with local controls.** CLI/TUI sessions with personal
  state retain observations and can add bounded, unconfirmed guidance to later
  requests. Capture and recall add no inference requests. `lmx learning inspect`
  reads the evidence offline; `lmx learning undo` blocks the last adaptation and
  dependent lessons, and `lmx learning off` opts the workspace out persistently.
- **Bounded verification replay.** A reproducible failure can trigger a fixed
  isolated refinement only with complete evidence, a cached replay image and a
  finite whole-job allowance. The 48-slot experiment needs
  `--max-total-requests` of at least 192; other work shares that same allowance.
  Missing prerequisites abstain before learning dispatch. Supported guidance is
  temporary and source-backed; unknown or interrupted usage requires recovery.
- **Portable, reviewed learning assets.** Typed procedure files, trusted tool
  descriptions and allowlisted search settings retain their complete bytes and
  runtime bindings through native export. Receiving hosts revalidate current
  policy and supply fresh approval. Confirmed export requires a complete
  dependency/capability manifest and source-bound CodeGate/reviewer evidence.
  Research qualification retains complete reflection records and one durable
  allowance across stages; incomplete runs remain incomplete evidence.
- **Provider and workspace repairs.** ReqLLM 1.29 verifies certificate trust and
  hostnames for secure WebSocket connections, including Codex subscription
  transport ([upstream advisory](https://github.com/agentjido/req_llm/security/advisories/GHSA-6vww-5m28-f26v)).
  The release also includes upstream reasoning/terminal-stream and billing
  metadata fixes, native Ixway harness attribution, sanitized startup Git
  origins, environment-correct directory searches and remote undo notices.

The [changelog](https://github.com/houllette/lemieux/blob/v0.12.0/CHANGELOG.md)
contains the full changes and migration notes. See
[ordinary-use controls](https://github.com/houllette/lemieux/blob/v0.12.0/docs/harness-learning.md#ordinary-use-experience-and-controls)
for learning prerequisites, accounting, evidence and opt-out behavior.

## Updating from 0.11.0

An installed `lmx` on macOS or Linux stages the release after its signed manifest
is published, or when you run:

```sh
lmx update
```

Save an unsent draft, quit and start `lmx -c` to resume. The exit message also
prints `lmx --resume PLAYER-NAME` for the session you just left. New watch and
learning modules, retained callbacks and changed dependency code require a fresh
VM; no hot upgrade or downgrade path is declared.

`LMX_AUTO_UPDATE=0` keeps notices but installs only on `lmx update` or `/update`.
Windows updates by downloading and unpacking the new archive.

Ordinary experience is enabled only with personal state. Personal
`"learning": false` or `"disabled_extensions": ["learning"]` disables it;
`"capture": false` disables both capture and this experience lane.
`--config none` without `LMX_HOME` has no personal state. A project can opt out
with `.lmx/learning.json` containing `{"enabled": false}`; project settings never
override a personal opt-out. Undo cannot retract a request already sent.

Review script extensions pinned to a bare 0.11 version or `~> 0.11.0` before
widening their code and manifest requirements. Compiled bundles retain extension
API 1 and its OTP/Elixir compatibility checks; rebuild any bundle the loader
refuses.

## Library migration

Use `{:lemieux, "~> 0.12.0"}`. The library still starts no Lemieux processes;
hosts mount its supervisor and supply storage, credentials, environments and
current policy. The CLI defaults above do not turn learning on in an embedder.

- Update an existing provider lock with `req_llm` and `llm_db` together. This
  release requires ReqLLM 1.29 and uses the LLMDB 2026.10.6 catalog.
- Requalify experimental confirmations against current runtime identities and
  complete request/terminal/transcript evidence. Historical scores, archived
  assets and source checksums cannot supply current host authority.
- Version 2 research plans keep their original analysis; version 3 is selected
  explicitly. Supply the same durable study allowance for each research stage;
  a new directory or stage must not reset consumed requests or unknown usage.
- Watch sources, refinement isolation and persistent promotion remain host-owned
  seams. Hosts opt in, supply transactional installation/recovery and current
  approval, and retain exact rollback; no persistent learning scheduler starts
  implicitly.

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
[Verify a download](https://github.com/houllette/lemieux/blob/v0.12.0/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, and
`mix lmx update` fast-forwards it from its Git upstream.

**As a library**, add `{:lemieux, "~> 0.12.0"}` and start with
[First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key. See
[Library migration](#library-migration) for changes to existing hosts.

## Before your first session

- `auto` is the default permission mode. Use `--permission-mode ask` for approval
  of tool actions, or `--sandbox` to require an available OS sandbox. `full_auto`
  and `off` explicitly select unrestricted execution. See
  [the trust model](https://github.com/houllette/lemieux/blob/v0.12.0/SECURITY.md#what-lmx-trusts-by-default).
- Your provider bills requests. `--max-requests` and `--max-cost-usd` bound the
  direct session; `--max-total-requests` and `--max-total-cost-usd` bound shared
  work. An unfinished plan can cause more requests; `"continuation": false`
  turns that continuation off. With no key, an available local Ollama model can
  be used; otherwise the terminal asks you to choose a provider.
- Personal and repository instructions, rules and selected skills guide the
  model. They do not grant execution or approval authority.
- The installed `lmx` never reads a working directory's `.env`; keep credentials
  in your environment or `~/.lmx/config.json`.
- Repository `.mcp.json` servers start after trust. Plugins and extensions are
  trusted code selected by the host.
- Installed copies check for updates hourly and install only after signature
  verification. `LMX_CHECK_UPDATES=0` disables automatic checks.

## Known limitations

- Pre-1.0: minor releases may change library APIs; migration notes are in the
  changelog. Experimental interfaces can change in any 0.x release.
- macOS and Windows archives are not signed by Apple or Microsoft.
- Windows is experimental, without an installer or automatic updates.
- Linux arm64 and musl distributions have no native archive.
- `/undo` cannot restore every shell effect, ignored file, Git filter, commit or
  change outside a repository; it reports what it could not restore.
- Background jobs, isolated writers, harness learning and evaluations remain
  experimental. Production language-server adapters and matched hosted-model
  qualification of repository context remain host work.

## Assets

The four archives, `install.sh` and `install.py`, `SHA256SUMS` and
`SHA256SUMS.sig`, `update.json` and `update.json.sig`, `LICENSE`, `NOTICE`, these
notes, the reviewed upgrade plan and per-platform upgrade reports. `SHA256SUMS`
lists every asset except the signatures.
