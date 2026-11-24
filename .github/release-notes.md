# Lemieux 1.2.2

Lemieux 1.2.2 fixes switching to Anthropic with diagram previews enabled,
adds terminal pickers for sessions and service tiers, and improves recovery
when long-running turns hit a limit or need a retry.

## What changed

- **Providers and terminal UI.** Switch to Anthropic with `diagram_preview`
  enabled. Use `/priority` to select a supported service tier and `/model`
  to select Standard access for eligible OpenAI Responses models. The header
  shows the requested access program and provider confirmation when available.
- **Sessions.** Search this folder's sessions or all sessions with `/resume`.
  Retries, cancellation, and replay preserve transcript order and account for
  provider usage. Compaction retries use a smaller reasoning budget where
  supported, and turn-limit messages explain how to continue.
- **Tools.** The MCP panel shows pending stdio requests, progress, and the
  silence budget. Post-answer verification keeps diagnostic detail in Tasks.

See the [full changelog](https://github.com/houllette/lemieux/blob/v1.2.2/CHANGELOG.md).

## Update from 1.2.1

**Restart on every platform.** The release updates runtime dependencies and
changes session and terminal state. Save unsent drafts, stage the signed
update with `lmx update` or `/update`, then restart and resume with `lmx -c`
or `lmx --resume SESSION`. The installer-managed TUI restart preserves its
exact session. You can resume existing transcripts and continue using personal
config version 1 and extension API 1.

## Install

On macOS or Linux:

```sh
curl -fsSL https://github.com/houllette/lemieux/releases/latest/download/install.sh | sh
```

The installer needs curl and Python 3.8 or newer, verifies signatures and
checksums, and installs per user under `~/.local`. Add `~/.local/bin` to PATH.

| Platform | Support |
| --- | --- |
| macOS, Apple Silicon and Intel | macOS 15 or later. Use the installer for the unsigned archives. |
| Linux x86-64 | glibc 2.34 or newer, CA certificates, `awk` and `libgcc_s` |
| Windows x86-64 | Experimental. Unpack the archive manually and use Git Bash. |
| Linux arm64 or musl | Use a source checkout. |

The release-signing public key is `X7aGNLOgOV+bz13CuG4x4AVnhKmsPIH8eYvBrajsiG8=`.
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.2.2/docs/releases.md)
explain the signature and checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.2"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer. The host owns credentials, storage
and policy. See [First embedded agent](https://hexdocs.pm/lemieux/1.2.2/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default. Workspace edits run automatically. Commands run
automatically inside an available OS sandbox and ask for approval otherwise.
MCP, web and eval tools ask either way. The installed binary ignores a working
directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.2.2/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation, ACP draft v2 and learning and benchmark APIs
remain experimental.
