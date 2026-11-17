# Lemieux 1.2.0

Lemieux 1.2.0 expands editor integration through ACP, adds native hover pointers
in supporting terminals, and makes active work easier to inspect and stop.
The supported 1.x library, CLI and extension contracts remain compatible.

## What changed

- **Editor integration.** Use `lmx acp setup` to configure credentials and a
  model before connecting Zed. ACP exposes model/reasoning selectors, form
  questions, tool locations and file diffs. V1 editor text access includes
  unsaved buffers while preserving host filesystem policy and approvals.
  Session load/resume and repeated close are corrected. Experimental draft v2
  clients must adopt the updated configuration/capability shapes and
  `_meta["com.github.houllette.lemieux/capabilities"]` namespace; v1 keeps
  `_meta.lemieux`. Registry metadata is prepared; registry publication follows
  separate qualification.
- **Native hover pointers.** Direct Ghostty and Kitty sessions show a pointer
  over visible click targets through ExRatatui 0.21.0. `LMX_HOVER_POINTER=0`
  disables it; `LMX_HOVER_POINTER=1` explicitly declares support elsewhere.
  Unknown terminals and multiplexers stay conservative. Editor handoff and
  shutdown restore the arrow; embedding hosts opt in explicitly.
- **Visible verification and cancellation.** Post-answer verification has an
  explicit phase and Tasks entry with bounded output, elapsed time and Stop
  task. Cancellation is recorded, queued follow-ups survive, and later results
  are labelled as new follow-ups. Tasks puts `[c Stop task]` first for running
  commands and agents while retaining confirmation and logs.
- **Responsive commands.** `/fast` can change during a turn and takes effect
  on the next model request, including tool continuations; requests already
  in flight retain their parameters. Faster service still requires route/model
  support and may cost more. `/usage` executes with one Enter and reports
  asynchronous fetching, results or failures. Highlighted autocomplete choices
  work on Enter and Tab during active turns.
- **Terminal fixes.** Startup notices stay in one temporary box and dismiss
  completely. FAST and ULTRAFAST badges use consistent spacing and case.
  Standard console log handlers are muted while the TUI owns the terminal,
  while file diagnostics remain available.
- **Dependency refresh.** NimblePool moves to 1.2.0 and Telemetry to 1.4.3;
  committed example locks are refreshed.

The [changelog](https://github.com/houllette/lemieux/blob/v1.2.0/CHANGELOG.md)
has the detailed changes. See [ACP setup](https://github.com/houllette/lemieux/blob/v1.2.0/docs/acp.md)
for editor configuration and protocol scope.

## Update from 1.1.3

**Restart on every platform. No hot update or live downgrade is declared.**
New ACP and verification modules, retained server/TUI state and the native
terminal dependency update require fresh initialization.

Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session. Personal config
version 1, extension API 1, existing transcripts and supported 1.x contracts
remain compatible. Consumed budgets remain attached to the resumed session.
See the [upgrade steps](https://github.com/houllette/lemieux/blob/v1.2.0/docs/releases.md#upgrading-from-113-to-120).

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
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.2.0/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.2"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.2.0/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.2.0/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation, ACP draft v2 and experimental learning/benchmarking
APIs retain their experimental status. This release makes no claim of live
provider/model quality, hosted cache effectiveness or improved learning outcomes.
