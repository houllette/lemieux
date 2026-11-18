# Lemieux 1.2.1

Lemieux 1.2.1 improves recovery in long-running sessions, keeps queued input
visible during tool work, and adds deadlines and in-memory transcripts for
embedders.

## What changed

- **Session recovery.** Automatic compaction makes one shorter attempt when a
  summary hits its output limit. During backoff, requests are checked against
  the known context window. Approved background results that arrive at the
  turn limit remain available to an explicit continuation.
- **Steering and questions.** Parent steering stays visible and revocable
  during delegate and tool work. Submitting deferred answers can continue a
  paused task with the original budget and the host's continuation policy.
- **Provider routing and recovery.** Direct providers accept a per-provider
  `base_url`. Known Ixway quota exhaustion stops automatic retries and keeps
  completed tool results for manual retry. Vertex OAuth and Application Default
  Credentials go through ReqLLM 1.31.0.
- **MCP.** The initial HTTP discovery request advertises the protocol version
  in its body and header. Bounded stdio diagnostics record framing and the
  request lifecycle.
- **Embedding.** `run_deadline_ms:` sets a wall-clock limit for one-shot runs.
  `Lemieux.Store.Memory` provides an owner-bound, byte-limited transcript
  store that supports resume.

See the [full changelog](https://github.com/houllette/lemieux/blob/v1.2.1/CHANGELOG.md).

## Update from 1.2.0

**Restart on every platform.** Session and TUI state, retained callbacks, and
runtime dependency changes require fresh initialization.

Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session. Personal config
version 1, extension API 1, existing transcripts and supported 1.x contracts
remain compatible. Consumed budgets remain attached to the resumed session.
See the [upgrade steps](https://github.com/houllette/lemieux/blob/v1.2.1/docs/releases.md#upgrading-from-120-to-121).

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
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.2.1/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.2"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.2.1/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.2.1/SECURITY.md#what-lmx-trusts-by-default).

Windows, browser automation, ACP draft v2 and experimental learning/benchmarking
APIs retain their experimental status. This release makes no claim of live
provider/model quality, hosted cache effectiveness or improved learning outcomes.
