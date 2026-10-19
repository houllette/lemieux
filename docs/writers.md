# Isolated parallel writers

`Lemieux.Writers` splits independent implementation briefs among isolated
top-level sessions, collects reviewable patches, and integrates accepted
patches through one coordinator. This is an opt-in embedding API. It does
not enable writers in ordinary `lmx` or broaden the read-only `subagents`
tool. A host can expose writers to its model through the optional
`Lemieux.Extensions.Writers` extension described below. No separate job server
is required: start a batch from an existing
parent session.

The parent must already have an inclusive `:job_limits` allowance or
host-owned `:job_budget`. Writers share that exact ledger, including
auxiliary inference and declared paid tools, even when their providers differ.
The host supplies current credentials, environments, permissions and checks.

## Let the planning agent choose

`Lemieux.Extensions.Writers` adds a configured `writers` tool and concise
selection guidance to an ordinary harness. The extension is opt-in; the four
default tools and the read-only `subagents` contract do not change.

| Method | Suitable work | Example |
| --- | --- | --- |
| Single session | Shared files, changing interfaces, or small changes | Redesign retries across the session lifecycle |
| Read-only scouts, when supplied by the host | Independent investigations before implementation | Investigate compatibility, persistence and migration impacts |
| Serial writers | Independent isolated patches with constrained capacity | Two adapters with one available backend slot |
| Parallel writers | Substantial independent work with stable interfaces and disjoint file/test ownership | CSV and JSONL importers against an agreed ingestion contract; parent owns shared wiring |

These are heuristics to evaluate, not claims of better quality or speed. Large
tasks may still belong in one session. Serial writers within one batch use the
same base snapshot: later writers do not receive earlier patches. Dependent
stages require separately integrated batches with fresh snapshots.

Supply the same explicit host policy as the embedding API, plus maximum path
and tool grants. The model supplies briefs within those grants:

```elixir
{:ok, harness} = Lemieux.Harness.assemble(
  Lemieux.Harness.new(),
  [{Lemieux.Extensions.Writers,
    paths: ["importers/csv/", "importers/jsonl/", "test/importers/"],
    tools: ["read", "write", "edit"],
    max_writers: 2,
    max_requests: 40,
    max_batches: 2,
    workspace_factory: fn context ->
      {:ok, Lemieux.Writers.Worktree.new(root: context.cwd, directory: writers_directory,
        source: :working_tree, paths: ["importers/", "test/importers/"])}
    end,
    options: [factory: factory, verify: verify,
              checks: checks, authorize: authorize, authority: authority,
              max_active: 2, timeout_ms: 900_000]}]
)

{:ok, parent} = Lemieux.start_session(
  harness: harness, supervisor: MyApp.Agents, provider: provider, model: model,
  store: store, cwd: repository_root, job_limits: [max_requests: 120]
)
```

The host callbacks above have the signatures documented in `Lemieux.Writers`.
`workspace_factory` runs once per start after current authorization and shared
allowance checks. It must return a freshly captured adapter, so a later batch
sees accepted earlier changes. A static `options[:workspace]` is supported for
one batch only; multiple batches without the factory are refused. The default
batch ceiling is one for a static adapter and two with a factory. Reusing a
stock adapter after integration otherwise gives a later writer its original
snapshot, even when the parent working tree has changed.
The authorization callback also receives `:tool` with the requested action and
parent identity, before each invocation. It must consult current policy;
captured authority is not evidence that permission remains valid. `:paths` and
`:tools` are ceilings; factories must still provide scoped environments,
explicit tools and credentials. Worktrees alone do not sandbox commands.

The tool supports `start`, `status`, `await`, `review`, `integrate`, `cancel` and
`close`. Start requires a short reason, stable interfaces, expected checks and
bounded briefs with exact file or directory-prefix ownership. Shared interfaces
and expected checks are included in each writer's brief. Host verification is
independent of those model expectations. Start attempts consume the configured
batch ceiling once briefs and the live-batch precondition are validated,
including failed allocations; all inference uses the inclusive
job allowance. Await may return a running snapshot after its observation window.

The parent retrieves each accepted patch and report using `review`, following
`next_offset` until it is null, and explicitly supplies accepted artifact
digests to `integrate`. Both files must be retrieved completely and unchanged.
Retrieval does not prove understanding; fresh host review authorization and
project checks still gate integration. Full reports and failed artifacts remain
available after workspace cleanup. Close a settled batch before starting another.

Choices and retrieval receipts are durable generic documents, under
`lemieux.writer_dispatch` and `lemieux.writer_reviews`. They grant no runtime
permissions. Configured tools and live coordinator capabilities are not restored
from transcripts: a resuming host supplies current policy again. The extension
mentions scouts only when the catalog actually includes `subagents`.

