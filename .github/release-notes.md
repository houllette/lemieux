# Lemieux 0.11.0

Plan and review work durably, connect an editor over ACP, and bound a whole job's
requests and cost. Hosts can opt into recoverable background jobs, isolated
writers and source-verified repository context. This release also makes input,
approval and extension activity easier to audit. Installed copies need a restart
on every platform.

## What changed

- **Plan and review before editing.** `/plan` drafts, edits, approves and exports
  a persistent plan. Planning stays read-only until its obligations are approved;
  progress retains that approval. `/review` pins the working, staged, commit or
  range changes being reviewed and restricts write and shell tools.
- **Editor and headless workflows.** `lmx acp` exposes native sessions over ACP
  versions 1 and 2, with streaming, approvals, cancellation, loading and forking.
  `lmx run --output-schema FILE` validates the final JSON answer and records the
  schema digest; invalid output fails without a paid repair request.
- **Guarded defaults.** `auto` is the default permission mode. Workspace edits
  are automatic, and commands use an OS sandbox when one is available. Without
  a sandbox, commands and external capabilities require approval. An unattended
  request that needs approval is denied. Explicit sandbox requests fail closed.
- **Whole-job budgets and verification.** `--max-total-requests` and
  `--max-total-cost-usd` share one allowance across parent and child inference,
  summaries, checks, compaction scoring and paid tools. Verification observes
  workspace changes, including shell edits and failed commands, and names
  checks that were skipped or unavailable. A normal stop still does not mean
  the result was verified.
- **Background jobs and isolated writers.** Opt-in hosts can queue, schedule,
  detach, attach, cancel and reconcile durable jobs under current authority.
  Writer batches keep file ownership, shared budgets, reviewable artifacts and
  guarded integration in separate worktrees. Interrupted integration preserves
  recovery evidence and rolls back failed checks. Parallel writers remain an
  explicit host choice; worktrees alone do not sandbox execution.
- **Fresh repository context.** The optional `repository_context` tool returns
  bounded maps, definitions, references, dependencies, symbols and diagnostics.
  Current path policy and source digests gate disclosure; stale records are
  withheld and a literal search can supply current source. The offline Elixir
  index reads and parses without evaluating repository code. No language server
  or persistent retrieval memory starts implicitly.
- **Input, approvals and extension status.** Hosts can attest current input
  provenance and bind approval resolution to the effective call and current
  context. Replayed text cannot recreate authority. `/status` and `lmx status`
  expose local extension observations and cancellation commands; evidence
  separates catalog bytes, notices and extension-started requests from provider
  usage. Missing usage stays unknown.
- **Workspace, provider and MCP repairs.** Reads and instruction discovery use
  the effective environment. Scoped `.claude/rules` activate before matching
  native file operations. Provider retry and cache-key behavior agrees across
  hosts. MCP stdio bounds frames, pending responses and stderr, and records
  termination and cleanup evidence. Malformed negotiation and cyclic pagination
  return errors. Todo, subagent and completion receipts are easier to scan.

The [changelog](https://github.com/houllette/lemieux/blob/v0.11.0/CHANGELOG.md)
contains the complete changes and migration notes. Jobs, writers and repository
context are opt-in; their mechanical tests do not establish an agent-quality or
cost advantage.

## Updating from 0.10.0

An installed `lmx` on macOS or Linux stages the release after its signed manifest
is published, or when you run:

```sh
lmx update
```

Save an unsent draft, quit and start `lmx -c` to resume. The exit message also
prints `lmx --resume PLAYER-NAME` for the session you just left. New session and
harness state, supervision and modules require fresh initialization; this is a
restart update on every platform.

`LMX_AUTO_UPDATE=0` keeps notices but installs only on `lmx update` or `/update`.
Windows updates by downloading and unpacking the new archive.

Script extensions pinned to a bare 0.10 version or a patch-line requirement such
as `~> 0.10.0` need their code and manifest reviewed for 0.11. Compiled bundles
retain extension API 1; rebuild any bundle that `lmx extension list` refuses.

## Library migration

Add `{:lemieux, "~> 0.11.0"}` to your dependencies. The library still starts no
Lemieux processes; hosts mount its supervisor and supply storage, credentials,
environments and current policy.

- Hosts opting into jobs or writers supply shared allowances and lifecycle,
  verification and integration callbacks. Existing scouts remain read-only.
  Ordinary session resume is unchanged; `Session.continue/1` requires a
  reconciled `recover_tools: true` resume for interrupted tool execution.
- Input attestors, configured tools, contribution callbacks, credentials and
  approval authority must be supplied by the current host again on resume;
  transcript evidence is inert. Scoped approval and input capture are opt-in.
- Match the budget and evidence fields you use. Job accounting, input provenance,
  extension activity and tool lifecycle evidence add fields to those results.
- Provider retries belong to the runtime host; explicit retry settings and stable
  session cache keys are preserved. Optional source context requires explicit
  repository scopes and trusted adapters.

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
[Verify a download](https://github.com/houllette/lemieux/blob/v0.11.0/docs/releases.md#verify-a-download).
The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.

**From source**, anywhere mise can install the pinned Erlang and Elixir:

```sh
git clone https://github.com/houllette/lemieux.git && cd lemieux
mise install && mise exec -- mix deps.get
mise exec -- mix lmx -C /path/to/your/project
```

`mise exec -- mix lmx` runs any `lmx` command from the checkout, and
`mix lmx update` fast-forwards it from its Git upstream.

**As a library**, add `{:lemieux, "~> 0.11.0"}` and start with
[First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html),
which runs a complete session without an API key. See
[Library migration](#library-migration) for changes to existing hosts.

## Before your first session

- `auto` is the default permission mode. Use `--permission-mode ask` for approval
  of tool actions, or `--sandbox` to require an available OS sandbox. `full_auto`
  and `off` explicitly select unrestricted execution. See
  [the trust model](https://github.com/houllette/lemieux/blob/v0.11.0/SECURITY.md#what-lmx-trusts-by-default).
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
