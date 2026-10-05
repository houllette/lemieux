# Harness-learning cross-system acceptance runbook

**Experimental.** May change in any 0.x release.

This is the acceptance procedure for a hosted harness-learning deployment:
Lemieux, an **orchestrating host** (a host application that embeds Lemieux
and governs experiments, activation and rollback) and Ixway analytics,
assembled as [Hosted harness learning](host-integration.md) describes. It
builds on:

- [The cross-system architecture](host-integration.md)
- [The Lemieux contracts](harness-learning.md)
- [The orchestrating host's adoption requirements](host-integration.md#orchestrating-host-adoption)
- [Ixway's adoption requirements](host-integration.md#ixway-analytics-adoption)

No assembled deployment has passed this procedure yet; it is open work in the
[roadmap](roadmap.md#hosted-integration-still-to-complete).

## Purpose

This is an acceptance procedure, not an implementation plan. Run it in full
after the host and Ixway adoption requirements and the entry gate below are
satisfied. The offline contract checks can be prepared earlier.

Its job is to prove that the assembled system has one meaning for every
object, preserves provenance and tenant boundaries across transfers,
separates discovery from confirmation, and activates only the version that
independent evidence justified.

A green CI run in each repository is necessary but insufficient. This runbook
looks for a **split**: any point where two systems accept different meanings,
ids, digests, scope, completeness, lifecycle state, cost, exposure, or active
version for the same logical event.

## What counts as a split

| Split class | Example |
| --- | --- |
| Contract | The host accepts a field/version that Ixway interprets differently, or one project silently drops a required field |
| Identity | The same run/finding/candidate maps to different tenant, project, parent, or correlation ids |
| Evidence | Lemieux records a tool failure or unknown cost while the host or Ixway records success or zero |
| Provenance | A finding, candidate, or activation cannot trace to exact immutable source digests |
| Exposure | Ixway or the host knows a finding derives from a case but the discovery archive or corpus history does not |
| Authority | A search worker, Ixway service, UI, or editable workflow can activate, evaluate secretly, or change a hard gate |
| Lifecycle | One system considers a job complete while another expects more attempts, or a retry creates duplicate work |
| Resolution | The host activates asset digest A but a new Lemieux run reports effective digest B |
| Accounting | Reserved, measured, committed, and Ixway-reported tokens/cost disagree without an explicit completeness reason |
| Monitoring | The host rolls back but Ixway continues attributing new runs to the reverted candidate, or historical runs are rewritten |

Any unexplained split fails acceptance even when the candidate itself performs
well.

## Acceptance owners

Name one person or accountable service owner for each role before scheduling:

- runbook commander;
- Lemieux evidence owner;
- host harness-engineering owner;
- Ixway provenance/analytics owner;
- host security/sandbox owner;
- corpus/evaluator owner;
- budget/provider owner; and
- release/rollback owner.

No owner may sign both proposer and evaluator evidence for the final proof.
The commander records decisions but cannot waive a hard failure.

## Environment and prerequisites

Use a staging environment isolated from production tenants and credentials,
but exercise the production code paths, durable queues, artifact store,
microVM service, evaluator image, and monitor/rollback transaction.

Record the following in a run manifest before any paid work:

- `runbook_id` and timestamp;
- exact Lemieux, host and Ixway commits/releases;
- every cross-system schema version and golden-fixture digest;
- ReqLLM/provider adapter and selected model versions;
- proposer model/configuration and frozen base model/configuration;
- host database migration and worker release;
- Ixway ingestion/derivation release;
- sandbox image, attestation issuer, evaluator, grader, and corpus versions;
- active control asset ids and effective harness digest;
- test tenant/project/account identities;
- development, validation, and encrypted holdout corpus digests;
- smoke/full and tenant/day budgets, per-attempt maximum, and expected upper
  bound; and
- artifact retention location and sign-off owners.

Required environment fixtures:

1. tenant A/project A, the target of the positive proof;
2. tenant B/project B, used only for cross-tenant denial tests;
3. a control environment-context asset;
4. development and validation cases where unnecessary environment exploration
   is measurable, plus counterexamples where added context should not help;
5. secret holdout cases that no analyzer, proposer, discovery worker, UI, or
   ordinary artifact identity has seen;
6. one mechanically failing baseline behavior that a safe context asset can
   plausibly improve;
7. one intentionally unsafe or critical-regression candidate fixture;
8. one canary fixture that trips the configured rollback threshold; and
9. deterministic golden events for every cross-system contract.

The environment-context asset is the first recommended proof because it tests
the complete loop without allowing arbitrary Lemieux source modification. The
host collects allowlisted facts; the candidate changes only their safe
selection/presentation.

## Entry gate

Do not begin live integration until:

- Lemieux `mix precommit` is green at the recorded commit;
- the complete host and Ixway CI/precommit/data-quality suites are green at
  their recorded commits;
- all three repositories accept the same golden fixtures and reject the same
  incompatible/tampered fixtures;
- database migrations and rollback plans have been rehearsed;
- the sandbox/evaluator threat model has completed its required review;
- the holdout owner attests that no source or derivation was exposed;
- projected worst-case spend is atomically reservable; and
- `:shadow` mode is enforced for discovery.

Modes belong to the host (requirement H5 in
[the adoption requirements](host-integration.md#orchestrating-host-adoption));
`Lemieux.Learning.Discovery.Plan` carries no mode field, and
`Discovery.Shadow.run/4` accepts only `mode: :shadow`. The local analogue is
that a `Discovery.Cycle` never writes the overlay and
`Lemieux.Learning.Overlay.export/3` refuses an unconfirmed candidate.

Archive all entry-gate reports under the `runbook_id`.

## Check 1: Offline contract conformance

Run the shared fixture suite independently in each repository, then reconcile
the outputs byte-for-byte or by their documented canonical digest.

Test at least:

- valid current and prior-compatible versions;
- unknown future required version;
- additive unknown optional field;
- missing required field;
- changed payload with unchanged digest;
- duplicate delivery id;
- same external id in tenant A and tenant B;
- unknown versus zero usage/cost;
- canceled/failed/timed-out terminal outcomes;
- nested finding source closure;
- candidate with invalid parent/content digest; and
- activation/rollback event versions.

Pass criteria:

- all systems agree on accept/reject/quarantine;
- canonical digests match;
- ignored additive fields survive the required round trip;
- tenant identity never participates in cross-tenant deduplication; and
- no system converts unknown/incomplete evidence to success, failure, or zero.

Store a conformance matrix with one row per fixture and one column per project.

## Check 2: Baseline Lemieux evidence

Through the host, start a fresh baseline Lemieux session for a development
case. Do not use a resumed motivating session. Capture:

- the host's run/session/attempt identity;
- active asset ids/digest resolved before launch;
- Lemieux effective harness snapshot;
- every request snapshot;
- transcript entries and tool outcomes;
- usage, cost, latency, stop reason, changed paths, and sandbox evidence; and
- the terminal `RunEvidence` manifest.

Reconcile immediately:

1. The asset ids/digest in the host's `RunSpec`, Lemieux's harness snapshot,
   every request/run correlation, and the host's attempt record are identical.
2. Request snapshots rebuild the same provider-neutral request semantics.
3. Artifact bytes match every stored digest and require tenant A authorization.
4. Telemetry contains correlations and numeric measurements but no prompt,
   path, tool argument/result, or credential content.
5. Failed/unknown facts remain explicitly incomplete throughout the host.

Repeat once with cancellation or timeout to prove terminal negative evidence
survives and is not classified as task success.

Pass artifact: a digest-verifiable baseline evidence chain from `RunSpec`
through transcript/artifacts to terminal `RunEvidence`.

## Check 3: Host projection and Ixway finding

Allow the host's outbox to deliver the authorized baseline projection to
Ixway. Temporarily interrupt delivery after the host's commit, restart the
worker, and deliver the same message twice.

Verify:

- one projection version and one Ixway ingestion receipt exist;
- the projection digest maps to the exact host evidence version;
- tenant/project, purpose, redaction, retention, completeness, event time, and
  artifact grants are unchanged;
- no holdout, grader, evaluator, promoter, credential, or unrelated content is
  present; and
- duplicate/restarted delivery creates no duplicate analytical source.

Run the versioned Ixway analysis that identifies unnecessary environment
exploration. It must emit structured observation, finding, and hypothesis
fields with sample/window, effect or descriptive metric, uncertainty,
comparability/data-quality limitations, derivation version, and transitive
source closure.

Publish the finding twice through the Ixway outbox. The host must create one
tenant-A opportunity whose origin records the Ixway finding; the original
finding snapshot and digest remain separate from any host interpretation.
Return an accepted/disposition receipt to Ixway and verify idempotency in
both directions.

Pass artifact: projection -> derivation -> finding -> opportunity -> receipt,
with complete forward and reverse source links.

## Check 4: Case curation and exposure closure

The case curator reviews the opportunity and freezes the development and
validation cases before optimizer authority opens. Record mechanical graders,
fixtures, versions, and case-review evidence. Confirm the current control
reproduces the motivating failure or documented intermittent condition.

Before releasing the Ixway finding or any derived artifact to discovery:

1. Ask Ixway and the host independently for its transitive source closure.
2. Require identical case/run/source ids and derivation digests.
3. Commit exposures for every source case and consumer role.
4. Attempt to assign an exposed source case to holdout; the transaction must
   fail and produce an audit event.
5. Verify the secret holdout digest/material remains unreadable to the curator
   after closure, Ixway, and every discovery identity.

Pass artifact: immutable case versions, matching source closures, committed
exposures, rejected contaminated-holdout assignment, and holdout-owner
attestation.

## Check 5: Shadow discovery

Create a `DiscoveryPlan` fixing the candidate interface, safe asset surface,
seed/control digests, proposer and base model/configuration, development and
validation corpus versions, objectives, hard safety constraints, interface
validator, concurrency, total budget, and stopping rule.

Materialize the discovery workspace and inspect it out of band:

- all authorized prior raw traces are present and digest-correct;
- Ixway findings are under the derived namespace and link to raw sources;
- no holdout, grader internals, evaluator/promoter identity, other tenant, or
  credential appears;
- history is read-only and only the proposal path is writable; and
- the recorded exposure set covers every direct and derived input.

Run enough iterations to produce multiple candidates, including an interface-
invalid or hard-invalid fixture. Interrupt the durable coordinator after a
proposal and again after a candidate evaluation; resume each time. A local
rehearsal of this step exists: `Lemieux.Learning.Discovery.Campaign.resume/1`
continues an interrupted campaign from its archive, and `Discovery.State`
records candidate and evaluation idempotency keys so a resumed search cannot
repeat a recorded evaluation.

Verify:

- proposer logs, candidate bytes/digests, parents, evaluations, costs, and
  exposure are complete;
- restart creates no duplicate proposal, evaluation, reservation, or spend;
- each evaluation uses a fresh root session/workspace/microVM;
- the base model/configuration and plan facts do not drift;
- invalid/unsafe/incomplete candidates do not enter the Pareto frontier;
- the total reservation is never exceeded and unknown cost prevents launch;
  and
- no API, worker, UI, or database path can activate the best candidate while
  mode is `:shadow`.

Pass artifact: complete discovery archive, deterministic frontier, accounting
reconciliation, and proof that active control is unchanged.

## Check 6: Independent confirmation

Select one frontier candidate through an authorized host command. Freeze its
bytes/digest and create a new preregistered `Lemieux.Experiment.Plan` with
control, metric, minimum effect, development/hidden sample, stopping rule, and
budget. Development/validation search results remain provenance and must not
populate confirmation fields.

Run fresh paired control/variant attempts in separate worktrees and microVMs.
The locked evaluator reads secret holdouts after terminal attempt artifacts are
immutable. Reconcile:

- repository/image/model/effort/tools/limits/cases are equal across arms;
- only the declared candidate digest differs;
- no attempt process holds evaluator, holdout, budget, registry, or promoter
  credentials;
- signed attestations bind plan, attempt, case, arm, scope, policy, artifacts,
  and terminal outcome; and
- the decision applies containment/safety, critical regression, held-out
  effect/uncertainty, then secondary efficiency in that order.

Before accepting the positive result, run negative confirmation fixtures:

- missing and forged attestation;
- changed candidate bytes under the old digest;
- missing attempt or grader output;
- unknown cost/usage;
- candidate attempt to change a grader or evaluator input;
- search result presented in place of hidden evidence; and
- Ixway confidence presented as a promotion result.

Every negative fixture must fail, abort, or become inconclusive. None may pass.

Pass artifact: signed paired confirmation evidence and one immutable passing
decision whose candidate exactly matches the discovery selection.

## Check 7: Reviewed activation and effective resolution

Move to `:review` only after confirming no `:shadow` job remains capable of
activation. Install the canary monitor and rollback target before requesting
activation. Have an authenticated human approve the eligible non-code asset.

Verify atomically:

- one immutable asset version exists with parent, candidate/discovery,
  opportunity/finding, experiment/decision, author, semantic diff, and rollback
  provenance;
- activation history and the active pointer move in one transaction;
- a concurrent stale activation loses its compare-and-set;
- an already-running historical session retains the old harness digest; and
- a fresh session resolves and reports the newly active asset and effective
  harness digest.

Run positive canaries, then inject the prepared regression canary. Restart the
monitor worker while the alert is outstanding. Verify one incident and one
atomic rollback restore the exact parent under retries. A new Lemieux session
must report the restored digest; historical candidate sessions remain linked
to the version they used.

Ixway may later publish a drift finding and must identify active versus rolled-
back/historical versions correctly. The host's hard rollback must complete
successfully with Ixway disabled.

Pass artifact: reviewed activation, effective-resolution proof, canary history,
incident, exact rollback, and post-rollback run evidence.

## Check 8: Security, tenancy, and authority fault matrix

Run all tests below even if equivalent unit tests exist:

| Injection | Required result |
| --- | --- |
| Tenant B projection references tenant A evidence | The host and Ixway reject it without revealing tenant A content |
| Tenant B artifact locator used with tenant A or no scope | Denied and audited |
| Ixway service calls candidate, asset, activation, or rollback path | No credential/API authority; denied |
| Discovery identity requests holdout or grader internals | Denied and audited before content release |
| Finding omits or changes source closure | Quarantined; no opportunity/discovery release |
| Experience bundle includes a holdout or cross-tenant artifact | Materialization rejected before proposer launch |
| Candidate writes history, evaluator, grader, or policy path | Sandbox violation; candidate hard-invalid |
| Search score supplied to activation | Type/policy rejection |
| UI or broadcast message attempts lifecycle advancement | No transition; authenticated host command required |
| Unknown price or insufficient tenant/day budget | Admission refused before provider/VM launch |
| Forged/missing/wrong-audience sandbox attestation | Evidence unusable; fail closed |
| Duplicate event/job/outbox/inbox delivery | Exactly one semantic result and no duplicated spend |
| Coordinator/service restart at every state boundary | Reconstructs state without repeating paid work |
| Ixway unavailable | Lemieux runs and the host's hard monitor/rollback continue |
| Host unavailable during Lemieux terminal event | Durable host/store recovery yields one terminal evidence record |
| Model/configuration changes during a frozen discovery/experiment | Rejected as plan drift |
| Tenant evidence attempts global activation | Permanently denied |

Retain denial audit ids and verify the attempted secret values did not enter
logs, telemetry, findings, broadcasts, or error messages.

## Check 9: Accounting reconciliation

For every run, candidate batch, confirmation arm, and Ixway analysis, reconcile:

- provider request counts and token usage;
- Lemieux normalized usage/cost and completeness;
- the host's reserved, committed, and released amounts;
- Ixway analytical totals and excluded/incomplete rows;
- VM/evaluator allowances; and
- total runbook maximum versus actual spend.

Exact dollar values may differ only where a documented provider price update,
rounding rule, or delayed finalization explains the difference. Record the
rule and raw usage. Missing evidence stays incomplete; it does not release a
conservative reservation as though cost were zero.

Pass criteria: all explainable deltas are within the predeclared tolerance,
and every unexplained identity/count/cost mismatch is zero.

## Check 10: Bidirectional lineage reconciliation

Build the lineage graph independently from each system's records, then compare
nodes and digests.

Forward path:

```text
RunSpec
  -> HarnessSnapshot / RunEvidence
  -> EvidenceProjection
  -> Ixway Finding
  -> Host Opportunity
  -> CaseVersions / Exposure
  -> DiscoveryPlan / Candidate / Frontier
  -> Experiment.Plan / signed Decision
  -> Asset.Version / Activation
  -> Canary / Incident / Rollback
  -> post-rollback HarnessSnapshot
```

Reverse path starts from the rollback/active asset and must recover every
exact parent, decision, candidate, discovery, opportunity, finding derivation,
projection, run, request, transcript entry, and artifact digest.

Required reconciliation:

- node ids, versions, scope, parents, and semantic digests match;
- every edge exists on both relevant sides or has one documented authoritative
  direction plus a delivery receipt;
- no orphan finding, opportunity, candidate, decision, activation, or incident
  exists;
- the active pointer and fresh Lemieux harness snapshot agree;
- exposure closure is a superset of every proposer/analyzer input and excludes
  holdouts; and
- historical records retain the versions that actually produced them.

Export the graph and machine-readable mismatch report into the evidence
package. Any mismatch fails the runbook.

## Evidence package

The final immutable package contains:

- run manifest and exact project/dependency/image/model versions;
- entry-gate CI, security, migration, corpus, and budget reports;
- contract conformance matrix and golden fixture digests;
- baseline and post-activation/post-rollback harness/run evidence;
- projection, finding, opportunity, case, exposure, discovery, candidate,
  confirmation, asset, activation, monitor, incident, and rollback records;
- proposer/evaluator logs and signed attestations;
- accounting reconciliation;
- negative/fault-matrix audit ids;
- bidirectional lineage graph and zero-mismatch report;
- known limitations and deferred non-gating observations; and
- signed approvals from every acceptance owner.

Store the package in the host's artifact authority under the test tenant and
a separate release evidence location according to retention policy. Secrets
and raw tenant content remain access-controlled; the sign-off summary contains
digests and outcomes rather than copying them.

## Failure and split procedure

When any phase finds a split:

1. Stop new discovery, confirmation, and activation admission for the affected
   contract/version. Do not delete existing evidence.
2. If an asset is active and safety, identity, provenance, or resolution is in
   doubt, use the host's tested rollback path.
3. Record a split incident with runbook id, phase, exact objects/versions,
   expected and observed semantics, scope, and artifact digests.
4. Determine the authoritative source from the architecture. Do not make both
   sides “agree” by weakening validation or copying the more convenient value.
5. Add the mismatch as a golden contract, unit, integration, and runbook
   regression fixture in every affected repository.
6. Fix the owning system, replay from the last immutable valid boundary, and
   prove idempotency. Never edit historical evidence in place.
7. Rerun the failed phase, every downstream phase, accounting reconciliation,
   and bidirectional lineage comparison.
8. If object meaning or authority changed, handle it as a
   [contract change](host-integration.md#changing-a-contract) before
   resuming: new wire versions; updated golden fixtures, architecture page,
   adoption requirements and runbook; and review by every acceptance owner
   whose system it touches.

Three consecutive attempts that fail at the same external dependency may be
reported blocked, but a semantic, security, evidence, or authority mismatch is
failed, not blocked or waived.

## Final definition of done

The combined system is accepted only when:

- every entry gate and phase passes at the recorded immutable versions;
- contract conformance has no unexplained difference across repositories;
- the positive environment-context scenario travels through evidence,
  finding, opportunity, discovery, independent confirmation, reviewed
  activation, monitoring, and exact rollback;
- all negative, cross-tenant, holdout, authority, forged-evidence, budget,
  drift, restart, and outage injections fail in the required direction;
- accounting reconciles and no paid work was duplicated;
- forward and reverse lineage produce zero mismatches;
- Ixway can be unavailable without preventing Lemieux execution or the host's
  hard rollback;
- the host's active pointer always matches the effective harness digest on a
  fresh Lemieux run;
- the immutable evidence package is complete and access-controlled; and
- all named owners sign without waiving a hard condition.

Automatic non-code promotion remains disabled after the first passing runbook.
Enable it only through a separate governance decision after repeated shadow
and reviewed cycles demonstrate representative cases, useful findings,
reliable confirmation, decisions reviewers can explain, and successful
rollback operations. Harness-code deployment remains human-owned permanently.