## Run a batch

Use the [embedding API](embedding.md) to start a parent with storage outside
the writers' workspaces and an inclusive allowance:

```elixir
{:ok, parent} = Lemieux.start_session(
  supervisor: MyApp.Agents, provider: provider, model: model,
  store: store, cwd: repository_root, tools: [],
  job_limits: [max_requests: 30, max_cost_usd: 2.0]
)
```

Approve explicit briefs with non-overlapping scopes and tool names:

```elixir
alias Lemieux.Writers
alias Lemieux.Writers.Plan
alias Lemieux.Writers.Worktree

plans = [
  Plan.new(id: "parser", task: "Implement the parser changes",
    paths: ["lib/parser.ex", "test/parser_test.exs"], tools: ["read", "edit", "write"]),
  Plan.new(id: "formatter", task: "Implement the formatter changes",
    paths: ["lib/formatter.ex", "test/formatter_test.exs"], tools: ["read", "edit", "write"])
]

workspace = Worktree.new(root: repository_root, directory: private_writer_directory)
{:ok, batch} = Writers.start(parent, plans,
  workspace: workspace,
  factory: fn plan, isolated ->
    {:ok, MyApp.WriterOptions.current(plan, isolated)}
  end,
  verify: &MyApp.Checks.writer/3,
  checks: &MyApp.Checks.project/1,
  authorize: &MyApp.Policy.authorize_writers/3,
  authority: current_principal,
  max_active: 2,
  timeout_ms: 3_600_000
)
{:ok, result} = Writers.await(batch)
```

`MyApp.*` callbacks are host code, not bundled modules. The factory must
return explicit tools and build policy for `isolated.cwd`. Parent hooks
are retained and factory hooks are added. The coordinator fixes identity,
environment, store, shared ledger, execution journal and provider rate domain.
Starting a session makes no inference request; starting writers does.

Scopes are exact files or directory prefixes ending in `/`, never glob
patterns. Ancestor and case collisions are refused before allocation. Up
to four writers are allowed; `:max_active` selects one through four. One
live coordinator is allowed per parent. The elapsed deadline includes
preparation, approvals and integration and is clamped to the parent's
remaining deadline. A clock may be supplied for deterministic host tests.

The stock adapter allows file readers, `write`, `edit` and
`apply_patch`. A host factory may also supply `Lemieux.Tools.ReadOnlyBash`
for inline analysis with no writable roots or network, including background
analysis. This explicit read-only capability does not require a general
command grant. General shell tools and command-based search still require an
environment granting commands. Another workspace adapter may grant commands
only with a host-provided environment that enforces the intended scope.
A worktree separates files, not security; Git metadata and objects are
shared. Trusted Elixir callbacks remain host authority.

## Results and review

A writer that yields with background commands keeps its workspace lease until
those commands finish and it produces its final report. One batched completion
resumes the same session under its remaining allowance and deadline. Parent
**Tasks** shows live writer commands and permits inspection and cancellation.
Cancellation stops the commands and revokes their continuation; cleanup and
patch export retain their existing custody rules. The bounded
`Lemieux.Agent.Session` adapter follows the same completion lifecycle.

Each writer returns only a JSON object: `summary` is a string, and
`critical_findings` and `uncertainties` are arrays. Prose or code fences around
the object fail report validation. The host's `verify/3` receives the complete session
result and report and returns `{:ok, %{"status" => "passed", ...}}` with
a named check, or an error. A model stop does not certify completion. Failed
effects, missing patches, invalid reports and out-of-scope changes fail the
batch and prevent integration.

The adapter exports a binary Git patch, complete findings and verification,
and a manifest, tied to the writer transcript and original revision.
Artifact files remain after worktree cleanup. Failed verification and
interruption retain unverified patches; they cannot be integrated. An
unfinished report explicitly marks critical findings unavailable and links
the full transcript. The parent transcript stores
bounded references; findings are not truncated into a tool response.
Patch/report hashes and manifest identity are checked before integration.

Review the full patch and report, then accept exact digests:

```elixir
accepted = Enum.map(result.writers, & &1.artifact.digest)
{:ok, receipt} = Writers.integrate(batch, accepted, current_principal)
:ok = Writers.close(batch, current_principal)
```

An embedding UI chooses which digests to accept; this example accepts the
whole batch. Mutating actions use the current `:authorize` callback,
including authorization immediately before primary writes. Observation
capabilities cannot approve integration. Snapshots include writer session
handles so hosts can inspect pending decisions and use ordinary session
approval and answer APIs. Auxiliary model calls in host verification must
use `JobBudget.run/4` against the same ledger.

