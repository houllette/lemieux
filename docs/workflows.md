# Plans, goals and checkpointed workflows

These optional extensions and composition helpers run on ordinary Lemieux
sessions:

- a **plan** (the `todo` tool) tracks the work the model reports;
- **verify after changes** runs the project's own check when a turn edited
  files;
- a **goal** is completion a host verifies with its own checks;
- **checkpointed composition** (experimental) runs an explicit multi-stage
  agent written in Elixir.

They keep their state in the session's transcript, as small JSON documents
called session documents (`Lemieux.Session.document/2`), so it survives
resume. These documents are not the file checkpoints `/undo` uses
([Checkpoints](tool-contracts.md#checkpoints)). None of them is a durable
cross-session scheduler.

## Session plans

The plan extension, `Lemieux.Extensions.Planning`, adds the `todo` tool and
supplies the latest plan to each prepared request. `lmx` applies it to every
new session; `"disabled_extensions": ["planning"]` leaves it out, and the
terminal UI draws the plan above the input while a task is open. A library
host opts in through `Harness.assemble/2`, with `planning: true` in
`Lemieux.Extensions.coding/3`, or by calling `Planning.apply(harness, [])`.

The tool's description tells the model to finish the plan's tasks before
ending its turn, unless the person asked it to stop sooner, because a plan with
open tasks says the work is not done; [Continue unfinished
work](#continue-unfinished-work) acts on the same signal.

The ordinary way to keep a plan is `set`: the model sends the whole list, each
task a title and a status (`pending`, `in_progress` or `completed`), whenever it
changes. It needs no revision — `Planning.set/2` reads the current one and
retries once if another write landed in between. Restated titles keep their
task IDs (or name an `id` to rename one), and tasks left out of the list are
gone from the plan; earlier revisions remain in the transcript.

`todo` also supports `list`, `create`, `update`, `reopen`, and `delete` for
single-task changes. Those mutations require the revision returned by `list`;
a conflict requires reading again. Tasks have stable session-local IDs, a title,
status, optional owner, dependency IDs and evidence references. References and
completed status are reports, not proof. Owners grant no execution authority.
Completed tasks must be reopened with a reason before editing. Reopen downstream
completed tasks first; remove dependency references before deleting a
prerequisite. A `set` keeps recorded dependencies that still hold and releases
those the model reports past.

`todo` calls share a wave with other tools and take turns only with each other.
A host renders the plan from the session's `{:entry, entry}` events: an
`:extension_state` entry whose payload namespace is `"lemieux.plan"` carries the
revision and the plan, and `Planning.tasks/1` gives the visible task list.

There are at most 64 tasks, including tombstones, in a bounded session document.
Every mutation is persisted before success, independently of tool-output limits.
No-op updates leave the revision unchanged. Compaction retains the authoritative
transcript; the next request receives only the current plan summary. Resume
restores state, and fork copies its historical value without a shared writer.
Reapply the extension on resume to restore its preparation hook.

`Session.document/2` and `Session.put_document/4` give any extension a
namespaced session document of its own. They serialize compare-and-swap
writes and enforce a 64 KiB bound; what the document means is the
extension's business. The entry type uses transcript schema 4 so older
binaries refuse to lose it silently. This is not a cross-session work queue
or issue database; those belong to hosts.

## Continue unfinished work

A response that calls no tool ends the prompt. On a long task a model often
stops before it is done — it reports progress, says what it will do next, or
asks whether to go on — and the session then waits for somebody to type
"continue". `Lemieux.Extensions.Continuation` is the `/goal`-style answer that
needs no command: the objective is the plan the model already keeps.

At an ordinary stop it sends the model back, with a message starting
`[lmx continue]` that lists what is open, when the plan has tasks still
`pending` or `in_progress` **and** the model wrote that plan during this
prompt (a plan left from an earlier task is not what a later question is
about). The model can decline: an answer that calls no tool is taken as its
decision — the person asked it to stop there, or it is blocked or needs
something only the person can give — and ends the prompt. The message names
the person's own "stop here" first, since the hook reads the plan and cannot
see the prompt. Per prompt it sends the model back at most `:max_continuations`
times (default 5).

A response cut off at the output-token limit (`:length`) with no tool call is
picked up too: a message starting `[lmx output limit]` says what happened and
asks for smaller pieces, at most `:max_output_continuations` times (default 3).
A second cut-off with nothing done in between ends the prompt `:length`, and
`lmx` says so. A cut-off inside a tool call, typically a large file write, is
the loop's rather than this extension's: the call the limit cut short is
answered without running, telling the model to split the work into smaller
calls ([Tool contracts](tool-contracts.md)), and the turn goes on.

With `:completion_check` (off by default; `"continuation":
{"completion_check": true}` in `lmx`), the first ordinary stop of a prompt in
which the model called a tool, with no plan of its own left open, gets one
more message, starting `[lmx requirements]`: list the request's explicit
requirements (names, paths, field names and types, formats, sizes and limits,
the person's exact commands), check each against the machine, and fix what
does not match or say it all does. It is asked once per prompt, so it costs
one request when nothing is wrong. It catches work checked against the
model's own reading of the task, such as a field named `val` where the task
said `value`, or a file over a stated size it never measured; it cannot make
a genuinely ambiguous requirement come out the way the person meant.

None of these applies to an aside, whose veto would end it as
`:hook_failed`. Every message is recorded as stop-hook feedback
(`"stop_hook" => true`), so the counts are read back from the transcript and
survive resume, and the terminal UI draws them as the harness speaking. `lmx` applies it to every session it
equips; `"continuation": false` or `"disabled_extensions": ["continuation"]`
leaves it out. A library host passes `continuation: true` (or its options) to
`Lemieux.Extensions.coding/3`, which places it ahead of `verify`: the first stop
hook to deny wins, so a model sent back to its plan is not checked on half-done
work, and the check runs once the plan is finished.

## Verify after changes

`Lemieux.Extensions.Verify` runs the project's own check after a turn that edited
files and, when it fails, gives the model a bounded number of chances to fix what
the check reports. `lmx` applies it whenever it has a personal state directory
(`"verify": false` turns it off, `"verify": {"command": …}` names the command,
and `/verify off` pauses it for a session). A library host opts in with
`verify: true` (or its options) in `Lemieux.Extensions.coding/3`, or applies
`{Lemieux.Extensions.Verify, opts}`.

The check runs at an ordinary stop when a `write`, `edit` or `apply_patch` call
succeeded since the person's prompt or the last check — another stop hook's
message is not a prompt, so edits before it still count — unless the model itself
ran exactly that command and saw it pass after its last edit. The command is
`:command`, or found from the repository's conventions: `tests/run.sh`, a
`Makefile` `test` or `check` target, then `mix test`, the `package.json` test
script (run with the lockfile's package manager), `cargo test`, `go test ./...`,
pytest configuration, Gradle and Maven. No convention means no check. A failure
comes back to the model as a message starting `[lmx verify]` with the command,
how it ended and the end of its output, and says the model may stop without
further changes when a failure predates it. Nothing further is checked until
the model edits again.

Options: `:command`, `:max_continuations` (default 2), `:timeout_ms` (default
five minutes), `:max_output_bytes`, `:excerpt_bytes`, `:editing_tools`,
`:enabled`, `:environment`, `:cwd` and `:checkpoints` (below).
`Verify.set_enabled(session, boolean)` toggles it for the rest of a session
(what `/verify` does), and `Verify.status/1` reports the toggle and the last
result. Both live in the `"lemieux.verify"` session document, so they
survive resume. A command that cannot run at all — not installed, exit
status 126 or 127 — is not reported to the model. Edits made only through
`bash` do not trigger a check unless `"bash"` is added to `:editing_tools`.

The check is a command the repository chose — `make test` is whatever the
checkout says it is — so it goes through the session's permission policy as
the `bash` call that would run it, with the `bash` tool's descriptor:

- with no policy, which is `lmx`'s default, it runs without asking;
- in `ask` or `accept_edits` mode the approval card shows the command, an
  allow rule such as `Bash(make test)` lets it run unasked, and a `Bash` deny
  rule refuses it;
- with nobody to ask (`lmx run`, or `non_interactive: :deny`), a check that
  would ask is refused;
- a hook that rewrites the command runs the rewritten one.

A refused check is not a failure: nothing ran, so the turn ends as it would
have, and `/verify` shows the refusal as the last result.

A check can change files too: a formatter it runs, fixtures it regenerates.
Given `:checkpoints`, the directory `Lemieux.Extensions.Checkpoints` records
into, the check is recorded with the turn whose edits it checked, so an undo
of that turn takes back what the check changed along with the edits, as far
as it would for a command ([Checkpoints](tool-contracts.md#checkpoints)).
Outside a git repository, undo names the check among what it did not
reverse. `lmx` passes the directory whenever it records checkpoints. Without
`:checkpoints`, undo puts back the model's edits and says nothing about the
check's.

## Verified goals

`Lemieux.Extensions.Goal` is optional. The host authorizes each objective and
supplies executable evidence checks. The model gets `get_goal` and `update_goal`,
which can request verification or report a blocker, but cannot create an
objective or enlarge its allowance.

```elixir
harness = Lemieux.Extensions.Goal.apply(harness,
  policy_id: "release-checks-v1",
  checks: %{"tests" => &MyHost.check_test_receipt/1},
  snapshot: &MyHost.workspace_snapshot/1,
  max_requests: 20,
  max_continuations: 2
)
# Start the ordinary session with this harness, then explicitly authorize:
{:ok, _} = Lemieux.Extensions.Goal.create(session, 0, "Deliver the fix", ["tests"])
```

A snapshot callback receives the ordinary hook/tool context and returns
`{:ok, nonempty_json_map}` identifying the actual execution environment. Each
check receives `%{goal: goal, snapshot: snapshot, context: context}` and returns
`{:pass, [evidence_reference]}` or `{:fail, reason}`. Hosts should validate durable
receipts against the supplied snapshot; the model's assertion is not evidence.
Version `policy_id` when checks or their interpretation change.

Verification records a durable intent before running callbacks, then commits
against its revision. It records criteria, evidence references, policy ID,
goal revision and snapshot digest. Snapshots must match before and after all
checks. Missing checks, exceptions, malformed results, timeouts or snapshot drift
leave the goal `unverified`. Deterministic checks run under the mounted task
supervisor, with a bounded deadline (`verify_timeout_ms`, default 5000).

The optional `reviewer` map contains a certified read-only Subagent.Definition,
`options` including the tree cost cap, `timeout_ms`, and `accept` callback. The
definition must have a request bound. Review runs only after deterministic checks
pass. Its child transcript and usage flow through ordinary parent delegation
accounting, including failed review. A reviewer is additional evidence, not a
replacement for deterministic checks. See `Lemieux.Extensions.Goal.Verification`.

An ordinary model stop invokes verification. An unverified goal may continue
only within `max_continuations` (default **zero**) and the session's clamped
request limit. Error, cancellation and budget stops do not continue. A reported
blocker stops continuation but does not count as completion. Used continuations
survive resume; reapply executable host policy on resume. After interrupted
verification, `recover(session, observed_revision)` is an explicit host decision
to permit another check. Never automatically retry uncertain external effects
inside a verifier.

Completion describes the checked snapshot. Later workspace edits require a new
assessment/objective; a historical completed record is not evidence for changed
files. A terminal goal may be replaced through `create/4` at its observed revision.
All state is session-local, kept in a session document.

## Checkpointed composition

**Experimental.** `Lemieux.Agent` and its `Agent.Session`,
`Agent.Checkpoint` and `Agent.Composition` modules may change in any 0.x
release.

Keep orchestration in an ordinary `c:Lemieux.Agent.run/2` implementation: Elixir
functions and `with` expressions choose branches and pass artifacts between
bounded stages. `Agent.Checkpoint` adds persistence; `Agent.Composition` adds
bounded parallel execution and usage aggregation. There is no workflow DSL,
implicit scheduler or new application process.

```elixir
alias Lemieux.Agent.{Checkpoint, Composition}

{:ok, run} = Checkpoint.open(journal_session, "investigate-v1", %{
  "workflow_digest" => workflow_digest,
  "configuration_digest" => configuration_digest,
  "policy_digest" => policy_digest
})

inputs = %{
  "workspace_snapshot" => immutable_snapshot,
  "upstream_artifacts" => %{"brief" => brief_sha256}
}

Checkpoint.step(run, "investigate", inputs, fn ->
  Composition.session(%{prompt: brief, cwd: workspace, timeout_ms: 30_000},
    supervisor: runtime, store: store, provider: provider, model: model,
    session_options: [tools: read_only_tools, max_requests: 4])
end, validate: &MyHost.validate_saved_artifacts/1)
```

The journal is an ordinary host-mounted session using the host's store. Executable
callbacks, providers, credentials and sandbox policy are never restored from its
transcript. Reopen with identical code/configuration/policy identity on resume.
Each step binds its workspace snapshot and upstream artifact digests. These must
represent real host-verified inputs, not model-authored labels. A changed identity
requires a new run or step key. Fork requires a new run ID, so approval and execution
authority do not transfer with copied transcript evidence.

A step records `in_doubt` before executing. Success stores bounded JSON output;
an ordinary error stores failure and any observation. Interruption or invalid
output leaves uncertainty. Calling the step again never repeats uncertain or
failed effects. The host must reconcile external receipts and stop the original
worker before using `resolve/5` or `retry/4`. Each decision is revision checked
and recorded; retries retain prior attempts and allow at most eight executions per step.

Cached output requires a successful explicit `validate` callback. Matching an
input digest does not prove a previous file edit still exists. Validate artifact
hashes and external receipts against the environment where the result will be
used. Invalid cached output produces an error rather than rerunning paid work.

For a consequential step, pass `approval: true`. Execution returns
`{:suspended, %{key: key, revision: revision, digest: digest}}`. Present that exact
artifact/input identity for review. Host `approve(run, key, revision, reason)`
marks it ready; repeating the same step then executes. Stale approval cannot
authorize changed work. Approval is never inferred from elapsed time.

`Composition.parallel(runtime, items, fun, max_concurrency: 3, timeout: 30_000)`
returns ordered all-settled outcomes. At most 64 items and eight workers are
allowed. Use distinct checkpoint keys and host-provided isolated workspaces for
independent writers. The host owns the finite stage list and total allowance;
request limits on individual stages do not create a shared cost reservation.

`Composition.session/2` requires a stage request ceiling and uses the existing
Agent.Session runner. It retains the transcript session ID while leaving the
full transcript in the configured store. Keep large artifacts in host storage
and checkpoint references/digests; the checkpoint limit is 64 KiB. Outputs too
large to commit remain uncertain and require reconciliation.

`Composition.usage(run, keys)` sums all recorded attempts, including failed and
retried model work. Supply every executed key. Uncertain or unmeasured attempts
keep aggregate cost unknown; deterministic stages may explicitly report zero
usage. This is accounting evidence, not automatic budget admission.
