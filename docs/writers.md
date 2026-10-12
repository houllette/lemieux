# Isolated parallel writers

`Lemieux.Writers` splits independent implementation briefs among isolated
top-level sessions, collects reviewable patches, and integrates accepted
patches through one coordinator. This is an opt-in embedding API. It does
not enable writers in ordinary `lmx` or broaden the read-only `subagents`
tool. No separate job server is required: start a batch from an existing
parent session.

The parent must already have an inclusive `:job_limits` allowance or
host-owned `:job_budget`. Writers share that exact ledger, including
auxiliary inference and declared paid tools, even when their providers differ.
The host supplies current credentials, environments, permissions and checks.

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
`apply_patch`, and grants no shell. Command-based search also requires an
environment granting commands. Another workspace adapter may grant commands
only with a host-provided environment that enforces the intended scope.
A worktree separates files, not security; Git metadata and objects are
shared. Trusted Elixir callbacks remain host authority.

## Results and review

Each writer returns JSON with `summary`, `critical_findings` and
`uncertainties`. The host's `verify/3` receives the complete session
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

The worktree adapter freezes HEAD when constructed. It refuses stale bases,
dirty accepted paths, overlapping patches and altered artifacts. Unrelated
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

## Migration

This API is additive and experimental. Existing scout definitions remain
read-only. Hosts opting in must supply the shared allowance and lifecycle
callbacks. `Session.register_work_owner/3` keeps the parent busy, propagates
cancellation and removes a dead owner's registration without importing
writer code into the core. Startup and ordinary CLI behavior are unchanged.
