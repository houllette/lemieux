# 1.0 release qualification

This packet separates offline contract tests, native archive qualification,
real model/transport observations and terminal inspection. A result qualifies
only its recorded source revision, runtime, archive, platform, model and account.
No result establishes comparative coding quality, learning efficacy or transfer.

[Registration](registration.json) freezes the paths, total 40-request / $10 API
ceiling and failure rules before live work. The aim is to spend less. Google is
excluded by the user; unavailable Anthropic credentials do not trigger a new
account or key. An already-running local Ollama server is eligible. No hosted
OAuth server is assumed from a configured MCP client.

Each path has a disjoint request/dollar allocation. Resume inherits the original
session's accounting. Additional scenarios must fit the registered reserve;
new invocations never erase consumed or unknown usage. Unknown pricing stops a
hosted path before dispatch. Local Ollama has no remote API charge; its economic
cost stays UNPRICED and its request cap still applies. Interrupted calls stay incomplete, even if a later check
passes. Cost derived from token tariffs is identified separately from an
account-side invoice or subscription quota.

## Recorded results

The native candidate and repaired live observations use source
`9f07379990748694e4223929937cac8f12b79517`.
The transport driver ran on `ee52dc4b0815998be10517beb70e5874c50eee57`; its
results keep that identity. A subsequent native check exposed a cancellation
accounting bug. The repaired source was qualified with a distinct registered
reserve job, without modifying or refunding the original history.

| Observation | Requests | Result |
| --- | ---: | --- |
| OpenAI API, `openai:gpt-6-sol` | 7 | Tool/edit/check, resume, structured output and running-shell cancellation passed |
| Codex subscription, `openai_codex:gpt-6.1-sol` | 7 | Same checks passed; subscription billing/quota not independently verified |
| Local Ollama, `qwen3.8:27b-mxfp8` | 8 | Same checks passed; economic cost remains UNPRICED |
| Original native TUI, OpenAI | 7 | Coding, UI controls and process cancellation passed; saved free-tool hold stayed active |
| Repaired native TUI, OpenAI | 7 | Coding, undo/redo, cancellation and continuation after restart passed; final active/debt counts zero |

[Accounting](accounting.json) records all 36 calls, including native auxiliary
requests. OpenAI API token-tariff accounting totals $0.182856; Codex list-tariff
accounting totals $0.023521. These are usage-based estimates, not an independently
verified invoice. No further live calls were made. Google was excluded;
Anthropic credentials and a configured hosted MCP OAuth account were unavailable.

The original [transport observations](transport-observations.json),
[native failure](native-before-repair.json),
[reserve registration](reserve-cancellation.json) and
[repaired native receipt](native-after-repair.json) retain that distinction.
The [local archive receipt](native-archive.json) and
[actual upgrade report](upgrade-report-macos-silicon-local.json) bind the local
Apple Silicon checks to the archive and restart-plan digests. The cross-platform
GitHub rehearsal is a separate result.
[Current PR checks](https://github.com/houllette/lemieux/pull/117/checks) cover the
final review head. The [release rehearsal](https://github.com/houllette/lemieux/actions/runs/41117747494)
builds source `9f07379`; subsequent test-synchronization, example-deadline and evidence commits do not
change the runtime or release-host code. Rebuilding for the final tag still
requires qualification of the exact final archives.

The [coding/cancellation recording](native-coding-cancellation.cast) and
[resume recording](native-resume.cast) are native OpenAI terminal runs with only
synthetic fixture content. Replay with an asciicast v2 player. They retain
original timing and are qualification recordings, not a polished promotional
video. Native pseudo-terminal cells were inspected; the computer-use tool refused
Ghostty access for safety reasons, so desktop visual inspection remains unrun.
The [announcement draft](announcement-draft.md) is prepared for publication after
the maintainer completes the signed release and installation checks.

[Offline observations](offline-observations.json) preserve the targeted results
and intermediate failures. Full local gate and exact-head CI outcomes are reported
in the pull request; an intermediate passing subset is not a full-gate claim.

## Candidate and archive gates

The candidate source prepares version 1.0.0 with a reviewed restart decision
from the signed, published 0.12.0 archives. The previous checksum list and update
manifest signatures are verified using the public key; no private release key
is needed. Each native archive needs its matching-host cold boot/tool/resume
report. A local Apple Silicon archive is a separate result from CI's Linux,
Intel, Apple Silicon and Windows archives. Windows remains experimental.

The release workflow's manual rehearsal builds and qualifies all four archives
without tagging, signing or publishing. Keep its complete-candidate inventory,
archive/plan/report digests and final outcome. An unsigned rehearsal is not a
published release. OS signing/notarization changes bytes and requires fresh
qualification.

## Real-path checks

Use a fresh workspace and private state directory. Read a small fixture, edit
only the intended file, run its unchanged check and verify the artifact outside
the model. Close and resume the recorded session. Inspect the tool results and
usage; an answer claiming success is insufficient. Check native Codex structured
output separately from OpenAI API text/tool streaming. Cancel actual running
work and verify its process ends. Retain failures and unrun paths explicitly.

In the installed binary, inspect the no-key provider panel, terminal startup and
restoration, multiline input, draft preservation, resizing, tool/task views,
undo/redo and restart/resume. Use synthetic fixture content only. Provider-free
scripted checks establish mechanics; they do not count as real provider trials.
A recorded demo must say which provider or scripted fixture it used.

MCP hosted consent/call/warm-restart/refresh requires an entitled configured
account and explicit host authorization. Local OAuth fixtures remain a separate
offline result when no such account is available.

## Publication boundary

Archive sanitized receipts with source/runtime/archive identities, observed
assertions, usage completeness and unresolved failures. Do not publish tokens,
transcripts, provider response headers, private paths or source captures. The
public announcement should demonstrate the coding workflow, request inspection,
embedding and extension seams. Learning remains experimental and issue #79 gates
claims of improved outcomes or economics. Signing, version tagging, package and
GitHub publication and the public announcement remain maintainer actions after
qualification.
