# Lemieux 1.1.1

Lemieux 1.1.1 fixes terminal input, context and cost reporting, planning and
provider recovery while retaining the supported 1.x library, CLI and extension
contracts.

## What changed

- **Editable answers and file references.** Free-form, Other and note editors
  have a visible theme-aware blinking cursor. Arrow keys edit the focused
  answer; Tab changes questions while preserving drafts. File completion
  respects submitted `@` references, quoted paths and surrounding punctuation.
- **Honest context measurements.** Missing or explicitly unreported usage
  invalidates the prior measurement. Displays distinguish the actual context
  window, planning cap, compaction forecast and measurement freshness.
- **Clear cost and cache reporting.** Unreported cache counters stay unknown.
  Subscription/catalog comparisons are labeled API-equivalent estimates;
  Codex comparisons use OpenAI reference tariffs. Estimates do not establish
  cash charges, remaining quota or real hosted cache hit rates.
- **Plans that can change after discovery.** Provisional plans use task-driven
  granularity and can expand or rename steps after substantive discoveries.
  A new unrelated task still starts a separate plan.
- **Network recovery.** Typed network-down and network-unreachable failures
  use the existing retry/backoff and budget policy, including interrupted
  streams.
- **Host transport fixes.** Visible click targets and hover share hit testing,
  covered targets stay inactive, and opted-in cell transports receive
  deduplicated pointer/restore intents. Native local-pointer support remains
  pending an upstream ExRatatui capability/lifecycle API.

The bounded MCP diagnostic pipe shipped in 1.1.0. This patch adds offline
regression coverage for delayed SSH-like errors, reconnect cleanup and editor
preservation; it makes no claim about a real SSH disconnect.

The [changelog](https://github.com/houllette/lemieux/blob/v1.1.1/CHANGELOG.md)
has the detailed changes.

## Update from 1.1.0

**Restart on every platform. No hot update or live downgrade is declared.**
Context/conversation and TUI state changed, and the new hover module has no
supported live migration.

Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session. Personal config
version 1, extension API 1 and supported 1.x contracts remain compatible;
no config or transcript migration is required. Consumed budgets remain attached
to the resumed session. See the
[upgrade steps](https://github.com/houllette/lemieux/blob/v1.1.1/docs/releases.md#upgrading-from-110-to-111).

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
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.1.1/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.1"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.1.1/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.1.1/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation and experimental learning/benchmarking APIs retain
their existing status. This patch makes no claim of live provider/model
quality, hosted cache effectiveness or improved learning outcomes. Native
local-pointer feedback, transcript-spacing, todo-subtask and snippet-copying
proposals retain their documented scope on the
[roadmap](https://github.com/houllette/lemieux/blob/v1.1.1/docs/roadmap.md).
