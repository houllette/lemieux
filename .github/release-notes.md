# Lemieux 1.1.0

Lemieux 1.1 improves the `lmx` terminal workflow, provider account visibility
and MCP setup while retaining the supported 1.x library, CLI and extension
contracts. The terminal app and embedding hosts still use the same runtime;
model inference remains in ReqLLM.

## What changed

- **Codex account discovery.** Use an existing local Codex sign-in and choose
  from the active account's visible models, including new IDs missing from
  bundled metadata. Discovery runs in the background, invalidates changed
  accounts and preserves model/effort preferences. Explicit ReqLLM auth takes
  precedence; Codex keeps refresh ownership.
- **Provider account usage.** `/usage [refresh]` shows supported metered spend
  and subscription windows. Reporting is asynchronous and cached; missing
  permissions, unknown limits and stale values remain explicit. It makes no
  inference request and does not replace session or configured-budget accounting.
- **Optional questions without a full stop.** The agent may defer an optional
  `ask_user` answer while continuing independent work. Blocking remains the
  default, answers are delivered once, and unanswered questions never grant
  approval. Idle answers wait for the next explicit prompt.
- **Readable diagnostics and reviewed bug reports.** Budget refusals explain
  amounts and next steps while retaining exact saved diagnostics. Internal
  faults show a reporting hint and turn summary. `/feedback bug` prepares a
  sanitized draft; `/feedback bug submit` explicitly submits the reviewed
  report through an authenticated GitHub CLI. Ordinary feedback remains.
- **MCP from the terminal.** Add local/global HTTP or stdio servers with
  `lmx mcp add`, complete interactive OAuth, and inspect cached tools and
  schemas in `/mcp`. Discovery survives client/browser exits, and default
  stdio diagnostics use a bounded separate pipe.
- **Everyday UI and configuration fixes.** Copy question-panel text, read
  wrapped options, place the editing cursor with a click, discover local MTPLX
  models and see token throughput. Supported System One config changes reload
  at idle boundaries; other settings still require restart.
- **Updated dependencies.** ReqLLM 1.30.0, LLMDB 2026.11.2, ExRatatui 0.20.0
  and JSV 0.27.0, with the patched validator in both dependency graphs.

The [changelog](https://github.com/houllette/lemieux/blob/v1.1.0/CHANGELOG.md)
has the detailed changes and migration notes.

## Update from 1.0

**Restart on every platform. No hot update or live downgrade is declared.**
Save unsent drafts, stage the signed update with `lmx update` or `/update`,
then restart and resume with `lmx -c` or `lmx --resume SESSION`. The explicit
installer-managed TUI restart preserves its exact session; automatic restart
is limited to a pristine idle screen.

Personal config version 1, `openai_codex:MODEL` names, provider model/effort
preferences and extension API 1 remain compatible. Keep an explicit ReqLLM
OAuth override when it is the credential source you intend to use. Check
`lmx extension list` after updating and rebuild only extensions the loader
refuses. Resume keeps consumed budgets and uses current host authorization.
See [upgrade steps](https://github.com/houllette/lemieux/blob/v1.1.0/docs/releases.md#upgrading-from-10-to-11).

Default stdio MCP launchers need Bash for the separate diagnostic pipe
(Git Bash on Windows). Custom launchers retain their host's diagnostic policy.

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
[Verification and installation details](https://github.com/houllette/lemieux/blob/v1.1.0/docs/releases.md)
explain the signature/checksum chain and platform limits.

For an embedding application, use `{:lemieux, "~> 1.1"}`. The library requires
Elixir 1.19 or newer and OTP 27 or newer, starts no Lemieux processes on its
own, and retains explicit host ownership of credentials, storage and policy.
Update constrained provider-stack locks together; start with
[First embedded agent](https://hexdocs.pm/lemieux/1.1.0/first-embedded-agent.html).

## Trust and experimental scope

`auto` remains the default: workspace edits run automatically; commands do so
only inside an available OS sandbox, otherwise they ask. MCP, web and eval
tools ask either way. Instructions, skills and optional answers grant no new
authority. The installed binary never loads a working directory's `.env`.
See [the trust model](https://github.com/houllette/lemieux/blob/v1.1.0/SECURITY.md#what-lmx-trusts-by-default).

Experimental learning gains stricter execution bindings, reviewed asset-use
checks, provider-free planning and export dependency closure. These changes
do not establish independent efficacy, better task outcomes or lower cost,
and do not enable new asset kinds for automatic persistent selection. Capture
and recall add no inference requests; isolated refinement still needs its
existing finite allowance and prerequisites. See
[learning qualification](https://github.com/houllette/lemieux/blob/v1.1.0/docs/learning-qualification.md).

Windows, browser automation and the experimental learning/benchmarking APIs
retain their existing status. The broader transcript-spacing, todo-subtask,
snippet-copying and pointer-feedback proposals remain future work.
