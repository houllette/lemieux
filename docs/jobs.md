# Durable background jobs

For CI, builds and deployments inside an ordinary conversation, use
[session watches](watches.md). They start automatically with the equipped
session and observe existing work without a separate jobs worker.

A job has a submitted task, an inclusive allowance, a managed lifetime and
reviewable results. Its worker owns the conversation while clients come and
go. Owned background commands hold the attempt open until their results are
consumed under its remaining allowance and deadline. Cancellation revokes that
continuation. Start a worker, submit a bounded task, then attach when you want to watch:

```sh
nohup lmx jobs serve > lmx-jobs.log 2>&1 &
lmx jobs submit --max-total-requests 30 --max-total-cost-usd 5.0 "Fix the failing tests"
lmx jobs list
lmx jobs attach JOB_ID
```

From a source checkout use `mix lmx` in place of `lmx`. The worker is a
foreground process suitable for your service manager; `nohup` is one way to
keep it alive after closing the shell. Closing an attach client detaches it.
It does not cancel the job. `lmx jobs cancel JOB_ID` does.

Commands return JSON. `get JOB_ID` shows status, inclusive accounting,
pending decisions and the result. `effects JOB_ID [--cursor KEY]` shows
dispatch records and receipts. `list [--cursor JOB_ID]` and `effects` are
paged. Results name the job, root and child transcripts, verification
document, evidence entry IDs and receipt prefix. Answer previews and evidence
reference lists have explicit truncation flags; full evidence remains in the
transcripts and journal.

The default directory is `LMX_HOME/jobs`, or `~/.lmx/jobs`. Use the same
`--jobs-dir DIR` on the worker and clients to select another. The directory,
journal files and Unix socket are private to the operating-system user.
The local transport is intended for macOS and Linux; an embedded host can
choose another transport. No distributed Erlang node is started.

## Allowances and scheduling

Submission requires at least one inclusive request or dollar limit. All
parent and child inference, auxiliary model calls sharing the job ledger,
and declared paid tools reserve from the same allowance. Consumed requests
are never refunded. Unknown prices or usage close dollar admission rather
than becoming zero. An actual provider charge above its estimate is recorded
and stops further admission; estimates are not provider billing guarantees.

Jobs have a one-hour elapsed deadline by default. `--timeout-ms N` changes
it, measured from the first preparation attempt, including approval waits
and downtime. Recovery retains the original deadline and caps. For a
one-shot schedule, add `--at 2026-10-13T09:00:00Z`. Recurring schedules are
host-owned submissions, each with its own intent and allowance.

The worker defaults to two active jobs and at most 100 admitted jobs,
including queued and scheduled work. Configure it with `--max-active N`
and `--max-pending N`. Preparation occupies a slot and runs in a supervised
task, so slow setup can still be inspected or cancelled. Avoid concurrent
writers in the same checkout; this host does not provide isolated worktrees.

## Decisions use the current host

Worker options after `serve` use ordinary CLI configuration, model routing,
workspace rules, hooks and sandbox assembly. For example:

```sh
lmx jobs serve --jobs-dir /path/to/jobs --max-active 1 --config /path/to/config.json
lmx jobs submit --jobs-dir /path/to/jobs --model anthropic:claude-sonnet-5 \
  --max-total-requests 20 "Implement the requested change"
```

Jobs use an interactive permission channel even while clients are detached.
A pending approval remains visible through `get` or `attach`, and its wait
ends at the job's deadline. Approve or deny the exact pending session and call:

```sh
lmx jobs approve JOB_ID SESSION_ID CALL_ID
lmx jobs deny JOB_ID SESSION_ID CALL_ID
lmx jobs answer JOB_ID SESSION_ID CALL_ID "The answer to the pending question"
```

The client obtains the current attempt epoch before resolution; a restart
or recovery between those steps makes the reply stale. Embedded hosts also
supply their current authorization. Stored approvals do not grant authority
to a newly reconstructed worker. Questions requiring structured answers can
be answered through `Lemieux.Jobs.answer/7`.

## Interruption and recovery

Stopping the worker (`lmx jobs stop`) or losing it leaves active work
interrupted. Restart loads queued intents, but quarantines previously active
jobs. Inspect them before requesting `lmx jobs recover JOB_ID`.

| Durable evidence | Recovery behavior |
| --- | --- |
| Submitted intent, no admitted effect | Start the submitted task under current policy. |
| Completed provider or tool receipt | Repair a missing transcript result; consume the outcome without repeating the completed effect. |
| Interrupted local reader, or a host-declared idempotent and retryable tool | Retry through the current catalog and hooks; a changed descriptor is refused. |
| Pending approval | Keep its record; ask the current host again when continuing the call. |
| Dispatch start with an ambiguous external outcome | Block recovery until the host records evidence. |
| Outstanding or unmeasured paid reservation | Retain the reservation and consumed request count; close dollar admission until accounting is reconciled. |

