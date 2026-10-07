# Roadmap

Lemieux is at 0.9. This page lists the work that is still open, so that a
contributor can see where help is useful and what "done" means for each item.
It is not a promise of dates. Before you begin a large change, start a
conversation in
[Discussions → Ideas](https://github.com/houllette/lemieux/discussions/categories/ideas),
as [Proposing larger changes](../CONTRIBUTING.md#proposing-larger-changes)
describes.

What already works is described in the guides and module documentation; this
page holds only what remains.

## Next

- **Platform-signed binaries.** Sign the macOS archives with an Apple
  Developer ID and notarize them, and sign the Windows archive. Today the
  macOS archives have to be installed with the install scripts rather than
  unpacked in Finder, and the Windows build is experimental. Releases
  themselves are already signed: the installer and `lmx`'s updater check an
  Ed25519 signature on the release checksums and update manifest.
- **Omarchy's agent selector.** Offer `lmx` to Omarchy upstream as a
  default agent: the `omarchy-agent` arm in
  [Desktop launchers and Omarchy](desktop.md#starting-lmx-from-a-launcher-or-an-agent-selector)
  and an entry in `omarchy-default-agent`, plus usage reporting for its agents
  widget. Done when `omarchy default agent lmx` works on a stock Omarchy
  install; `lmx` itself never patches Omarchy's files.
- **Provider coverage.** Record which provider and model paths have been run
  end to end for each release (V5 below), and add recipes for more ReqLLM
  providers.
- **Delegation.** Measure whether read-only investigators make the parent
  agent faster or more accurate before widening what they may do (V3).
- **Research tools.** Evaluate web research quality on tasks it has not
  seen (V6).
- **Harness learning.** Confirm that a learned harness overlay generalizes to
  new tasks and models before recommending regular self-improvement
  cycles (V9).

## Acceptance and experiments still to run

Each item needs new evidence. A previous run or a passing offline test does
not qualify another model, account, runtime or deployment.

| ID | What remains | What counts as done |
| --- | --- | --- |
| V1 | Independently confirm a revised recipe for the guided extension builder (`lmx --build-ext`). The current recipe was chosen on development cases and was never confirmed. | Freeze baseline, candidate, runtime, graders, fresh cases and budget before running; report both arms, failures, authoring cost, complete usage and exposure. See [confirmation](agent-extensions.md#confirmation-and-qualified-export). |
| V2 | Review feedback-to-case curation (`lmx feedback draft-case`, `lmx corpus promote`) over real use. | Review 20 consecutive items; approve at least half as mechanical or environmental cases; median curation time per approved case at most 30 minutes; every approved case detects an intentionally reintroduced regression. |
| V3 | Show that delegation helps on tasks that challenge a parent with iterative shell access, across served models. | Meet the correctness, latency, token, write-safety and fact-retention thresholds in [the delegation gate](subagents.md#evaluation-gate). |
| V4 | Complete an MCP OAuth flow against hosted servers: consent, an authorized call, a warm restart and a token refresh, with an account entitled to the server. | Discovery and client registration alone do not establish consent or tool access. Keep sanitized observations under the [MCP authorization contract](mcp.md#oauth-ownership-and-security). |
| V5 | Qualify each advertised provider/model path for a release. | Follow [provider validation](providers.md); label results by runtime, account and model, and unrun paths as unrun. |
| V6 | Establish web research quality beyond selected development questions. | Use unseen tasks, independent source-support review, repetitions and account-side cost. Passage presence and fetched-URL citations do not prove entailment or source quality. See [web tools](web-tools.md). |
| V7 | Run the assembled hosted-learning staging proof: Lemieux, an orchestrating host and Ixway analytics together. | Retain the evidence package [cross-system acceptance](acceptance.md) requires: restart, isolation, accounting and exact rollback. Separate repository CI is insufficient. |
| V8 | Keep the test suite fast and race-free as coverage grows. | Measure the current revision, platform and toolchain; fix bottlenecks and reproducible races without weakening assertions or masking failures with retries. |
| V9 | Confirm a learned harness candidate on fresh external tasks before recommending scheduled self-improvement cycles. | Keep the campaign archives and the cycle ledger. Confirm on unseen cases on every served model; cases the search inspected are development evidence. |

A provider listing a model in its catalog proves neither account entitlement
nor remaining subscription quota. Live work needs explicitly selected
provider, model and effort candidates and an explicit request or dollar
allowance.

## Hosted integration still to complete

A hosted deployment adds two systems to Lemieux
([Hosted harness learning](host-integration.md)):

- [Orchestrating host adoption](host-integration.md#orchestrating-host-adoption):
  authorized evidence, case authority, isolated discovery and confirmation,
  one registry, monitored activation and rollback. This work belongs to
  whichever host application adopts the contract.
- [Ixway analytics adoption](host-integration.md#ixway-analytics-adoption):
  versioned projections, advisory findings, provenance, exposure closure,
  evidence quality and disposition delivery. This is separate from
  [Ixway inference routing](ixway.md), which ships.

Verify observation first, independent fitness second, shadow discovery third,
and reviewed activation after rollback works. The
[runbook](acceptance.md) defines acceptance. `Lemieux.Feedback.Flow`,
`Lemieux.Experiment.State` and `Lemieux.Experiment.CodeGate` are the
host-facing contracts. Without a host, activation remains a reviewed overlay
file (`.lmx/harness.json` or `~/.lmx/harness.json`).

## Conditional follow-ups

These proposals wait on evidence and have no scheduled implementation:

- Broader prompt optimization, asset consolidation and discovery edit surfaces
  wait on independent confirmation and reviewed feedback cases. Preserve
  regression coverage and provenance.
- Specialist scouts, clean-context verifiers and broader delegation topologies
  wait on V3. Local coordination and mutation reservations belong to an
  explicitly selected host; the library starts no coordination daemon.
- Structured compaction sections remain opt-in until a paired workload
  demonstrates better obligation retention without unacceptable overhead.
- Remote receipt reconciliation, hermetic builds, subscription remaining/reset
  displays and automatic activation require a host with the relevant service,
  data or isolation. Code release remains human-owned.

## Not planned

- A web framework or database dependency in the core library.
- Hand-written provider adapters: providers belong in ReqLLM.
- An application callback that starts Lemieux on its own: hosts mount
  `Lemieux.Supervisor` themselves.

## Maintaining this index

Give new work an owner and an observable completion test. On completion,
remove its entry and update the owning guide with supported behavior and limits.
Keep reports in ignored `tmp/` directories or a host-owned artifact store.
Recover old plans with `git log -- docs/PATH.md` and
`git show COMMIT:docs/PATH.md`; do not add a parallel history index.
