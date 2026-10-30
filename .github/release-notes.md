# Lemieux 1.0.0

An open-source coding agent you can take apart: the `lmx` terminal app and the
Elixir runtime underneath it. Lemieux owns the model/tool loop and records each
session as an append-only transcript you can inspect, resume, fork and replay.
The terminal app uses the same public API an embedding application uses.

## The 1.0 contract

Supported library callbacks, harness composition, session events and CLI
automation contracts remain compatible throughout 1.x. Minor releases add
compatible functionality; incompatible supported API changes require a new
major version. Transcript schemas and extension bundles retain their explicit
version checks. See [Support and compatibility](https://github.com/houllette/lemieux/blob/v1.0.0/docs/support.md).

The library starts no Lemieux processes when installed. Hosts mount
`Lemieux.Supervisor` and own credentials, persistence, execution environments
and policy. Models go through ReqLLM; a provider/model catalog entry is separate
from account entitlement and a qualified end-to-end tool loop.

## Included in this release

- A terminal coding workflow with tools, task and tool-management views,
  verification after edits, steering, cancellation, undo/redo and durable plans.
- Sessions, cross-process resume, fork and inspectable model requests, with
  versioned append-only transcripts and current host authorization on resume.
- An embedding API and native extension behaviours, supported through package
  consumer checks and provider-free executable tutorials.
- Independent todo plans, explicit update restarts that preserve the exact
  session, capability-aware fast modes, and native Codex structured-output fixes.
- Scoped experience controls: inspect, undo, persistent opt-out and `forget`.
  Forgetting removes captures and recalled guidance while retaining tombstones,
  transcripts, exposure receipts and refinement/accounting archives. Late
  delivery of an older prompt cannot recreate its capture.
- Enforced repository checks, including coverage and security, and immutable
  version tags. Release archives remain checksum/signature verified.

The [changelog](https://github.com/houllette/lemieux/blob/v1.0.0/CHANGELOG.md)
contains the changes. Installed copies require a restart on every platform;
no hot path is declared. Resume the previous session after restarting.

## Install

On macOS or Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
```

The installer needs curl and Python 3.8 or newer, verifies the release signature
and checksums, and installs per user under `~/.local`. Add `~/.local/bin` to
your PATH. macOS requires macOS 15 or later. Linux x86-64 requires glibc 2.34 or
newer, CA certificates, `awk` and `libgcc_s`. The archives are not Apple-signed:
use the installer rather than unpacking in Finder. Windows x86-64 remains
experimental and requires Git Bash; unpack its archive manually.

As a library, use `{:lemieux, "~> 1.0"}` and start with
[First embedded agent](https://hexdocs.pm/lemieux/first-embedded-agent.html).
That complete example needs no API key or network.

## Before your first session

`auto` is the default: workspace edits run automatically, and commands run
automatically only inside an available OS sandbox. Otherwise commands ask.
MCP, web and eval tools ask either way. `--permission-mode ask` asks before
changes; `full_auto` explicitly bypasses approvals. The startup banner reports
the actual mode and sandbox. Read [the trust model](https://github.com/houllette/lemieux/blob/v1.0.0/SECURITY.md#what-lmx-trusts-by-default).

Use request and dollar limits for your provider allowance. The installed binary
never loads a working directory's `.env`. Instructions and skills do not grant
execution authority; repository MCP configuration requires trust. Installed
updates verify signatures. `LMX_AUTO_UPDATE=0` keeps updates manual, and
`LMX_CHECK_UPDATES=0` disables automatic checks.

## Experimental features and limits

Learning, benchmarking, feedback, research qualification and learned-asset
interfaces are outside the stable public API. Capture and recall add no extra
inference requests; isolated refinement requires an existing finite allowance
and its prerequisites. Observed retention/reuse does not establish improved task
outcomes, independent transfer or lower cost. Those claims require separate
qualification. See [ordinary-use controls](https://github.com/houllette/lemieux/blob/v1.0.0/docs/harness-learning.md#ordinary-use-experience-and-controls).

Browser automation and Windows remain experimental. Linux arm64 and musl
distributions have no native archive. OS code signing/notarization is separate
from the project's release signatures. Undo cannot reverse every shell,
external-service, ignored-file or Git effect and reports its limitations.

## Assets

The four native archives, installers, signed checksum list and update manifest,
license/notices, these notes, the reviewed restart plan and per-platform archive
qualification reports. Automated qualification, real provider observations and
terminal inspection are recorded separately; these notes make no unrecorded
qualification claim.