A job is also interrupted when a live effect loses its owner before recording
a result. This fences further dispatch, including a subsequent model turn.
Cancellation prevents new dispatch and stops the root and children, but cannot
undo an external effect that already began. Such an outcome remains uncertain.

To reconcile an effect, write a JSON object with `status: "completed"`, its
provider or tool `result`, and a nonempty `evidence` reference to the proof.
Alternatively, `status: "not_run"` is an explicit assertion that the effect
did not happen. This is a host decision, not a guessed retry policy:

```sh
lmx jobs reconcile JOB_ID EFFECT_KEY effect-decision.json
lmx jobs reconcile JOB_ID budget accounting-decision.json
lmx jobs recover JOB_ID
```

A budget decision contains the verified cumulative `spent_usd` and `evidence`.
It cannot lower known recorded costs, refund requests or increase caps. Resolve
ambiguous effects first. Reconciliation requires current authorization and
proof that the old sessions have stopped. A journal receipt cannot establish
exactly-once execution across an external system; a start without a finish is
uncertainty, not a failure to repeat automatically.

Completed tool receipts must match the original call ID and tool name;
provider entries must match the original request ID. Recovery appends host
reconciliation evidence to the conversation without replacing its history or
adding a duplicate tool response, including when an unknown result was already
recorded before interruption.

## Embed a job host

Mount both components explicitly. Storage and authorization belong to your
application. This example uses private files and an offline provider:

```elixir
{:ok, _runtime} = Lemieux.Supervisor.start_link(name: MyApp.Agents)

factory = fn _job ->
  provider = Lemieux.Providers.Scripted.new([
    Lemieux.Providers.Scripted.complete("Finished offline")
  ])
  {:ok, [provider: provider, model: "test:model", tools: []]}
end

authorize = fn _action, _job, authority ->
  if authority == :current_owner, do: :ok, else: {:error, :unauthorized}
end

{:ok, jobs} = Lemieux.Jobs.start_link(
  supervisor: MyApp.Agents,
  journal: Lemieux.Jobs.Journal.Files.new("/private/job-state"),
  store: Lemieux.Store.JSONL.new("/private/transcripts"),
  factory: factory,
  authorize: authorize
)

{:ok, job} = Lemieux.Jobs.submit(jobs, %{
  "prompt" => "Inspect the fixture",
  "cwd" => File.cwd!(),
  "limits" => %{"max_requests" => 3}
}, :current_owner)

{:ok, snapshot} = Lemieux.Jobs.attach(jobs, job["id"], self(), :current_owner)
```

The factory runs during each preparation attempt. Reconstruct provider,
catalog, hooks and environment from current host policy. The manager fixes
the transcript identity, shared ledger, dispatch journal, subscriber and
workspace after assembly, so a factory cannot accidentally detach the job
from its accounting. Factory options may impose additional, tighter session
ceilings. Trusted host code must route auxiliary inference through
`Lemieux.JobBudget.run/4` and declare paid tool prices and actual charges.

The authorizer runs for `submit`, `run`, `dispatch`, `read`, `list`, `cancel`,
`recover`, `resolve` and `reconcile`. Return promptly and fail closed. Authority
is an in-memory host value; it is never restored from a record. Queued jobs
loaded at startup are offered to the current host with `nil` authority, so a
host that requires a fresh principal can refuse them and accept an explicit
recovery request instead.

`Lemieux.Jobs.Journal` specifies durable CAS writes, bounded prefix scans and
non-expiring owner locks. A database host can implement indexed scans and
transactions without adding a database dependency to the core. The filesystem
adapter scans job records at startup; an indexed host can implement the optional
`pending` callback to restore only nonterminal jobs as history grows. The filesystem
adapter syncs record contents and atomically replaces snapshots; its power-loss
guarantees depend on the filesystem's treatment of directory entries. Foreign
or unreachable lock owners are refused, rather than expired into split ownership.

Each dispatch receipt is a separate record; admission does not rewrite an
ever-growing transcript or effect list. Attach observers are bounded, and slow
observers are detached with a notice; they can read the durable snapshot and
reattach. Transports and recurring schedulers remain host choices.

`Lemieux.Execution` is the synchronous dispatch seam. Ordinary policy hooks
still allow, deny or rewrite calls before dispatch. `Lemieux.Session.continue/1`
requires the current host's explicit `recover_tools: true` opt-in after
reconciliation. Ordinary session resume keeps its existing lost-result behavior
and never automatically starts work. Neither adding the library nor mounting
its ordinary runtime starts a job worker.

The distinction between durable effects and recipe inputs is informed by
[Pi Durable](https://earendil.com/posts/pi-durable/) and
[Goose recipes](https://goose-docs.ai/docs/guides/recipes/session-recipes/).
The implementation keeps persistence, scheduling and transport at the host
boundary while retaining Lemieux's provider and transcript contracts.