## Integration and recovery

A built-in write refused because a file was unread or changed since its last
read carries typed evidence that mutation never started. The writer may read
again and correct the write before independent verification. Permission denials,
failed actual writes and unknown executors cannot use this exception.

The worktree adapter freezes HEAD when constructed. It refuses stale bases,
staged or unstaged changes to accepted paths, overlapping patches and altered artifacts. Unrelated
working and staged edits are preserved; the user's index is never changed.
Checkout and patch capture use private Git configuration so repository
hooks, filters and external diff programs do not execute.
Unrelated ignored host files and generated build output remain outside the
patch. An ignored deliverable, a filtered file or another uncaptured source
file fails capture rather than disappearing from the result.

Project checks run on the combined candidate and again after applying
accepted paths. Checks cannot replace the accepted patch with unreviewed
content. They are bounded host callbacks returning named verification
evidence. Hosts must serialize other edits to accepted paths during
integration: filesystem rename is not compare-and-swap against an editor.

A durable intent, including bounded before/after file images, precedes primary
writes. Images retain actual bytes and file permissions, including line endings
that Git normalizes.
Exceptions, throws and exits from a post-application check also trigger guarded
rollback. Their error receipts identify the transaction, including when foreign
edits block recovery. Killing an integration task leaves its guardian armed;
losing the entire runtime requires explicit cold recovery from the journal.

Recovery does not depend on unreachable Git objects surviving garbage
collection. Complete binary patches can reconstruct an accepted tree after
Git prunes its cached objects. Failed checks or interruption
trigger guarded rollback. Every accepted file must still match its before
or after image. Foreign edits are preserved and leave a blocked transaction;
no next integration runs over unresolved work. Its identifier is returned
in the error and recorded under the repository's private
`.git/lemieux-writers` journal. After inspecting it:

```elixir
Worktree.recover(workspace, transaction_id)
```

Recovery rechecks and restores original file images. It reruns neither
provider calls nor project checks. Lease intents are recorded before
allocation. After establishing that an old runtime has stopped, a host can
clean its abandoned leases:

```elixir
{:ok, cleanup_receipts} = Worktree.reap(workspace)
```

Live or unprovable lock owners and changed leases without saved artifacts
are retained. Complete artifacts are never
removed. Normal cancellation, parent loss and coordinator loss stop writers
and release their leases. Preparation must clean partial allocations on
failure and be bounded; failed release is a hard failure leaving an
inspectable lease. Interrupted writers are never silently resumed.

## Compare before wider use

```sh
mix lemieux.writers.compare --output /tmp/writer-comparison
```

The directory must be new. It retains `comparison.json`, both arms'
transcripts, patches, manifests and full reports. The arms use identical
Scripted providers and allowances; serial runs one writer and parallel two.
The grader checks exact files, complete findings, requests, dollars and
elapsed time. Artificial model latency exercises scheduling. A time gain
here is fixture evidence, not live coding-quality evidence.

`Lemieux.Writers.Evaluation.compare/3` accepts host-recorded matched
observations. Task, base, model/policy and independent grader identities
must match. Unauthorized writes, missing effects and lost critical findings
are hard failures. Quality regression, unknown dollars, unacceptable cost
or no measured gain fail the pair. Representative matched model runs and
review of failures are still required before wider adoption. Comparison
changes no defaults and authorizes no spending.

Measure completed integration separately from candidate correctness. Include
planning, scouts, review, verification, retries and unsuccessful attempts in the
elapsed time and inclusive inference usage. Compare a single session and
scout-assisted coding as well as serial and parallel writers; serial writers
alone cannot establish that delegation improves on ordinary coding.

Freeze task inputs, hidden graders, reference controls, source revisions and
model/effort before running a cohort. Balance every method across order positions
and repeat matched cases. Use tasks with room for improvement, including existing
repository behavior and coupled component contracts. Report correctness,
robustness and maintenance review separately; a count of generated tests is not
a quality score. A host may choose a higher `:max_cost_ratio` to accept measured
quality gains at higher cost or elapsed time. Unknown costs and missing usage
remain unknown, and API-equivalent estimates are distinct from billed dollars.

## Migration

This API is additive and experimental. Existing scout definitions remain
read-only. Hosts opting in must supply the shared allowance and lifecycle
callbacks. `Session.register_work_owner/3` keeps the parent busy, propagates
cancellation and removes a dead owner's registration without importing
writer code into the core. Startup and ordinary CLI behavior are unchanged.
