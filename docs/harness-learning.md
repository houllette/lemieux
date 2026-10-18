# Harness-learning contracts

**Experimental.** May change in any 0.x release.

**Harness learning** improves the harness a session runs with (its
instructions, tool descriptions and other durable assets) from evidence of how
sessions went, without retraining a model. This guide covers the contracts
Lemieux implements for it: for a standalone host, `lmx` or your application on
one machine, and for an **orchestrating host**, a host application that
embeds Lemieux and runs the hosted loop that
[Hosted harness learning](host-integration.md) describes. `lmx help learning`
lists the command-line side, and the [roadmap](roadmap.md) tracks open
acceptance and integration.

The boundary remains deliberately narrow:

> Lemieux records effective behavior and executes bounded candidates. The
> orchestrating host authorizes, persists, schedules, confirms, and
> activates. Ixway derives findings from a projection the host authorized.

There is no Ixway client, database, web endpoint, tenant policy, durable job
coordinator, microVM implementation, or hosted or automatic activation path
in these modules. The only local activation is a reviewed overlay file that
`lmx harness export` writes and a person commits; see
[The active overlay](#the-active-overlay).

## Contract inventory

| Contract | Wire version | Integrity field | Meaning |
| --- | ---: | --- | --- |
| `Lemieux.Harness.Snapshot` | 1 | `semantic_sha256`, `manifest_sha256` | Effective behavior for a request, plus audit correlations |
| `Lemieux.RequestSnapshot` | 1 | `sha256` | Exact provider-neutral input to one model request |
| `Lemieux.Evidence.ArtifactReference` | 1 | `sha256` | Typed content reference verified against supplied bytes |
| `Lemieux.Evidence.Run` | 1 | `sha256` | One terminal prompt-level observation and artifact index |
| `Lemieux.Benchmark.Corpus.Exposure` | 2 | `sha256` | Direct and derived case exposure with transitive source ids |
| `Lemieux.Learning.Experience.Bundle` | 1 | `sha256` | Authorized, single-scope discovery history |
| `Lemieux.Learning.Experience.Lesson` | 1 | `id`, `sha256` | Scoped lesson with complete source bytes and exposure ancestry |
| `Lemieux.Learning.Discovery.Plan` | 1 | `sha256` | Frozen proposer-visible search contract and total budget |
| `Candidate`, `Evaluation`, `Frontier`, `State` | 1 | `sha256` | Immutable search archive and restart projection |
| `Lemieux.Experiment.Plan` | 1 | `sha256` | Ordinary preregistered one-factor confirmation plan |

Every wire object is a string-keyed JSON object. `Lemieux.Contract`
uses Elixir's compact standard-library JSON encoding and lowercase SHA-256.
The digest covers the entire object except its own digest field and any
explicitly documented exclusion. Arrays remain ordered; callers must not sort
or reinterpret them while verifying. Constructors normalize the collections
whose order is semantically a set, such as exposure case ids.

Unknown schema versions, missing digests, and unchanged digests over modified
content return errors. Additive fields require a version change when an older
reader cannot safely ignore their meaning. The transcript writes entry
schema version 2 for the `harness_snapshot` and `run_evidence` types and
reads versions 1 to 5. See
[Transcript compatibility](transcript-compatibility.md).

The shared full-object wire example is
[`test/fixtures/harness_learning/contracts.json`](https://github.com/houllette/lemieux/blob/main/test/fixtures/harness_learning/contracts.json).
It is checked byte-for-byte against deterministic builders and then verified
contract by contract. An orchestrating host and Ixway should vendor that file
as a test fixture, not import Lemieux modules or share a database schema.

## Effective harness and run evidence

An accepted prompt is one run. It may make several model requests and tool
waves. The durable order is:

```text
user
  -> prepare_next_turn hook
  -> harness_snapshot
  -> request
  -> assistant/tool_result/approval/compaction ...
  -> zero or more additional harness_snapshot/request cycles
  -> assistant | error | cancelled
  -> run_evidence
  -> {:finished, stop_reason}
```

A new harness snapshot is built after the request hook and before every model
request. A resume or fork therefore records the behavior actually in force,
not a parent transcript's stale assertion. Audit-only snapshot and evidence
entries are retained in the transcript but excluded from the provider
conversation and compaction accounting.

`Harness.Snapshot.semantic_sha256` covers ordered resolved assets, the system
prompt digest, model and effort, safe request parameters, context limits, the
visible tool catalog and descriptors, host profile identifiers, and Lemieux
and ReqLLM versions. It excludes the snapshot id and opaque correlations.
`manifest_sha256` covers those audit fields as well. Two tenants can therefore
group behavior-equivalent runs by semantic digest without losing tamper
evidence on tenant/run correlation.

Credential and transport-shaped keys are removed recursively from the harness
snapshot. Hosts must pass identifiers and digests in `harness_context`, never
secrets or executable values. A representative embedded start is:

```elixir
Lemieux.start_session(
  supervisor: MyApp.Agents,
  provider: provider,
  store: store,
  model: "anthropic:claude-sonnet-4-6",
  correlation_ids: %{
    "tenant_id" => tenant_id,
    "project_id" => project_id,
    "attempt_id" => attempt_id,
    "experiment_id" => experiment_id,
    "arm_id" => arm_id,
    "case_id" => case_id,
    "split" => split
  },
  harness_context: %{
    "resolved_assets" => resolved_asset_refs,
    "hooks" => %{"id" => hook_profile.id, "sha256" => hook_profile.sha256},
    "workflow" => workflow_ref,
    "environment_context" => environment_profile_ref,
    "sandbox_profile" => sandbox_profile_ref,
    "sandbox_completeness" => "complete"
  },
  evidence_artifacts: artifact_references,
  subscriber: exporter
)
```

Executable hooks, environments, tools, providers, and sandboxes are still
supplied through their existing runtime seams. The maps above are evidence,
not restored authority.

Subscribers receive `{:harness_snapshot, snapshot}` for each request and
exactly one `{:run_evidence, manifest}` before `{:finished, reason}` for each
accepted prompt. Both are also entries, so an exporter crash does not erase
the audit record. The latest objects are exposed by `Session.snapshot/1`.

`Evidence.Run` deliberately does not copy prompts, tool arguments, result
bodies, or changed paths. It contains correlations; provider/model and
terminal facts; sanitized tool/approval/error observations; request and
harness digests; and typed artifact references. The transcript itself is one
such content-addressed artifact, with exact ordered entry ids and sequence
numbers plus first/last bounds. In a hosted deployment, the orchestrating host
persists the manifest and controls whether a locator can be resolved.

Hook evidence remains content-free too. `prepare_next_turn` records only its
allowed, rewritten, denied, or failed outcome and the names of changed request
fields; tool outcomes carry only a `hook_rewritten` boolean. Original and
effective prompt or argument bodies remain in their ordinary protected
transcript entries rather than being copied into the manifest.

Run outcomes are:

| Outcome | Meaning |
| --- | --- |
| `succeeded` | The model stopped normally |
| `failed` | Provider, hook, or runtime failure |
| `canceled` | Operator or host cancellation |
| `timed_out` | A timeout terminal reason |
| `budget_stopped` | The next paid operation was denied by the frozen budget |
| `stopped` | A bounded stop such as `max_turns` or `no_progress` |

Usage, cost, cache, retry, sandbox, and artifact facts distinguish `complete`,
`partial`, `unknown`, and `not_applicable`. Unknown usage or price is never
encoded as zero. Failed and canceled runs remain observations.

## Evaluating the effective lmx harness

Discovery and confirmation keep a **profile-only** default. Its observations
say `runtime_qualification.lane: "profile_only"`; a profile plus one overlay
file does not qualify the ordinary CLI's personal and repository layers.

A host can select `Lemieux.CLI.Runtime.Evaluation` to use the same
`Runtime.with_workspace/2` and `Runtime.prepare/2` assembly as `lmx run`.
Both arms receive current CLI options and the same host-supplied provider,
store, environment, hooks and ceilings. The unmodified control keeps that
assembled harness. Personal overlay descriptions apply; repository overlay
descriptions are dropped by normal discovery, with the normal notice. Disabled
extensions and inactive/declined applications remain visible in the freeze.

```elixir
alias Lemieux.CLI.Runtime.Evaluation, as: CLI

# options is the parsed CLI configuration; provider and store are fresh host inputs.
host = [cwd: workspace, provider: provider, store: store,
        environment: environment, max_requests: 6]
surface = ["system_suffix", "tool_descriptions.write"]
{:ok, prepared} = CLI.prepare(options, host, surface: surface)

# The seed is a portable search document. Only its delta is applied to lmx.
factory = CLI.factory(options, host, parent_profile: seed_profile, surface: surface)
config = Keyword.merge(campaign_config,
  runtime_factory: factory,
  runtime_identity: CLI.identity(prepared)
)
```

The frozen surface accepts an appended `system_suffix`, descriptions of
existing enabled local tools, and explicitly named `generation.max_tokens`,
`generation.temperature` or `generation.reasoning_effort` fields. It cannot
add tools, change executors or replace host policy. An edit conflicting with
a host constraint is refused before dispatch. The profile adapter accepts
append-only prompt changes, changed descriptions and those generation fields;
it rejects whole-prompt replacements, catalog/budget edits and description
removal. This preserves the actual CLI layers instead of replacing them with
the search profile. The profile's model must match the host's selected model;
this supplied adapter uses that same model for confirmation. A host supporting
another confirmation target supplies its own factory and records its model
normalization explicitly.

`Evaluator.run/3`, `Campaign.run/1`, `Campaign.resume/1` and `Confirm.run/3`
accept the factory. A campaign freezes its explicit `runtime_identity` in the
plan, together with one-way identities of the factory code/captured configuration
and shared session constraints. Resume and confirmation reject changed inputs or a switch to the
profile-only lane. Recompute the binding from current host inputs when
resuming; never copy an old identity to conceal changed configuration. A cycle
using this lane must bind its factory's parent to the cycle's actual seeded
profile, including the overlay it selected.

Each attempt assembles in the benchmark's actual workspace. Its data-only
qualification records the resolved prompt, local catalog and visibility,
applied/declined extensions, disabled selections, overlay assets and
qualification, generation settings, retry policy, verification configuration,
environment identity, resume/fork history digest, host configuration and
runtime code digests. Callback and environment state contributes only a
one-way digest. No serialized callback, environment credential, provider or
store is restored from this data. Resuming uses the normal current-host
assembly and transcript reconstruction; an old catalog cannot restore tools
that current host constraints withheld.

Observations retain `lane: "effective_lmx"`, the frozen control and effective
configuration, allowed surface and intentional changes. Request harness
snapshots carry the qualification reference in `workflow.evaluation`; terminal
run evidence names the actual request harness snapshot. Request hooks, retry
budget messages and dynamic MCP discovery can change the actual request: the
ordinary request snapshots record those facts. A prepared freeze alone does
not prove a request was authorized or sent.

`CLI.compatible?/2` permits cache reuse only for intact, identical
qualifications. Supply a non-secret host `provider_identity` map with `"id"`
and a SHA-256 `"sha256"` binding the serving route/model revision to enable
reuse. Without that binding, or with opaque process/reference state, reuse is
refused. Current permission mode and remembered rules are fingerprinted;
changed code, configuration, closure inputs, layers, generation, retry,
verification, environment, history or surface invalidate reuse. A host remains
responsible for external mutable services behind its revision. Different
workspace paths are different qualifications; copied benchmark workspaces are
not silently declared equivalent. `expected_control_sha256:` can require an
exact control before running a pre-isolated workspace.

A comparison qualifies only these recorded host inputs, model, corpus,
workspace and intentional edit. It does not establish hosted-provider quality,
transferability, sandbox containment or permission to activate an overlay.
Providers and environments remain fresh host inputs, frozen sample counts
remain unchanged, and no factory enables hosted spending implicitly. Use
isolated evaluation stores and personal-state directories when ordinary capture
or checkpoints are selected.

## Artifact-to-event correlation

The golden fixture demonstrates the complete join without embedding content:

```text
harness_snapshot.id + semantic_sha256
       ^
       | request.harness_snapshot_id/sha256
       |
run_evidence.requests[]
       |
       +-- run/session/root/tenant/project correlation ids
       +-- artifacts[].id + sha256 + media_type + content_schema + scope
       |
experience_bundle.raw[].reference
       |
evaluation.artifacts[] <- candidate.content/rationale
       |
exposure.derived_artifact_ids -> exposure.source_case_ids
```

An artifact id or locator is not authority. The receiver verifies
`schema_version`, media/schema meaning, scope, `size_bytes`, and SHA-256 over
the bytes supplied through its own authorized artifact service.

## Exposure and experience materialization

`Corpus.expose/3` records direct exposure. `Corpus.expose_derived/4` resolves
each derivation's `source_case_ids` and nested `source_derivation_ids` through
`Corpus.source_closure/2`, producing a sorted, cycle-safe closure. Once a
source case is recorded for a consumer/lineage, it cannot later become a
holdout in that corpus. Repeating the same exposure id and bytes is
idempotent; reusing an id for different bytes is a conflict.

An orchestrating host must commit this exposure before it grants a proposer,
analyzer, or development evaluator access. A derived Ixway finding does not
launder its source cases into secret evidence.

`Experience.Bundle` keeps `raw` and `derived` collections visibly separate.
Every seed, candidate, evaluation, raw item, derived item, artifact descriptor,
and plan repeats the same scope. Forbidden holdout/hidden/secret labels,
cross-scope references, derived items without sources, and malformed artifact
references reject the entire bundle.

`Experience.Materializer.materialize/4` accepts only caller-provided bytes.
It validates all paths, sizes, digests, duplicate/reserved names, symlinked
ancestors, and scope before staging. It writes `.complete` last and atomically
renames the staging tree. History and the root become read-only; only
`proposal/` remains writable. It never fetches from a host service or from
Ixway.

## Persistent improvement lessons

`Experience.Lesson` retains what an improvement attempted and why it appeared
to work, fail or remain uncertain. It is an opt-in evidence contract; ordinary
`lmx` sessions do not yet capture or activate these lessons automatically.
Hosts create a lesson from an authorized `Experience.Bundle`, its complete
artifact bytes keyed by SHA-256, and string-keyed attributes:

```elixir
alias Lemieux.Learning.Experience.{Lesson, Lessons}
alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles

# bundle and artifact_bytes are already authorized for this exact host scope.
context = %{
  "model" => "test:model",
  "tools_sha256" => Lemieux.Contract.sha256("host tool catalog identity"),
  "environment_sha256" => Lemieux.Contract.sha256("host environment identity"),
  "repository" => "my-project"
}

{:ok, lesson} = Lesson.new(bundle, artifact_bytes, %{
  "key" => "check-before-editing",
  "kind" => "procedure",
  "outcome" => "supported",
  "qualification" => "behavioral",
  "applicability" => ["editing a failing parser"],
  "mechanism" => "Run the failing check before editing to preserve the baseline.",
  "supporting" => ["observation-id-in-bundle"],
  "contradicting" => [],
  "candidate_ids" => [],
  "binding" => context,
  "provenance" => %{"actor" => "my-host", "run_id" => "run-1"},
  "created_at" => "2026-10-17T00:00:00Z",
  "expires_at" => nil,
  "supersedes" => []
})

# Select a private, ignored directory. Nothing is created until append.
store = LessonFiles.new(".lmx/lessons", bundle.scope)
:ok = Lessons.append(store, lesson)
{:ok, history} = Lessons.history(store)
{:ok, inspected} = Lessons.read(store, lesson.id)
```

The host supplies real semantic identities for its effective model, tools,
environment and repository. They are exact applicability constraints, not
restored credentials, modules, hooks or permissions. `workspace_fact` also
requires `revision` and `source_sha256` bindings; `procedure` and
`proposer_lesson` may omit those two to survive source revisions. An optional
UTC `expires_at` excludes the record at and after that instant. Missing or
changed current bindings exclude it. Facts are never rebound to new revisions
by loading a saved record.

Outcomes remain `supported`, `rejected`, `contradicted` or
`insufficient_evidence`. Qualification remains `unconfirmed` or `behavioral`,
even if a source evaluation passed: retention and output adoption establish
neither independent confirmation nor transfer to another task or model.
Mechanical evaluation/confirmation evidence remains intact in the source
bundle, with its original qualification. Storage does not activate a lesson;
`Asset.Registry` still accepts only approved asset proposals.

Every artifact reference must resolve to supplied bytes in the same exact
scope; unrelated extra bytes are refused. Observation/candidate ids must
exist, source references must resolve, and a cyclic proof is invalid. The
lesson conservatively retains the union of all source case ids in its bundle,
including earlier exposures. `source_lessons` can contain complete
`Lesson.to_map/1` manifests used to derive the new lesson; their bytes, scope
and transitive exposures are verified too. No hidden artifact fetching occurs.
The whole encoding is limited to two MiB, with 512 bundle sources, at most 16
direct source lessons and eight ancestry levels. Larger histories need a
smaller explicitly authorized bundle; they are never silently truncated.

Use `Lessons.recall/5` before giving lessons to an improver:

```elixir
consumer = %{
  "id" => "exposure-task-2", "consumer_role" => "proposer",
  "consumer_id" => "improver-1", "model" => "test:model",
  "at" => "2026-10-17T01:00:00Z"
}

# The host's callback must durably commit the Exposure under the given scope
# before returning :ok. An unavailable store returns {:error, reason}.
{:ok, lessons, exposure} =
  Lessons.recall(store, context, consumer, &MyHost.commit_exposure/2)
```

The callback receives a `Benchmark.Corpus.Exposure` whose derived artifact ids
are the returned lesson ids and whose source case ids include every direct
and transitive source. Commit those ids through `Corpus.expose_derived/4` and
persist the resulting corpus (or an equivalent transactional host ledger).
A later holdout assignment must consult that exposure history. Reuse an
exposure id only for the same consumer, timestamp, context and lesson set;
changed bytes under an id are a host-ledger conflict. Failed commits release
no content. Empty recall commits nothing. `read/2` is privileged host
inspection, so a host that feeds it directly to a model bypasses this gate.
Eligibility filtering is deterministic; the retrieval API below adds task
relevance ranking.
Recall refuses more than 16 current lessons or eight MiB of complete encoded
records by default (`max_lessons:` and `max_bytes:`). It releases no partial
result; the host must explicitly narrow the store/scope or choose a larger
finite limit.

To revise a logical key, put the old lesson ids in `supersedes` and their full
manifests in `source_lessons`. Append checks that the old records or
tombstones exist in the same store and key. Old bytes remain inspectable.
Concurrent siblings are a reported conflict, never a newest-wins selection;
resolve it by appending a lesson that explicitly supersedes both. Suppression
persists even if the replacement expires or is pruned, preventing obsolete
advice from resurfacing.

`Lessons.prune(store, id, reason, at)` is explicit retention. The local adapter
atomically publishes a digested tombstone before deleting source/content
bytes. A repeated identical prune finishes interrupted cleanup; a different
reason/timestamp is a conflict. Tombstones retain identity, scope, key,
supersession and exposure ancestry. Re-appending a pruned id is refused.
Private 0600 records publish atomically from synced temporary files, so
interrupted writes expose no partial lesson and duplicate appends do not
overwrite bytes. Symlinked ancestors/records, corrupt content and unavailable
storage return errors. The host owns the directory; these checks are not an
isolation boundary against another process that can replace its directories.
After stopping writers, the host can remove abandoned `.partial-*` files.
The default history limit is 1000 entries, configurable with `max_entries:`;
hosts archive or raise that limit explicitly instead of silently dropping
audit history. Derived lessons embed source-lesson bytes: prune those
descendants too when retention requires removing the source content. Backups
and other copies remain the host's retention responsibility.

Embedding hosts implement the `Lessons` behavior with a stateful adapter
tuple; no database, network client, registry process or scheduler is required.
The local adapter uses atomic hard links and requires a filesystem supporting
them. `lmx harness verify lesson FILE` checks a saved complete manifest
offline, without exposing its contents or contacting a provider.

## Retrieving lessons for later proposals

`Experience.Retrieval` deterministically selects scoped experience without a
provider call. Freeze the library once for a control arm, or at each task
boundary for an updating arm. Keep the frozen inventory, query, current
bindings and replay clock with the receipt to reproduce that selection:

```elixir
alias Lemieux.Learning.Experience.Retrieval

{:ok, library} = Retrieval.freeze(store, bundle.scope)
query = %{"task" => "repair a failing parser", "failure_cues" => ["no verification"]}
options = [now: ~U[2026-10-17 01:00:00Z], max_results: 4]
{:ok, receipt} = Retrieval.inspect(store, library, query, context, options)

# consumer and commit have the same durable exposure contract as Lessons.recall.
# Give each distinct consumer/retrieval context its own exposure id.
{:ok, retrieved} =
  Retrieval.retrieve(store, library, query, context, consumer, commit, options)
```

Scope, binding, creation/expiry, supersession and conflicting logical keys
are checked before ranking. At least one query word must match an
applicability cue. Unique matching words score four points in applicability,
two in the mechanism and one in the key; ids break ties. One result slot is
reserved for the highest-ranked relevant rejected or contradicted lesson.
Those notes explicitly say `counterexample`; supported records remain
hypotheses with their original qualification. This lexical policy does not
establish semantic relevance or confirm a diagnosis.

The digested receipt names selected lesson/source evidence identities, query
and binding digests, limits, scores and inclusion/exclusion reasons. Defaults
bound the inventory to 1000 ids, complete source reads to eight MiB, results
to four, reported decisions to 128, each note's text to 1024 bytes, and
materialized evidence to 32 KiB. Counts include omitted decisions. Missing
records or an exhausted source allowance produce an incomplete inspection;
retrieval refuses to release that partial ranking. Corrupt or foreign records
fail verification. Pruning still takes effect in a frozen library.

Retrieved notes point to bounded evidence files containing source digests,
selected observations and explicitly truncated artifact excerpts. A file
that cannot fit says `not_materialized`. Complete verified plan, candidate
and evaluation contracts also yield the existing comparative/calibration
results: no observed fix, an observed regression or fix, and whether the
proposer's prediction matched it. Provider/runtime failures are identified
through the existing digest and excluded from edit-effect comparisons.
Incomplete comparative contracts stay `unassessed`; these observations
establish no causal diagnosis or activation permission.

To enable this in the first-party proposer, pin
`Proposer.profile(model, experience: true)` as the plan's evolver identity
and supply an optional host context:

```elixir
experience = %{
  store: store, library: library, query: query, binding: context,
  consumer: consumer, commit: commit, options: options
}
# Pass experience: experience in Proposer.propose/3's context, or in Meta's config.
```

The host may instead supply `experience: fn proposal_context -> {:ok, config}
end` to choose a task-specific query, new exposure identity and frozen or
updated library before each proposal. Returning an error starts no session.
Capture and library-update policy remain explicit host operations. Existing
proposer profiles and the provider-free seed path keep their behavior.

Exposure commits before any lesson reaches the sealed workspace. The evolver
reads `evidence/lessons/index.json` and follows evidence pointers on demand;
the critic receives the compact index. The candidate's trace and extensions
retain the retrieval receipt and complete source-case exposure. Retrieval
adds no reflection session, dependency or allowance; ordinary proposer model
calls retain their existing host authorization and accounting.

A selected rejected profile cannot be repeated verbatim, or by replaying all
its recorded changed-field values alongside unrelated edits, without a
`reconsiderations` manifest entry. It must name the lesson, explain the new
evidence, and reference genuinely new verified development evaluations by id
and SHA-256. Old source evaluations, fabricated digests, incomplete/unsafe or
provider-failed observations do not qualify. The rationale is inspectable;
this guard does not infer semantic equivalence between differently worded
edits. It neither evaluates the proposed edit nor changes the mutation
surface, confirmation lane or active harness.

Embedding adapters can opt into bounded retrieval with `Lessons.inventory/1`
and `Lessons.fetch/3`; existing adapters remain valid for persistence/recall
and return an explicit unsupported error for retrieval until implemented.

## Discovery is not confirmation

The discovery namespace is an exploratory archive:

- `Plan` freezes the mutation surface, immutable proposer/base model and
  interface validator, disjoint development/validation ids, objectives, hard
  constraints, and aggregate candidate/token/cost/time budget. Its encoding
  cannot contain a holdout field.
- `Candidate` binds content and rationale references to the exact plan,
  proposer, parent digests, interface result, scope, and exposures. Lineage is
  resolved and cycle checked.
- `Evaluation` accepts development or validation only. Objective scores cannot
  compensate for unsafe, incomplete, non-terminal, or over-budget evidence.
- `Frontier` removes hard-invalid candidates before deterministic Pareto
  comparison. It never makes an activation decision. Two `hard_constraints`
  kinds gate before the comparison as well: `no_solved_regression` excludes a
  candidate (reason `solved_regression`) that fails a development case its
  parent had solved, so a child cannot buy a higher mean by seesawing cases
  its lineage already won, and `max_content_bytes` excludes one (reason
  `content_too_large`) whose content exceeds the declared size. Other entries,
  including the legacy `mechanical` marker, are ignored by the frontier.
- `State` records append-only candidate/evaluation idempotency keys, budget
  accounting, transitions, and the final frontier. Encoding it gives an
  orchestrating host a restart checkpoint; Lemieux does not schedule or
  persist it. A plan budget with `"unknown_cost": "allow"` is for quota-billed
  providers, where dollars are structurally unknown: a missing cost then marks
  the budget's `cost_state` unknown instead of exhausting it, while tokens and
  time still count and still exhaust.

The state statuses are `planned`, `running`, `budget_exhausted`, `completed`,
`aborted`, and `failed`. `Discovery.Shadow.run/4` is a synchronous helper for
a caller-supplied proposer and evaluator. It only runs in `:shadow` mode and
requires immutable references to an externally secured sandbox and an exposed
corpus. `fresh_session_options/2` gives every proposer iteration a new root
session. The helper has no daemon, registry credential, or activation call.

The only path from a profile candidate to a qualified claim is
`Discovery.Confirmation.to_experiment/3`, which the confirmation lane
`Discovery.Confirm` runs. It verifies the selected candidate bytes, freezes
them as the one variant in an ordinary `Experiment.Plan`, and retains
development/validation results only as provenance. Hidden outcomes cannot
be prepopulated. Harness-code candidates require complete `CodeGate`
evidence and are marked human-release-only. A meta candidate, whose content
is a proposer profile, is judged by `Discovery.Meta.confirm/3` over paired
inner campaigns instead; see [The recursive step](#the-recursive-step).
`lmx harness export` writes an unconfirmed candidate into the active
overlay only with `--unconfirmed`, and labels the file's qualification as
such.

`Asset.Registry.activate/2` accepts only the existing approved asset proposal
shape and explicitly rejects discovery objects. Ixway findings, frontier
membership, and search scores have no conversion to activation authority.

## Search, proposer and standalone campaigns

The archive contracts above describe *what* a search records. The modules
below are the search itself. They are pure functions over the contracts
wherever a model is not required, and every one of them is reachable
offline through `Lemieux.Providers.Scripted`.

| Module | Role | Research it rests on |
| --- | --- | --- |
| `Lemieux.Learning.Discovery.Policy` | Search policy read from `plan.extensions["search"]`: the success objective and threshold, widening alpha, failed-case weight, fidelity tiers, always-included cases and their attempt counts, prior, clade posteriors, RNG seed, operator weights and the consolidation switch | One reader for defaults, so a plan that says nothing keeps its digest |
| `Lemieux.Learning.Discovery.Evaluator` | Maps a `Lemieux.Benchmark` report to evaluations and runs one profile candidate on selected cases; objectives come from the plan by name, safety is the changed-path allowlist, cost and sandbox completeness follow the plan's declared lane | The contract's own rule that unknown is never zero |
| `Lemieux.Learning.Discovery.Digest` | Clusters failures by verifier cause, causal status and mechanism from recorded tool outcomes | Self-Harness failure signatures; HarnessX's digester |
| `Lemieux.Learning.Discovery.Selection` | Thompson sampling over node and clade Beta posteriors, a widening rule deciding expand-versus-evaluate, failed-case-weighted and discrimination-weighted case sampling, fidelity tiers | Huxley-Gödel Machine; Mendel Gödel Machine; Harbor's multi-fidelity ladder |
| `Lemieux.Learning.Discovery.Comparison` | Reaction-norm and cross-lineage evidence for a parent, operator selection, acceptance per operator | Mendel Gödel Machine's comparative operators |
| `Lemieux.Learning.Discovery.Calibration` | Scores a candidate's predicted fixes and at-risk cases against realized outcomes: precision, recall, Brier | Agentic Harness Engineering's decision observability; "Harness Updating Is Not Harness Benefit" |
| `Lemieux.Learning.Discovery.Surface` | The bounded edit surface for profile candidates: dotted paths a candidate may change, grader-reference and size limits, and the validator identity a plan pins | Evolve-block markers; the DGM logging-marker incident |
| `Lemieux.Learning.Proposer` | The first-party proposer: digester, planner landscape, one evolver session writing a complete profile plus a manifest with predictions, one tool-less critic session that may veto | Self-Harness; HarnessX's AEGIS; HarnessFix |
| `Lemieux.Learning.Discovery.Campaign` | The standalone-host role: freezes the plan, records exposure first, runs `Shadow.run/4` with `search: true`, persists every candidate, evaluation, artifact and state as they happen | The cross-system architecture's "standalone host" |

`Policy.defaults/0` lists what a plan that says nothing gets.
`success_objective` is nil, which resolves to the plan's first maximized
objective, and `success_threshold` is 1.0. `widening_alpha` is 0.5 and
`failed_case_weight` is 3.0. `fidelity_tiers` is nil, which means one tier
over every development case, and `always_case_ids` is empty. `attempts` is
1 and `always_attempts` is nil, which means the same as `attempts`. `prior`
is `[1, 1]`, `clade` is true and `seed` is 0. `operator_weights` gives
`clonal`, `reaction_norm` and `cross_lineage` 1.0 each and `consolidate`
0.5, and `consolidate_enabled` is false.

`Shadow.run/4` keeps its linear loop by default. With `search: true` each
iteration asks `Selection.next_action/5` whether to expand a parent or
evaluate a candidate on its next fidelity tier; the first expansion always
produces the seed as a candidate so every later edit has a scored parent to
be compared with. A candidate the critic vetoed or the surface validator
rejected is recorded with its reason and never evaluated; that is the
rejected-edit buffer and it costs no rollouts. Selection decisions, vetoes,
incomplete attempts and the closing calibration summary are `State` events,
so a restart projection explains the archive's shape.

The `search` map also decides how much of the development split an
evaluation sees and how often. `fidelity_tiers` lists cumulative case
counts, so a candidate is first evaluated on a small tier and only widened
when selection keeps choosing it; `always_case_ids` are never deferred by a
tier, because they are the cases every candidate must face first. One run
of a case is one sample of a random process: the same profile can fail a case
once and pass it the next time, so a single run would decide whether an edit
was "safe". `attempts`
(default 1) repeats every development case that many times per evaluation
and `always_attempts` overrides it for the always cases; each attempt is its
own session and its own evaluation (`eval_<candidate>_<case>_1`, `_2`, and
so on). A case is solved only when **every** attempt passes — the frontier's
`no_solved_regression` gate, the proposer's comparative evidence, the
campaign report's "dev passed" column and the frontier's eligibility gate
(one unsafe attempt disqualifies) all read it that way — and frontier scores
are means over cases, not over evaluations, so a repeated case does not
outweigh one run once. Repeats multiply cost and time in proportion; only
the plan's token, cost and time budget bounds them.

Two additions to `Lemieux.Extension.Profile` and `Lemieux.Experiment.Plan` serve
the search. `options.tool_descriptions` lets a candidate change what the
model reads about a tool through `Lemieux.Tool.Override` without touching
execution, because that is the surface where the field reports edits pay and
transfer. The `e_process` stopping rule gives the confirmation lane an
anytime-valid acceptance test; see the [confirmation guide](agent-extensions.md#confirmation-and-qualified-export).

Run a campaign from a trusted configuration:

```sh
LMX_DISCOVERY_MODEL=provider:model mix lemieux.discovery examples/discovery/campaign.exs --allow-live
```

The example configurations under `examples/discovery/` use
`LMX_DISCOVERY_MODEL` for the searched model and the proposer, defaulting to
`zai_coding_plan:glm-5.3` (Z.AI's Coding Plan, which needs its own key).
Without `--allow-live` the command refuses any provider other than the
scripted double.

`campaign.exs` and `meta.exs` are written for a quota-billed plan like that
one. The seed goes through `Lemieux.Extension.Profile.quota/2`, which bounds
each session by requests instead of dollars, `quota: true` does the same for
the proposer, and every campaign budget allows `0.0` dollars. Point them at a
metered model unchanged and the first proposal or evaluation that reports a
cost exhausts that budget: the campaign stops as `budget_exhausted`. For a
metered model, drop `Profile.quota/2` and every `quota: true`, so each
session keeps its `"max_cost_usd"` (a session with a dollar cap refuses a
request it cannot price), and set `"maximum_cost_usd"` to what you are
willing to spend. Leave out `"unknown_cost" => "allow"` as well: the seed
candidate makes no request and reports a known $0, so a metered search runs
on past it, and without that setting a request nobody could price stops the
search (`budget_exhausted`) instead of counting as a lower bound.
`cycle.exs` runs a metered model beside a quota one, so it keeps
`"unknown_cost" => "allow"` for the quota model.

The archive lands under the
configuration's `output_dir`: `plan.json`, `exposure.json`, `seed/`,
`candidates/`, `evaluations/`, `artifacts/` (candidate contents and
transcripts by SHA-256), `proposals/` (each proposer workspace), `sessions/`
(every evaluated session's transcript, unless `:sessions_dir` points
elsewhere), `workspaces/` (the fixture copies attempts run in), `state.json`,
`frontier.json`, `calibration.json`, `digest.json`, `selection.json` and
`report.md`. `incomplete.jsonl` is appended with every attempt that ended
without an observation, `error.json` is written beside the state when the
campaign fails, and `confirmations/` appears once the confirmation lane has
run on a candidate. A frontier member is a development result over exposed
cases. Freeze it and run the confirmation lane on fresh cases before claiming
anything. The campaign has no hosted or automatic activation path; the only
local one is the reviewed overlay `lmx harness export` writes. The corpus
exposure it records is what prevents those cases from ever becoming a holdout.

An interrupted campaign resumes with `--resume` from the same configuration.
`Campaign.resume/1` treats the persisted plan as authoritative, checks that
the configuration still names the same evolver profile and manifest, loads
every recorded candidate and evaluation, and hands them to `Shadow.run/4` as
`:resume`. The state's idempotency keys make re-recording impossible, so the
only way to repeat paid work would be to forget it, and the loop refuses to
start from an archive that disagrees with its state.

### Confirming a candidate on a target model

A frontier member is confirmed, never promoted, by
`Lemieux.Learning.Discovery.Confirm`:

```sh
mix lemieux.discovery.confirm examples/discovery/campaign.exs CANDIDATE_ID \
  --allow-live --model openai:gpt-5-mini --usage-mode metered --max-cost-usd 3.0
```

It preregisters an ordinary `Lemieux.Experiment.Plan` through
`Discovery.Confirmation.to_experiment/3`, runs paired control (the seed) and
variant sessions on the manifest cases that were neither development nor
validation members of the plan, reduces related cases to cluster means, and
decides with the `e_process` rule unless `--legacy-rule` asks for the fixed-n
interval. `--model` runs both arms on a different model than the search
used: "Harness Updating Is Not Harness Benefit" reports that gains often do
not transfer, and AHE and the Mendel Gödel Machine report that structural
edits transfer while prose does not, so a candidate found cheaply on a small
model is confirmed where it will be used. The swap and any budget
normalization are recorded in the plan's control reference. The confirmation
directory is single-use; its exposure marker is written before the first
session and a second run there is refused.

The other flags are `--holdout a,b,c`, which restricts the holdout to named
cases the search still never saw; `--control CANDIDATE_ID`, which pairs
against a candidate other than the seed; and `--repetitions`, `--alpha`,
`--minimum-effect`, `--minimum-pairs`, `--max-cost-usd` and
`--max-cost-per-attempt-usd`. The defaults are one repetition, `alpha`
0.05, `minimum_effect` 0.1, `minimum_pairs` 2 or the number of holdout
clusters when there are fewer, `max_cost_usd` 5.0,
`max_cost_per_attempt_usd` 0.25 and `max_requests_per_attempt` 24 for a
quota profile. `--legacy-rule` swaps the e-process for the fixed-n interval
with `minimum_pairs` 2, or the `--minimum-pairs` value, at confidence 0.9.
The confirmation directory is `confirmations/CANDIDATE_ID` inside the
campaign archive; it receives `experiment-plan.json`, `exposure.json`,
`report.json`, `decision.json` and `result.json`.

### Mining a transcript for opportunities

`lmx feedback --mine SESSION` runs one bounded, tool-less reflection over a
stored transcript and records each opportunity the model names as a
`Lemieux.Feedback` record with a model actor and `reflection` provenance.
`Lemieux.Reflection.reflect(session, mode: :opportunities)` does the same inside a
running session, and `Lemieux.Reflection.Opportunities` is the library seam.
A mined record enters the same triage and case-draft path as a person's
feedback; it can propose a mechanical case, and it can never become an asset
on its own. RHO shows self-preference is trustworthy when grounded in
re-solving real failures, which is why a mined lesson goes through the same
case gate as a person's.

### The recursive step

`mix lemieux.discovery examples/discovery/meta.exs --allow-live --meta` runs
`Lemieux.Learning.Discovery.Meta`: a campaign whose seed is the proposer's own
profile, whose mutation surface is the proposer's instructions, and whose
cases are inner campaigns. One outer evaluation runs one inner campaign with
the candidate proposer profile and scores it by `frontier_yield` (the share
of the inner proposer's proposals that reached the inner frontier) and
`brier` (its prediction calibration, with an uncalibrated inner run scored
1.0). The proposer's own token spend is measured into each evaluation's
observations but is not a default objective, because as one it would let a
proposer that is worse on both scores win by being slightly cheaper. Add
`proposer_tokens` through `:objectives` when spend matters more than that. The
outer loop is the same `Shadow.run/4`, the same surface validator and critic,
and the same absence of an activation path; this is Hyperagents' editable
meta-level with no new authority.

A frontier proposer profile is confirmed on the validation inner campaigns
the outer search planned but never ran:

```sh
mix lemieux.discovery.confirm examples/discovery/meta.exs CANDIDATE_ID --meta --allow-live
```

`Lemieux.Learning.Discovery.Meta.confirm/3` runs each validation inner
campaign (the plan's `validation_case_ids`, frozen when the campaign
started) twice — once with the seed proposer profile as the control and
once with the candidate's as the variant — under
`confirmations/CANDIDATE_ID/<campaign>/{control,variant}` in the meta
archive, scores both with the same `frontier_yield` and `brier`, and pairs
them per campaign. The verdict is `pass` when the variant is no worse than
the control on both objectives on every validation campaign and better by
at least the minimum effect (0.1 yield, 0.05 Brier) on at least one
objective of at least one campaign; `fail` when any campaign is worse by at
least the minimum effect on either objective; `safety_failure` when a
variant run's inner candidate referenced held-out material; otherwise
`inconclusive`, which is also what an identical pair earns. The directory
is single-use, and `result.json` and `report.md` record the pairs with the
sample size. That n is the number of validation templates, and one inner
campaign per template is a sample of one: the verdict says whether the edit
held up on a campaign it was never tuned on, and the report labels it
development-grade evidence for that reason. Nothing is activated.

## Using self-improvement regularly

The pieces above are experiments somebody remembers to run. Routine use is
a loop with four properties: it starts from your active overlay, it grows
its own corpus, it never optimizes for one vendor's model, and the
only thing it changes on its own is a recommendation.

### The active overlay

The learned layer is an **overlay**: a file holding a system-prompt addition
and tool descriptions, with the provenance of the candidate it came from.
`~/.lmx/harness.json` is yours; `.lmx/harness.json` at a repository's root is
the repository's. `lmx` discovers both like persona and instruction files,
adds their text inside the workspace context block, and records the applied
overlay's digest and qualification in every request's harness snapshot. The
two are not equal:

- **Your own overlay** may add system-prompt text and re-describe tools.
  `lmx` wraps the tools it names in `Lemieux.Tool.Override`, which changes
  what the model reads about a tool and nothing about what the tool does.
- **A repository's overlay** may only add system-prompt text, and `lmx` names
  it on every start: `.lmx/harness.json: this repository's learned overlay
  (QUALIFICATION, DIGEST) adds text to the system prompt; delete or revert the
  file to stop it`. Its tool descriptions are dropped with a notice of their
  own, because a checkout that describes `bash` as safe to run anything is a
  stronger lie than any paragraph of instructions. A repository overlay
  linked from outside the checkout is refused.

With both present, both texts apply (yours first), tool descriptions come
only from yours, and the recorded qualification is the weaker of the two.
`qualification` must be `confirmed` or `unconfirmed` (absent means
unconfirmed); any other value makes `lmx` ignore the file and say so. The
file's `sha256` is computed by whoever wrote it, so it proves the file is
intact, not who wrote it. Activation is your review of the file; rollback is
deleting or reverting it. There is no other mutable learned-memory plane.

`lmx harness export` writes `.lmx/harness.json` in the current directory
unless `--to` names another path. Because a repository overlay applies only
its text, export to your own overlay when you want a candidate's learned tool
descriptions. An export with tool descriptions to anywhere else still writes
the file, then says on standard error which tools' descriptions do not apply
from there (or, when the overlay holds nothing but descriptions, that
nothing in it applies) and to export with `--to ~/.lmx/harness.json`
instead:

```sh
lmx harness export tmp/discovery/CAMPAIGN CANDIDATE_ID            # refuses an unconfirmed candidate
lmx harness export tmp/discovery/CAMPAIGN CANDIDATE_ID --to ~/.lmx/harness.json
lmx harness export tmp/discovery/CAMPAIGN CANDIDATE_ID --unconfirmed --to ~/.lmx/harness.json
lmx harness export tmp/discovery/CAMPAIGN CANDIDATE_ID --force    # overwrites an existing overlay
```

### One cycle

```sh
mix lemieux.discovery.cycle examples/discovery/cycle.exs --allow-live
```

`Lemieux.Learning.Discovery.Cycle` seeds from the base profile with the
active overlay applied, runs a bounded campaign, confirms the best frontier
member on every configured confirmation model over the cases the search
never saw, appends the result to `cycles.jsonl`, and prints one of four
recommendations: `export` (every confirmation passed), `hold` (a
confirmation failed, regressed, was unsafe, or is still sampling; also
when no frontier member was eligible and the mean Brier is at most
`brier_hold`, and when the campaign itself failed), `retarget-proposer`
(the proposer's mean Brier is above the configuration's `:brier_hold`,
default 0.25, so it is worse than predicting no change and the next spend
belongs to a meta campaign) or `grow-corpus` (the seed passed every
development case on every model, so no edit can rank above it until there
are failures to fix). It never writes the
overlay. Run it nightly, per release, or whenever the corpus has grown; the
ledger is the generation history.

The overlay a cycle seeds from is the file its configuration's
`:overlay_path` names, `.lmx/harness.json` by default, applied whole, tool
descriptions included. The example cycle searches with `LMX_DISCOVERY_MODEL`
and adds `LMX_DISCOVERY_SECOND_MODEL` (default `openai:gpt-5-mini`, metered
and capped per session) to its portfolio.

### Leaving it running

A cycle can run unattended because of one line in its configuration:

```elixir
allowance: %{"maximum_cost_usd" => 10.0, "maximum_tokens" => 40_000_000, "window_days" => 30}
```

Before a campaign starts, the cycle sums what the ledger shows spent inside
the window and adds its own worst case (the campaign's budget caps plus the
confirmation cost cap per confirmation model). If any limit would be
exceeded the cycle is refused, exits non-zero, and writes nothing: a
clamped campaign would be a different experiment from the configured one.
`mix lemieux.discovery.cycle CONFIG --status` prints the generation count,
the last verdict, the spend in the window and whether the next cycle would
be admitted, without running anything. A scheduler needs nothing else:

```sh
# crontab: one generation a night, refused automatically once the month's allowance is used
15 2 * * * cd /path/to/repo && mix lemieux.discovery.cycle examples/discovery/cycle.exs --allow-live >> tmp/discovery/cycle.log 2>&1
```

Read the ledger in the morning. `export` means one review of a candidate
under `lmx harness export`; `retarget-proposer` means the next scheduled
spend should be `--meta`; `grow-corpus` means the next spend is a person's
hour on cases, not a model's; a run of `hold` verdicts with inconclusive
confirmations means the holdout needs clusters, not the search more budget.

### What the workspace does and does not contain

Every attempt runs in a fresh copy of the case's fixture, initialized as its
own Git repository so a model that commits its work commits there: a copy
under a directory inside another repository is, to Git, part of it. Nothing
else is contained. The trusted local lane gives the model the host's shell;
run models you do not trust through a host sandbox runtime
(`Lemieux.Benchmark.Runtime.Sandbox`), and keep campaign output directories
out of anything you would mind a shell reaching.

### Not one model

A campaign's `:models` list is a portfolio: every case is evaluated on every
listed model, every objective becomes the mean across models, safety holds
only if it held on all of them, and each model's task success stays visible
to the frontier as `task_success@model`. Success for the search is
success on every model. A cycle's confirmation models can be a different
set again. The harness belongs to whoever runs it, on whatever model they
choose, so a candidate that only helps one vendor is a `hold`.

### Growing the corpus

The corpus is the binding constraint. Cases arrive through feedback:

```sh
lmx feedback --mine SESSION                                  # a model names opportunities
lmx feedback SESSION --text "It never reran the check"       # a person names one
lmx feedback draft-case FB_ID --source DIR --output eval/drafts \
  --prompt "Fix value.txt and rerun the check." --verifier "sh check.sh" --class mechanical
lmx corpus promote eval/drafts/case_ID eval/corpus/local/manifest.json \
  --cluster value-repair --allow value.txt
```

`draft-case` freezes a fixture and a verifier beside the record and records
your verifiability judgment as a revision; a mined record is not eligible
until a person classifies it. `promote` copies the reviewed fixture beside
the manifest, appends the task with its cluster and allowlist, and refuses a
mutation case whose grader already passes untouched: such a case can never
tell a candidate from the seed. Allowlists must include what the
verification command itself produces (`dist/**` for a `make` target).

A corpus is meant to be committed, so neither step copies secret-shaped
files. `draft-case` leaves them out of the fixture by name (`.env`, private
keys, credential stores and the rest `Lemieux.Benchmark.SecretFiles` lists)
and records each one as skipped; `promote` refuses a fixture that still has
one and names it, unless you pass `--allow-secret-files` for a deliberate
fake. The rule reads names only, so review a draft before you promote it.

### Bounded refinement controller

`Lemieux.Learning.Controller` is an explicit host-owned contract for ordinary
tasks, proposers, critics, probes, composition, reflection and confirmation.
It starts only when the host mounts it. The default learning allocation is
zero. The host supplies the existing `Lemieux.JobBudget`, finite token/time
ceilings and an allocation inside those ceilings; learning creates no extra
spend allowance. Request and dollar reservations use that same job ledger.

```elixir
{:ok, job} = Lemieux.JobBudget.start_link(max_requests: 40, max_cost_usd: 2.0)
{:ok, controller} = Lemieux.Learning.Controller.start_link(
  job_id: "task-42", job_budget: job, max_tokens: 100_000, max_time_ms: 120_000,
  learning: [max_requests: 8, max_tokens: 20_000,
    max_time_ms: 30_000, max_cost_usd: 0.5]
)
controlled = Lemieux.Learning.Controller.provider(controller, :task, provider,
  token_bound: &host_token_upper_bound/1, timeout_ms: 10_000
)
```

The token-bound callback is trusted, provider-free host policy and must cover
all input, output and cache tokens. An absent bound or provider refuses the
request. Start the controller before token-consuming parent work and route
every participant through it. Untracked parent requests close token admission.
Do not also charge the same provider request to a session-owned job ledger;
the controlled provider already reserves it. Other paid tools may use the
shared job ledger normally.

Reservations precede dispatch and persistence precedes effects. Each physical
retry consumes another request. Cancellation kills guarded work and retains
unknown usage; it never refunds the request. Reconciliation is idempotent,
and restoring an interrupted reservation marks it unknown rather than running
it again. Current limits, providers, callbacks and authority come from fresh
host options. Checkpoints contain data only and must match the job identity.
For crash durability, the job ledger and controller both need synchronous
host-owned persistence; an in-memory snapshot alone is not durable recovery.

Dollars use the job ledger's integer precision. Metered unknown pricing
refuses admission. Explicit `cost_mode: :quota` permits unknown dollars only
when the outer ledger and learning allocation have no dollar ceiling; tokens,
requests and time still count. Unknown cost stays `nil`. Admission estimates
are bounds supplied by the provider/host, rather than a billing guarantee;
actual overruns are recorded and stop further work. Runtime deadlines use a
monotonic clock, with a bounded wall-clock deadline retained for restart.

`Controller.consider/2` inspects bounded deterministic signals and records
healthy, unsupported and duplicate signals as no-op outcomes. Readiness never
authorizes dispatch. `reconcile/4` may carry a new information digest; repeated
uninformative attempts stop learning. `Controller.select/3` keeps the original
harness/output unless supported comparison bounds show an improvement.
Status, consideration and selection make no provider request. Decision history
is finite; reaching its limit stops work instead of forgetting idempotency.

The first-party proposer accepts an explicit
`{"outcome":"no_supported_improvement","reason":"..."}` manifest without
inventing a profile edit or invoking a critic. Select `Proposer.profile(model,
abstain: true)` to include that protocol in its instructions. A controller
signal can abstain before resolving a provider or exposing lesson evidence.
No-op usage is retained by the search state without adding a candidate;
ordinary candidate surface validation is unchanged. Cycles retain the seed on
primary-objective ties, regressions or missing paired development coverage.

For a preregistered experiment, `Controller.admit/3` checks the entire frozen
allocation and binds its plan digest. `Controller.experiment/5` reserves the
whole allocation before mounting a child controller; all child requests draw
from that reserved capacity. Unused dollars/tokens settle to actual usage;
allocated request slots are conservatively consumed even when unused. Supply
an explicit full request bound covering both arms, repetitions, tool turns and
retries. Admission never rewrites the plan to fit the remainder. Exhaustion or
interruption remains incomplete execution evidence.

`Campaign.run/1` and `resume/1` accept `controller:`, `token_bound:` and a full
`controller_allocation:` map with `:requests`, `:tokens`, `:time_ms` and
`:cost_usd`. Allocation must cover the frozen plan's entire maximum. Proposer
and critic calls share it with probes. `Confirm.run/3` uses that same host
controller, with its own `controller_allocation:` in the confirmation options;
both arms keep their preregistered normalization and sample counts. A recovered
interrupted allocation cannot be dispatched again. Host admission denials and
interrupted controller work cannot qualify as a candidate's task-quality
failure. Other hosts can wrap existing provider seams for any controller role,
including the meta proposer, without adding a provider adapter or bypassing
the live-run authorization gate.

### Ordinary-session capture

`Lemieux.Extensions.Capture` is selected by the stock `lmx` host when personal
state is enabled. It makes no model request. It observes verification failures
and failure-to-recovery episodes, corrections, and repeated tool failures or
recoveries. An observation is separate from a diagnosis: passing a later check
never establishes task correctness. Corrections without a verifier stay
`needs_review` drafts.

Before a prompt's first request, capture checkpoints bounded workspace bytes
through the active environment and effective read policy, without approval
prompts. Retries reuse those inputs. A resumed prompt
with earlier effects cannot replace missing inputs with the repaired workspace.
Terminal capture reads authoritative transcript entries; records contain entry
identities and hashes, observations, and terminal evidence references, rather
than copied conversation bodies. Input files remain private source content.

The defaults allow 256 KiB total, 64 KiB per file, 128 visited paths and 250 ms
per observation. A guarded worker dies when its caller dies or its deadline
expires. Environments must implement streaming reads, so the project policy cannot
trigger an unbounded fallback read. Unsupported streaming disables capture.
Timeouts, missing artifacts, omitted files, secret-shaped names, symlinks and
size limits produce unavailable or incomplete inputs. Capture never runs a verifier, and unknown replay eligibility is false.
Only file bytes are captured; permissions, services and external dependencies
must be reviewed by the host before replay. A generic transcript store owns its
read bounds; the stock JSONL store is also checked before reading.

Records live under `~/.lmx/capture/PROJECT_DIGEST/`, with private permissions and
an ignored directory. The host/project scope uses the workspace path digest,
not its basename. Retention defaults to 128 records for 30 days; expired and
excess records are removed on terminal capture. Pending checkpoints are bounded
and pruned during capture and removed after terminal processing. Storage and
callback failures emit a generic warning without transcript text and leave
ordinary completion intact.

```elixir
{:ok, records} = Lemieux.Extensions.Capture.history(capture_root, workspace)
:ok = Lemieux.Extensions.Capture.prune(capture_root, workspace, 30, 128)
:ok = Lemieux.Extensions.Capture.forget(capture_root, workspace)
```

Disable future capture with personal `"capture": false`,
`"disabled_extensions": ["capture"]`, `--config none`, or project
`.lmx/capture.json` containing `{"enabled": false}`. Malformed project policy
also disables capture. The project file cannot override a host opt-out.
Opting out creates no capture files; use `forget/2` to delete retained content.
Capture is omitted for extension-profile runs, child sessions and aside work.
Embedders explicitly select `{Lemieux.Extensions.Capture, dir: private_root,
store: transcript_store}`; adding the library starts no capture process.

A host may explicitly call `Capture.materialize/2` into a new directory to
inspect the original bytes. `Capture.validate_replay/3` additionally takes a
host-owned isolated validator `(directory, command) -> {:ok, exit_status}`;
it must reproduce the original defect using the exact recorded command and
exit status. A passing or mismatched check cannot qualify it. The callback is
trusted host work, never something a stored record authorizes. A copied
directory alone is not isolation. No provider call or command is triggered by
reading or loading a record.

Only after that explicit check can `Capture.case_draft/3` create an ordinary
`Lemieux.Feedback.CaseDraft`, still marked `draft`. Human review of secrets,
missing runtime requirements, acceptance criteria and the grader's failure on
the untouched control remains required before `lmx corpus promote`. A
correction, unavailable checkpoint or incomplete input cannot take this lane.
Capture does not automatically turn observations into lessons or activate them.
The [older capture example](https://github.com/houllette/lemieux/blob/main/examples/extensions/capture/README.md)
illustrates explicit command hooks; use the first-party extension for
pre-effect inputs and recovery records.

### What to watch

The cycle ledger and each campaign's `calibration.json` are the two numbers
that decide where the next cycle's spend goes. A rising frontier with
inconclusive confirmations means the holdout needs more clusters. A mean
Brier at or above the carry-forward baseline means the proposer, not the
harness, is what is holding progress back, and the meta campaign
(`--meta`) is how that is acted on. Read the frontier's exclusions too. The
reasons are `interface_invalid`, `no_evaluations`, `safety_failed`,
`evidence_incomplete`, `solved_regression` and `content_too_large`. A seed
excluded as `safety_failed` is a finding about the harness you run today,
while `evidence_incomplete` is a finding about the run, usually an evaluator
timeout, and `no_evaluations` means a candidate that passed the interface
check was never scored, usually because the budget ran out before its first
tier.

## Standalone inspection

The CLI exposes the parts that are safe without a hosted control plane:

```sh
lmx harness verify snapshot snapshot.json
lmx harness verify run run-evidence.json
lmx harness verify bundle experience-bundle.json
lmx harness verify discovery-plan plan.json
lmx harness verify candidate candidate.json
lmx harness verify evaluation evaluation.json
lmx harness verify frontier frontier.json
lmx harness verify state state.json
lmx harness verify exposure exposure.json
lmx harness verify experiment-plan experiment-plan.json

lmx harness materialize bundle.json ARTIFACT_DIR DESTINATION
```

Artifact files are named by reference id or SHA-256. Foreground shadow search
is a library API because a safe run needs real host-supplied proposer and
evaluator callbacks plus a sandbox declaration; a bare path or prompt cannot
be turned into those capabilities honestly. The command-line wrapper is
`mix lemieux.discovery`, and it works only because a trusted configuration
file supplies the proposer, the evaluator and the trusted-local sandbox
declaration.

## What an orchestrating host adds

A host application that runs the hosted loop should:

1. authenticate scope and resolve executable policy;
2. supply correlation ids, behavior-bearing profile references, and authorized
   artifacts;
3. persist snapshot/run events idempotently by ids and digests;
4. project the minimum authorized evidence to Ixway;
5. commit transitive exposure before releasing an experience bundle;
6. persist discovery state around effectful jobs; and
7. remain the sole confirmation, activation, canary, and rollback authority.

Ixway should consume the host's projection, retain source references and
derivation versions, and return findings, not Lemieux candidates or registry
writes. Lemieux does not know whether a finding came from Ixway; it sees a
scope-checked derived item and its complete source closure.

These contracts are complete on the Lemieux side. A hosted deployment is not
complete until the golden fixture passes in the host and in Ixway and the
[cross-system acceptance runbook](acceptance.md) passes.
