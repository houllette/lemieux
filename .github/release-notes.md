# Lemieux 1.1.3

Lemieux 1.1.3 makes narrow terminal layouts easier to read, adds an inspectable
Todo List, restores routed fast mode and reports agent activity through OSC
7501. The supported 1.x library, CLI and extension contracts remain compatible.

## What changed

- **Stable, readable header and status.** The version, directory and session
  label stay fixed while overflowing header metadata scrolls on its own clock.
  Transcript updates preserve scrolling progress. Status stats rotate as
  complete, viewport-sized pages every five seconds, and permission mode stays
  visible.
- **Todo navigation.** Press F5 or click the Todo List title to inspect the
  complete plan, including items hidden by the pinned preview's height limit.
  Navigate and scroll without losing the composer draft. Alt-M minimizes the
  pinned preview to a summary row and restores it when pressed again.
- **Tasks and selection.** Shift-Down closes either Tasks pane alongside Esc.
  Task descriptions and result/output text use muted grey italics. Shift-Up
  and Shift-Down select across multiline drafts, including soft wraps; F6 and
  the Tasks badge remain available while editing.
- **Routed fast mode.** `/fast` is available when the model and route explicitly
  advertise faster service, including supporting Ixway gateways. Preserve the
  chosen service tier through gateway requests, restore it with the session,
  and show active fast or ultrafast service in red in the header.
- **Terminal agent status.** OSC 7501 reports working, waiting, completed,
  failed and cancelled states to supporting terminals and multiplexers.
  Reports are independent of desktop notifications, and redirected CLI output
  stays free of status sequences. Optional `"program_status_title": true`
  adds the displayed session label and follows `/name` and session switches;
  it is off by default and leaves the ordinary window title intact.

The [changelog](https://github.com/houllette/lemieux/blob/v1.1.3/CHANGELOG.md)
has the detailed changes.

## Update from 1.1.2

**Restart on every platform. No hot update or live downgrade is declared.**
Retained conversation/TUI state, callbacks and new chrome, Todo inspector and
terminal-status modules require fresh initialization.

Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session. Personal config
version 1, extension API 1, existing plans and supported 1.x contracts remain
compatible. Consumed budgets remain attached to the resumed session.
See the [upgrade steps](https://github.com/houllette/lemieux/blob/v1.1.3/docs/releases.md#upgrading-from-112-to-113).

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
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.1.3/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.1"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.1.3/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.1.3/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation and experimental learning/benchmarking APIs retain
their existing status. This patch makes no claim of live provider/model
quality, hosted cache effectiveness or improved learning outcomes. Native
local terminal pointer feedback remains dependent on upstream capability and
lifecycle support; see the [roadmap](https://github.com/houllette/lemieux/blob/v1.1.3/docs/roadmap.md).
