# Hosted harness learning

**Experimental.** May change in any 0.x release.

**Harness learning** improves the harness a session runs with (its
instructions, tool descriptions and other durable assets) from evidence of how
sessions went, without retraining a model. On one machine, Lemieux runs the
whole loop itself ([Harness-learning contracts](harness-learning.md)). A
hosted deployment splits the work three ways:

- **Lemieux** executes sessions and records what happened.
- **Ixway** analyzes evidence it is authorized to see and reports findings.
- An **orchestrating host**, a host application that embeds Lemieux and owns
  tenants, storage, durable jobs and releases, governs experiments,
  activation and rollback.

This page is the ownership contract between the three and what each must
provide. [Cross-system acceptance](acceptance.md) is the procedure that proves
an assembled deployment works. No assembled deployment has passed it yet; it
is open work in the [roadmap](roadmap.md#hosted-integration-still-to-complete).
Ixway's analytics role here is separate from its
[inference routing](ixway.md).

## The three planes

| Plane | System | Semantic authority | It must not own |
| --- | --- | --- | --- |
| Execution and evidence | Lemieux | Agent-loop semantics, effective request and harness snapshots, transcripts, tool and hook outcomes, normalized usage, candidate execution, host-neutral benchmark and discovery contracts | Tenant identity, databases, durable jobs, hidden-case secrets, analytical conclusions, promotion, production deployment |
| Observation and inference | Ixway | Model-usage analysis, attribution, quality and failure patterns, feedback derivation, opportunity detection, confidence and data-quality reporting | Harness mutation, grader or holdout policy, activation, rollback, or rewriting source evidence |
| Governance and actuation | Orchestrating host | Authenticated scope, harness engineering, durable orchestration, case and corpus authority, isolation, budgets, confirmation, promotion, monitoring, and rollback | Reimplementing the Lemieux loop or duplicating Ixway's analytical pipelines |

Lemieux contains an OTP control plane for one runtime, but the orchestrating
host remains the deployment's governance and actuation plane. Ixway may
operate its own analytical jobs, but their outputs are advisory until the
host turns one into a governed opportunity.

The Ixway in this table is the observation and analytics plane. It is not
`Lemieux.Ixway`, which is an inference-routing policy: with `--ixway`, a
session's model calls go through an Ixway gateway, as
[Ixway inference integration](ixway.md) describes. No client for the
observation plane exists in this library.

## One closed loop, with typed boundaries

```text
                         frozen RunSpec
                   Host -----------------> Lemieux
                    ^                          |
                    |       RunEvidence        |
                    +--------------------------+
                    |
                    | authorized EvidenceProjection
                    v
                  Ixway
                    |
                    | Finding: provenance + uncertainty,
                    | never mutation authority
                    v
             Opportunity (host record)
                    |
                    v
      case curation -> discovery -> frozen candidate
                    |                    |
                    |                    v
                    +----------> confirmation experiment
                                         |
                                         v
                          activation -> canary -> rollback
```

Every arrow changes the type and authority of the object crossing it. A
receiver never silently upgrades an input into a more authoritative type.

### Core objects

| Object | Meaning | Source of truth |
| --- | --- | --- |
| `RunSpec` | Frozen input to one Lemieux run: effective asset digests, model/configuration, tools, limits, opaque scope and correlation ids, and host capabilities | The orchestrating host for hosted runs; the standalone host locally |
| `RunEvidence` | Provider-neutral facts emitted by Lemieux: harness/request snapshots, transcript and artifact references, tool outcomes, usage, stop reason, and runtime versions | Lemieux semantics, persisted and authorized by the host |
| `EvidenceProjection` | A purpose-limited, versioned, tenant-scoped projection suitable for Ixway; high-cardinality artifacts remain behind authorized references | The host |
| `Finding` | An Ixway observation or inference with source references, derivation version, scope, sample/window, uncertainty, data quality, and transitive exposure | Ixway |
| `Opportunity` | A host record saying evidence deserves governed investigation; it may originate from human feedback, an Ixway finding, a benchmark failure, or an operator hypothesis | The host |
| `CaseVersion` | An immutable, independently curated, mechanically or environmentally verifiable evaluation case | The host's case authority, using Lemieux's portable shape |
| `DiscoveryPlan` | An exploratory search contract fixing the mutable surface, exposed corpus, proposer, objectives, safety constraints, interface checks, and total budget | A host record using Lemieux's portable shape |
| `Candidate` | Immutable candidate lineage and content/patch digest plus development/validation evidence; never an active asset | Lemieux discovery semantics, persisted by the host |
| `Experiment.Plan` | A preregistered confirmatory comparison of one frozen candidate with the active control | The Lemieux contract, persisted by the host |
| `Experiment.Decision` | Locked, safety-first result over independent confirmation evidence | Lemieux decision semantics, applied by the host's locked evaluator path |
| `Asset.Version` | Immutable durable harness content with parent, provenance, digest, and rollback target | Lemieux shape; the host's registry or the project's Git is the hosted authority |
| `Activation` | Atomic movement of the active pointer to a confirmed asset version | The host |

## Non-negotiable distinctions

These are architecture constraints, not naming preferences:

1. **Fact is not inference.** Lemieux records what happened. Ixway may infer
   why it happened, but the finding retains links to the original facts.
2. **Derived feedback is not human feedback.** Raw human prose remains an
   immutable `Lemieux.Feedback` record. Ixway emits a `Finding`; the host may
   relate both to one `Opportunity` without overwriting either.
3. **Opportunity is not a case.** A separate curator must turn an opportunity
   into a versioned case before it can provide decisive evidence.
4. **Search is not confirmation.** Discovery is allowed to inspect exposed
   history, make broad changes, regress, and revise its hypotheses.
   `Lemieux.Experiment.Plan` remains immutable and preregistered.
5. **Candidate is not active.** Search workers and Ixway possess no activation
   capability. A search score can never satisfy the promotion contract.
6. **Telemetry is not the audit log.** Metrics carry opaque correlation ids;
   exact prompts, traces, diffs, decisions, and attestations live in
   access-controlled durable evidence.
7. **Session adaptation is not durable learning.** A model may change strategy
   within a transcript. Durable learning occurs only when the host activates
   an immutable, independently confirmed asset version.
8. **One active harness exists.** Human edits, Ixway-motivated proposals, and
   discovered candidates all converge on the same `Asset.Version` and
   activation mechanism. There is no second mutable learned-memory plane.

## Discovery workspace

Keep the proposer separate from candidate evaluation. Give it read-only access
to authorized candidate code, scores and traces and one isolated writable
proposal destination. Preserve an append-only archive, lineage, interface
validation and explicit search budgets. Final evaluation remains hidden.

`Lemieux.Learning.Proposer.Workspace` materializes this layout locally from
campaign evidence. For hosted runs, the host supplies the tenant-scoped
workspace and isolated candidate destination. Ixway findings supplement source
evidence; they do not grant database access or expose another tenant's
history.

## Evidence, privacy, and exposure

The orchestrating host is the authorization gateway between Lemieux evidence
and Ixway. A direct Lemieux-to-Ixway product dependency would violate the
database-free, host-neutral core and bypass the host's tenant and retention
policy. `Lemieux.Ixway` does not change this. With `--ixway` the gateway sees
every prompt of a routed session because it serves the inference, and that is
a routing choice the person made. It is not an evidence transfer, and the host
remains the authorization gateway for evidence.

An `EvidenceProjection` contains the minimum content required for its declared
Ixway analysis. Full prompts, paths, patches, grader output, credentials, and
transcripts remain in the host's artifact authority unless a short-lived grant
explicitly permits their use. Ixway may retain allowed projections and
derived data according to the tenant's policy; possession of an artifact
locator is never authorization.

Exposure is transitive. If a finding derives from cases A, B, and C and a
proposer sees that finding, the discovery has indirectly seen A, B, and C.
The host records those cases as exposed before materializing the finding.
They cannot later be assigned to a hidden holdout. Derived summaries do not
launder development evidence into secret evidence.

Tenant evidence, cases, findings, candidate archives, caches, and assets do
not cross tenants. Cross-tenant operational aggregates, if separately
permitted, may motivate human investigation but cannot directly justify a
tenant or global harness activation. Global changes require a separately
governed corpus and human release authority.

## Authority and capability model

The roles are separate even when early development runs them in one service:

| Role | May read | May write | Never receives |
| --- | --- | --- | --- |
| Evidence exporter | Authorized run facts and artifact metadata | Versioned `EvidenceProjection` | Promoter credentials |
| Ixway analyzer | Authorized projections and explicitly granted artifacts | Findings and derivation audit | Harness registry writes, holdouts |
| Case curator | Opportunity and source evidence | Immutable development/validation/holdout cases before closure | Candidate writes after the case is frozen |
| Discovery proposer | Seeds, exposed raw traces, Ixway findings, development/validation results | Candidate destination and proposer transcript | Holdout content, grader internals, evaluator or promoter credentials |
| Discovery evaluator | Candidate, exposed cases, fixed grader interface | Development/validation observations | Promotion authority |
| Confirmation evaluator | Frozen plan, attempt artifacts, secret holdouts | Signed confirmation result | Candidate mutation or activation authority |
| Promoter | Signed decision, policy facts, rollback and monitor readiness | Atomic activation/rollback | Mutable evaluator inputs |

Hard separation must be enforced with service identities, scoped artifact
grants, distinct microVMs/worktrees, and state-transition guards. Prompt
instructions are not a capability boundary.

## First vertical proof

The first cross-system proof should optimize a bounded environment-context
asset rather than Lemieux source. The host collects an allowlisted sandbox
snapshot; the candidate controls which safe facts to present and how to format
them. Lemieux executes baseline and candidate sessions. Ixway measures early
exploration turns, tool calls, task success, context tokens, cost, and task
family. The host alone curates the cases, runs discovery, confirms the
selected candidate, and activates or rolls it back.

This scenario exercises raw traces, derived findings, discovery, independent
confirmation, cost accounting, and activation without granting arbitrary code
or shell policy to the proposer.

## Architecture definition of done

This architecture is implemented only when all of the following are true:

- every cross-system object has one versioned owner, and golden compatibility
  fixtures pass in Lemieux, the host and Ixway;
- one production run can be traced from active asset digests through Lemieux
  evidence, host storage, an Ixway finding, a host opportunity, discovery,
  confirmation, activation, and canary outcome;
- the reverse trace from an activation to every motivating raw fact is also
  complete and digest-verifiable;
- holdout material and its derived information never enter discovery;
- cross-tenant reads, projections, findings, candidates, and activations are
  denied and audited;
- a search score, Ixway confidence, missing evidence, invalid attestation, or
  unknown cost can never cause activation;
- restarting any coordinator does not duplicate spend, evaluation, finding,
  opportunity, or activation;
- one intentional canary regression atomically restores the exact previous
  version; and
- the complete procedure in the
  [acceptance runbook](acceptance.md) passes with a retained evidence package
  and signed approvals from every
  [acceptance owner](acceptance.md#acceptance-owners).

## Changing a contract

A change inside one system's implementation needs only that system's own
review. A change to what an object means or who may act on it (an ownership
boundary, an authority transfer, a tenant or holdout rule, a promotion
precondition) is a contract change. A contract change:

- gets a new wire version for every object whose meaning changed (the
  [contract inventory](harness-learning.md#contract-inventory) lists
  Lemieux's current versions);
- updates the shared golden fixtures (Lemieux's is
  [`contracts.json`](https://github.com/houllette/lemieux/blob/main/test/fixtures/harness_learning/contracts.json)),
  this page, the affected requirements below and the
  [acceptance runbook](acceptance.md) together;
- is called out in the changelog of every system it changes; and
- reaches a host or Ixway only after the new golden fixtures pass there.

## Orchestrating host adoption

What an orchestrating host has to guarantee, in the order to build it. Each
ends with the checks that show it is done.

### H1: Authorized evidence and opportunity boundary

Map hosted session and run identity to digest-verified
`Lemieux.Harness.Snapshot` and `Lemieux.Evidence.Run` records. Preserve
effective asset ids, request/run/candidate/experiment correlations and
explicit missing usage, cost, artifact and sandbox facts.

Build an authorized, purpose-limited `EvidenceProjection` outbox and a
versioned Ixway `Finding` inbox. Validate scope, service identity, versions,
digests, source closure and delivery identity before accepting a finding.
Ixway outages must delay delivery without blocking ordinary runs.

Map human feedback, findings, benchmark failures, operator hypotheses and
discovery regressions into one opportunity lifecycle. Preserve immutable
origin and revisions; a finding never overwrites raw feedback or grants
experiment authority.

Acceptance: out-of-order/duplicate delivery is idempotent; projections appear
only after source commit; cross-scope, unresolved and tampered sources fail;
terminal dispositions return to Ixway without sensitive content. Both
interactive and headless launches report the effective harness.

### H2: Artifact, case and exposure authority

Provide tenant-scoped artifact access with digest, size, media/schema version,
retention class and reauthorized expiring grants. A locator is not permission.
Retain evidence referenced by active decisions and monitors; corrections append
versions rather than rewriting history.

Anchor human feedback to an authorized transcript entry, and keep it separate
from other reports, such as bug reports. Route subjective or unsupported
claims to review instead of inventing an automatic grader.

Freeze independent case/fixture/grader versions before opening optimizer
write authority. Keep development, validation and secret holdout custody
separate. Commit direct and derived source-case exposure before materializing
any bundle; summaries and nested findings expose their transitive sources.

Acceptance: curator authority closes before proposal; cross-tenant artifacts
and cases cannot enter a bundle; optimizer/analyzer cannot change approved
cases or read holdouts; exposure closure is deterministic and cycle-safe;
exposed cases cannot later be relabeled hidden. Apply the 20-item curation
test in the [roadmap](roadmap.md#acceptance-and-experiments-still-to-run) (V2).

### H3: Durable isolated confirmation before discovery

Run confirmation with frozen `Lemieux.Experiment.Plan` semantics.
`Lemieux.Learning.Discovery.Confirm` is the local reference behavior to wrap:
holdout on clusters the search never saw, a single-use confirmation directory
whose exposure marker is written before the first session starts, and the
`e_process` stopping rule by default. Every transition and audit event must
commit atomically; paid retries need explicit attempt identity, not
supervisor restart. Reserve worst-case batches against experiment and
tenant/day allowances before launch. Account for proposer, candidate, grader
and failed/interrupted work. Unknown dollar cost cannot authorize a
cost-qualified promotion.

Run paired fresh root sessions from identical pinned repository/image inputs,
with only the declared candidate differing. Supply separate workspaces and a
real host-owned microVM boundary where containment is claimed. Validate signed,
unexpired, plan/audience-bound attestations. Destroy leases on every terminal
path. Worktrees and ordinary containers do not prove that boundary.

A locked evaluator identity owns hidden cases, graders and signed results.
Safety failures and critical regressions veto quality/cost gains. Missing
attempts or evidence produces abort/inconclusive, not pass.

Acceptance: restart at each boundary cannot duplicate spend; candidates cannot
read evaluator/promoter/budget credentials or modify graders; wrong or missing
attestations fail; development results and Ixway confidence cannot populate
confirmation fields. Record real provisioning/cancellation/destruction evidence,
not only mocked adapter success.

### H4: Shadow discovery using existing Lemieux contracts

Persist `Lemieux.Learning.Discovery.Plan` and immutable candidate/evaluation
lineage using host records. Freeze the allowed mutation surface, source seeds,
proposer/base-model settings, exposed corpus, interface validator, objectives,
constraints, concurrency and total candidate/token/cost/time allowance.

Materialize authorized raw traces and separately labeled findings as read-only
history with one writable proposal destination. Proposer/evaluator sessions
are fresh and isolated. Retain proposer calls, candidate bytes, interface
failures, observations and all resource usage. Invalid candidates cannot enter
the frontier. Shadow mode has no activation command, route or worker path.

Reference implementations in Lemieux: `Lemieux.Learning.Discovery.Campaign`,
whose `resume/1` refuses a configuration that names a different manifest or
evolver profile than the persisted plan; `Discovery.State` budgets, where a
missing fact marks the budget unknown and stops the search (a plan with
`"unknown_cost": "allow"` lets a missing cost through as a lower bound,
for quota-billed providers); the
`Discovery.Surface` validator; and `Lemieux.Learning.Proposer.Workspace`.
`lmx harness export` is a human-only command; the host must not expose it, or
an equivalent, to search workers.

Acceptance: replay does not repeat a recorded proposal/evaluation; candidate
inputs cannot drift; hidden/other-tenant data is refused before launch;
selection freezes exact bytes into ordinary confirmation. A search score
cannot activate anything.

### H5: One registry, monitored activation and usable decisions

Integrate human-authored and discovered changes with one immutable registry
and resolution path. Project assets remain Git-owned; hosted pointer changes
use authenticated compare-and-set commands and append-only history. Do not
create a second mutable learned-memory store.

Keep the provenance chain opportunity → case → discovery → confirmation →
activation inspectable, with exposed results kept apart from hidden
confirmation, and with uncertainty, safety, resource completeness, versions,
monitor and rollback target recorded. Only authenticated commands change
lifecycle state: no view, broadcast or disconnected client can advance or
repeat paid work. Sensitive content is fetched under authorization, not
broadcast.

Enable modes in order: capture, shadow, then reviewed activation. Before
reviewed activation, install a versioned monitor and exact prior-version
rollback. Current and future sessions must report the correct historical or
new effective digest. Ixway must not sit in the rollback critical path.

Acceptance: concurrent activations have one winner; a deliberate canary
regression creates one incident and restores the exact parent across retries;
shadow mode cannot activate; what reviewers are shown agrees with policy and
keeps a finding, a search score, a confirmed result and the active version
distinct. Capture mode cannot launch a paid campaign.

### H6: Conditional autonomy and code lane

After the full runbook and a rollback drill, consider policy-controlled
automatic activation only for mechanically verifiable project/tenant
non-code assets. Global, subjective, safety, evaluator, grader,
credential, budget and policy changes remain human-governed.

Harness-source candidates use isolated worktrees/microVMs, normal precommit/CI,
compatibility, security, supply-chain, performance, live evaluation and canary
evidence. A passing `Lemieux.Experiment.CodeGate` creates a normal human-owned
release proposal. It does not authorize deployment or live-node loading.

### Order and completion

Build H1 → H2 → H3 → H4 → H5; H6 is conditional. Experiments run inside the
same launch, environment and tool-policy boundaries as the host's ordinary
sessions, narrowed for the experiment, rather than in a second runtime.

Complete shared fixture mappings, projection/finding/receipt/disposition and
artifact-grant examples, exposure receipts and the environment-context staging
scenario. Retain test and live evidence from the
[acceptance runbook](acceptance.md). Host-local completion alone does not
establish the assembled deployment.

## Ixway analytics adoption

### I1: Versioned projection ingestion and provenance

Complete consumption of host-authorized `EvidenceProjection` objects with
schema/version, semantic digest, source ids/digests, scope, analytical purpose,
service identity, grant expiry, retention/redaction and completeness fields.
Opaque Lemieux ids cannot establish tenant authority. Record event time
separately from arrival time.

Preserve immutable projection revisions and derivation source closure. Link
queries, code/model/prompt versions and authorized artifact versions to every
derived value. Quarantine incompatible or tampered input visibly; preserve
allowed additive fields. Unknown usage, price or outcome remains unknown.

Acceptance: duplicate/out-of-order deliveries converge; equal external ids in
different tenants do not join; expired grants and invalid identities cannot
partially enter analysis; superseded/deleted sources invalidate current views
without rewriting historical findings; nested provenance closure terminates
and returns all authorized sources.

### I2: Advisory findings with quality and comparability

Adapt existing metrics/insights to a canonical versioned `Finding` envelope:
id/revision, scope/purpose, claim class, structured metric and sample/window,
baseline, effect/uncertainty, source closure, derivation versions, quality and
missingness, limitations, suggested next investigation and signed digest.

Keep observations, inferences and hypotheses explicit. Deterministic counts,
source ids and quality flags cannot be rewritten by generated narrative.
Feedback themes retain the original human feedback id/revision; they never
replace raw prose or turn taste into a mechanically verified claim.

Compare task family, model/configuration/harness version, outcome authority,
repeated-case dependence, censoring and freshness before recommending a
model/configuration experiment. Pre/post comparisons remain observational;
only the host's signed confirmation is a confirmatory verdict. Cost or
latency cannot compensate for safety or critical regressions.

Acceptance: each value is reproducible from immutable versions; a narrative
cannot claim stronger evidence than its structured fields; repeated attempts
do not inflate independent samples; incompatible labels are not pooled;
synthetic confounding and unavailable artifacts reduce confidence visibly;
feedback derivation revisions coexist without crossing tenant boundaries.

### I3: Finding delivery, disposition and discovery export

Complete durable finding outbox delivery and idempotent host receipts.
Retain dispositions through opportunity/case review, discovery, confirmation,
activation and rollback. Measure finding precision, calibration and time to
useful action without confusing a rejected finding with a failed candidate.
Analytical improvements still use ordinary reviewed/versioned development.

Export exact authorized finding revisions and derived artifacts for discovery
with digest-verifiable transitive source closure. The host commits exposure
before releasing them. Summaries must not erase authorized raw evidence
references or smuggle hidden source cases into the proposer context.

Acceptance: retry does not duplicate opportunities; expired grants prevent
export; exported closure matches the host's independent closure; findings and
receipts carry no executable activation command or additional authority;
raw evidence remains traceable when optional summaries are removed.

### I4: Advisory monitoring

Link delayed events, drift and failure clusters to activation/canary identity
and historical harness digests. Distinguish active, rolled-back and prior
versions without rewriting the host's incidents. Ixway can recommend
investigation; the host's safety monitor and rollback must work during an
Ixway outage.

Acceptance: late evidence creates a revised finding, not a new historical
activation; neither alerts nor suggestions can invoke registry mutation or
rollback. Tenant-scoped data must not train or justify another tenant's assets.

### Delivery order and completion

I1 → I2 → I3 → I4. Agree projection/finding/receipt/grant/disposition fixtures,
metric definitions, derivation identifiers and compatibility ownership with
the host. Supply the environment-context finding for the shared runbook. Check
both provenance directions and all data-quality/security negative cases.

This is the observation plane: no direct Lemieux store/session connection,
hidden holdout access, candidate/grader writes, registry credentials or
promotion authority. I1 through I4 concern Ixway's analytics role. That role
is distinct from the inference-gateway role in
[Ixway inference integration](ixway.md), which `Lemieux.Ixway` implements
and which routes a session's model calls without carrying evidence. See
[Orchestrating host adoption](#orchestrating-host-adoption) for the
corresponding governance work.
