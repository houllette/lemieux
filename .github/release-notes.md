# Lemieux 1.1.2

Lemieux 1.1.2 fixes live permission changes, snippet copying and terminal
layout, adds optional todo subtasks, and refreshes the guides while retaining
the supported 1.x library, CLI and extension contracts.

## What changed

- **Live full-auto switching.** `/permissions full-auto` disables the CLI's
  implicit sandbox for subsequent operations; leaving that mode restores it.
  Commands already started keep their original policy. Explicitly configured
  and host-required sandboxes retain their authority, and the mode-change
  message reports the effective state. Lowercase and chunked permission-denial
  output receives the sandbox hint.
- **Todo subtasks.** Optional one-level subtasks keep stable IDs, derive their
  parent's status and divide each top-level task's share of plan progress.
  Existing flat plans retain their version-1 document format.
- **Source-aware snippet copying.** Click and release to copy a whole code
  block, including an unfinished block, or drag to select a range. Frames and
  fence labels stay out of the clipboard; tabs, Unicode, blank lines and
  source spacing are retained, and visual wraps are rejoined. Links keep
  their click-to-open action.
- **Readable terminal layout.** Wrapped input retains its first row and
  boundary spaces. Header and status overflow scroll slowly while permission
  mode stays stationary. Transcript gaps stay consistent, `/habs` replay
  omits startup milestones, and the pale-yellow Tasks badge animates while
  work is running, including between turns.
- **Compact cost and throughput reporting.** Costs round the session total
  up to cents, retain estimate/unknown labels and preserve accounting and
  budget precision. Per-request throughput decorations give way to a measured,
  duration-weighted turn average that resets each turn; the session average
  remains available.
- **Code and guide cleanup.** Remove unused internal helpers and obsolete
  request-row formatting after a Reacher audit. Guides now describe the
  current approval defaults, snippet copying and completed UI work.

The [changelog](https://github.com/houllette/lemieux/blob/v1.1.2/CHANGELOG.md)
has the detailed changes.

## Update from 1.1.1

**Restart on every platform. No hot update or live downgrade is declared.**
The sandbox activation closure, retained TUI state/callbacks and new TUI
modules require fresh initialization.

Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session. Personal config
version 1, extension API 1, existing flat plans and supported 1.x contracts
remain compatible. Consumed budgets remain attached to the resumed session.
See the [upgrade steps](https://github.com/houllette/lemieux/blob/v1.1.2/docs/releases.md#upgrading-from-111-to-112).

## Install

On macOS or Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
```

The installer needs curl and Python 3.8 or newer, verifies signatures and
checksums, and installs per user under `~/.local`. Add `~/.local/bin` to PATH.

| Platform | Support |
| --- | --- |
| macOS, Apple Silicon and Intel | macOS 15 or later; use the installer, since the archives are not Apple-signed |
| Linux x86-64 | glibc 2.34 or newer, CA certificates, `awk` and `libgcc_s` |
| Windows x86-64 | Experimental; unpack the archive manually and use Git Bash |
| Linux arm64 or musl | Use a source checkout; no native archive |

The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.1.2/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.1"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.1.2/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.1.2/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation and experimental learning/benchmarking APIs retain
their existing status. This patch makes no claim of live provider/model
quality, hosted cache effectiveness or improved learning outcomes. Native
local terminal pointer feedback remains dependent on upstream capability and
lifecycle support; see the [roadmap](https://github.com/houllette/lemieux/blob/v1.1.2/docs/roadmap.md).
