# Delegated investigations

A **subagent** is a separate, temporary session a parent session starts to
answer one question. Lemieux supports one deliberately narrow kind: a parent
may run one to three read-only investigators at a time, one level deep, over
an explicit snapshot of the work tree. Every child has a fresh context, a
separate transcript, read-only tools, a model/turn/time/cost budget, and a
structured result. The parent is the only writer and the only process that
decides what to do with the findings.

This is useful for independent repository searches, alternative explanations,
or a clean-context review. It is intentionally not a general agent team:
children cannot delegate, edit a checkout, run a shell, message each other,
stay in the background, or widen the authority the host chose.

In `lmx`, the model gets this as the `delegate` tool, with one definition by
default: the **repository scout**, which reads with `read`, `grep` and
`glob`. Each scout may spend up to $3, and all of a session's scouts together
up to $9; on a route `lmx` cannot price, the bounds are 480 requests a scout
and 2,880 for the session. `"scout_model"` in `~/.lmx/config.json` runs
scouts on a cheaper model than the parent's, and `--no-delegate` (or
`"delegate": false`, or `LMX_DELEGATE=0`) leaves the tool out. Measured on
read-heavy tasks, delegating cost several times the tokens of reading
directly and solved no more tasks ([Evaluation gate](#evaluation-gate)),
and the tool's description tells the model so.

The rest of this page is the contract for hosts that embed Lemieux.

## Mounting admission

`Lemieux.Supervisor` always mounts a provider limiter, a runtime-wide child
admission coordinator, and a dynamic supervisor for temporary groups. Defaults
permit three live children per root session and eight per mounted runtime:

```elixir
children = [
  {Lemieux.Supervisor,
   name: MyApp.Agents,
   subagents: [max_active_root: 3, max_active_runtime: 8],
   provider_limiter: [
     max_concurrency: 8,
     tokens_per_interval: 120_000,
     interval_ms: 60_000
   ]}
]
```

The provider limiter is shared by ordinary and delegated sessions in that
mount. `:tokens_per_interval` defaults to unlimited because Lemieux cannot
infer a provider account's real quota. A host using several mounts or several
credential pools should pass the same limiter pid and an explicit
`:provider_limit_key` to sessions sharing one rate domain. Admission waits in
the supervised provider task, never in the session `GenServer`; cancellation
therefore removes a queued call promptly.

The limiter bounds harness-side concurrency only. `req_llm` streams through
its own per-host connection pool, whose default is eight one-connection HTTP/1
pools — enough for a session on its own and not for a parent plus three
children, which is where concurrent streams start queueing behind one another
and dying at their deadlines.

Sizing that pool is the host's decision, made before mounting: a library
that restarted another application on mount would be deciding it on the
host's behalf. `Lemieux.ProviderPool.ensure/1` does it once per VM, never
touches a pool a host configured itself through `:req_llm`'s `:finch` key,
takes `max_concurrent_streams: n` for a host running many parents per
runtime, and `mode: :off` to decline. `lmx` calls it from
`Lemieux.CLI.configure/0`.

Every tree also needs a positive cost budget. Child definitions reserve their
maximum cost before any child starts, so an over-budget group fails atomically
— **before** any spawn intent is written, so a refused fan-out leaves no
record of children that never existed. The refusal itself is recorded as an
empty group result on the parent transcript, because the parent asked and the
answer was no.

Money is counted in integer micro-dollars (`Lemieux.Subagent.Money`).
Reservations round up, so a tree cannot drift past its cap over hundreds of
children, and unknown actual cost is charged at the reservation instead of
being treated as free. `Admission.snapshot/1` reports both micros and dollars,
and says how many children were never priced, because a total that includes
reservations for unmeasured work is an upper bound rather than a measurement.

### Deadlines compose, and are soft until the ceiling

A group has two hard clocks with a claim on it: its own `:timeout`, one hour
by default, and an optional host allowance passed as `:deadline_ms`. The
shorter wins, it is persisted in every spawn intent as
`effective_deadline_ms` with its `deadline_source`, and each child's hard
clock is clamped to what is left of it. A definition that declares an hour
gets thirty seconds if the group has thirty seconds left; nothing a definition
says can extend what authorized the group. The `delegate` tool passes the
deadline its own call was given, less the time a group needs to settle, so a
fan-out never outlives the tool call waiting for it.

Below that ceiling the clock is soft. Every `progress_interval` of its
definition (two minutes by default) a running child is **assessed** rather
than cancelled. `Lemieux.Progress` reads the entries the child appended since
its last check and settles the clear cases itself: half or more of the
interval's calls repeating an earlier call with the same answer is a stall,
and so is an interval with nothing appended and nothing in flight; a quiet
interval with a provider request or a tool call in flight is waiting, not
stuck. Distinct calls that may or may not be going anywhere are put to a
model, which is shown the objective, the clocks and the interval's calls and
asked for one word and a reason. A progressing child gets another interval.
A stalled one is cancelled as `:failed`, with `stalled: <reason>` in its
envelope's uncertainties and `stalled` as the reason in its own transcript.

The judge is the child's own provider and model unless the group's
`:progress` option names another (`provider:`, `model:`), one judge request
is bounded by `timeout_ms:` (a minute), and its usage is billed to the child.
A judge that fails, times out or answers unreadably lets the child continue,
with `by: "error"` on the event, because an unanswered question must not kill
a child that may be working. `assess: :activity` never asks a model,
`assess: false` arms no checks at all so the hard deadline is the only clock,
and a one-argument function is the host's own assessor. Each check is
published to the parent's subscribers as `child_assessed` and measured by
`[:lemieux, :subagent, :progress]`.

A wall clock alone cannot tell a stuck child from one streaming a long,
complete answer, and a short fixed deadline kills the second kind. What
bounds a runaway is the budgets and the repeat rules; the wall clock only
bounds waiting.

Every one of these clocks — the group's deadline, each child's checks and hard
deadline, the cancellation grace, the judge's timeout — is armed through a
`Lemieux.Clock` passed as `:clock` (the real clock when omitted). A host
testing its own deadlines passes a `Lemieux.Clock.Manual` and moves time with
`advance/3` instead of sleeping; `await_timer/3` waits until a timer is armed,
so the test neither polls nor races the machine's load.

## Define authority in the host

Definitions are ordinary data supplied by the host. The session and the
subagent runtime never scan a repository, home directory, plugin, or
frontmatter file for them; the shipped extensions described in
[the scout and workspace agents](#the-scout-and-workspace-agents) are a host
doing that on purpose.

```elixir
scout =
  Lemieux.Subagent.Definition.new(
    id: "repository-scout",
    description: "Trace relevant implementation and cite exact source locations",
    system_prompt: "Prefer primary source. Distinguish observations from inferences.",
    model: "anthropic:claude-sonnet-5",
    tools: [Lemieux.Tools.Read],
    max_cost_usd: 0.75
  )
```

A definition id is stable and human-readable; its persisted SHA-256 digest
covers every behavior-bearing field. `max_turns` (400), `timeout` (one hour,
the hard ceiling) and `progress_interval` (two minutes, the soft one) are
bounds a host chooses; the defaults are set where a child that is working
never meets them, because none of the three is what stops a stuck child. Every
configured tool must explicitly certify `Lemieux.Tool.read_only?/1`; a shell
command is never inferred to be safe from its text, and an advisory MCP
annotation is not sufficient authority.

The bundled `read` tool also lists one directory level, with file, directory,
and symlink markers. That small discovery surface matters for a repository
scout: read-only authority should not force it to guess paths it has no way to
enumerate, while a general shell would be much wider authority than it needs.

The default `Lemieux.Subagent.Result` contract asks the child for an answer,
sourced findings with confidence, content-addressed artifacts, uncertainties,
and searched/skipped coverage. A custom result module may be supplied as
`:result_schema` when it implements `schema/0` and `decode/1`; the runtime still
owns child identity, status, definition provenance, usage, and transcript id.
A claimed success cannot poison its siblings, and the runtime still owns the
status. What the child owns is the body, and that is read leniently; see
[The result envelope keeps what a child found](#the-result-envelope-keeps-what-a-child-found).

Children with tools receive the schema in their system prompt and the runtime
validates their final response. Lemieux does not also request provider-native
structured output for those turns: several providers implement it as a forced
synthetic tool, which would prevent the child from choosing `read` and would
bypass Lemieux's tool execution path. A tool-free child may still use the
provider-native output schema directly. Provider failures recorded in the
child transcript are preserved in the result's uncertainties.

### The scout and workspace agents

`Lemieux.Extensions.Delegation` — what `lmx` applies — builds the `delegate`
tool around one definition, the repository scout. The scout reads with `read`,
`grep` and `glob` (every one certified read-only), so it can search a tree
rather than walk it a directory at a time. It runs on the parent's model unless
`:scout_model` names another; a cheaper, faster model is the ordinary choice,
since the scout reads and reports and the parent does the reasoning that
matters. A child is bounded in dollars where its route can price a request,
and in requests where it cannot. The snapshot the scout is briefed on names
the repository's current commit (read without running anything the
repository configures; see [Checkpoints](tool-contracts.md#checkpoints)), or
`unversioned` where there is no commit to name.

When `Lemieux.Extensions.Workspace` ran first, the delegate tool also offers the
Claude-compatible subagent definitions it discovered — `.claude/agents/*.md`
from the person's home and from the repository (the repository's wins for the
same name), and a selected plugin's `agents/`, prefixed with the plugin's name.
Each keeps its own description and prompt. Each is still read-only: the tools a
file asks for that read (`Read`, `Grep`, `Glob`) are granted, and anything else
(`Bash`, `Edit`, …) is named in a startup notice rather than granted. A
definition whose `model` is a Lemieux `provider:model` runs on that model,
bounded in requests; Claude aliases (`sonnet`, `opus`, `haiku`) and `inherit`
mean the scout's model and budget.

## Give the model one bounded tool

The host builds one `delegate` tool from its definitions and passes it to the
parent in `:tools`, like any other tool. The snapshot and tree budget are
construction arguments, never model arguments:

```elixir
delegate =
  Lemieux.Subagent.Delegate.new([scout],
    snapshot: %{
      "kind" => "git",
      "revision" => current_commit,
      "workspace" => worktree_id
    },
    max_cost_usd: 2.25
  )

{:ok, parent} =
  Lemieux.start_session(
    supervisor: MyApp.Agents,
    provider: Lemieux.Providers.ReqLLM.new(),
    store: MyApp.AgentStore.new(tenant_id),
    model: "anthropic:claude-sonnet-5",
    tools: Lemieux.Tools.default() ++ [delegate]
  )

:ok = Lemieux.Session.prompt(parent, "Compare the three likely causes, then fix the best one")
```

Everything the host decides goes in at construction — the definitions, the
snapshot, the tree budget in dollars and optionally in requests
(`:max_requests`), and child options such as `:providers` or
`:child_options`. What only the session knows — its pid, id, supervisor and
root — the tool reads from its tool context when it runs, so the same struct
is good in any session it is handed to. `Lemieux.Subagent.Delegate` explains
why the session does not assemble this tool itself.

The model chooses a definition and writes a self-contained brief. The
`definition_id` field is a JSON-schema `enum` of the configured ids: as free
text it failed the first call in 13 of 30 experiment runs, each losing a turn
to `unknown_definition`. Every other field of the brief carries a description,
because a child receives the brief and nothing else — not the parent
conversation, not the reasoning that led to the call — and bare type
declarations left the model to invent plausible, generic objectives, which is
the expensive kind of wrong.

The tool description is also where the model is told *not* to delegate, and it
is the only place it is told anything about delegating: the default system
prompt says nothing, by design, and a workspace's instructions say nothing
unless somebody wrote it there. The description names when delegating pays
(separate questions that do not depend on each other's answers, or reading
wide enough to crowd out the work), says to read directly otherwise, and
carries the measured cost. The tool stays on by default in `lmx` — a session
that cannot delegate tells somebody who asked for a subagent that no such
tool exists, which is a worse answer than the cost — but the model is told
what it costs.

The model cannot choose a provider, model, credential, tool, budget,
filesystem scope, or snapshot. `delegate` is foreground work: the parent tool
task waits for an input-ordered, all-settled group result and then resumes
the normal agent loop. The rendered result is bounded before it enters parent
context; complete child transcripts remain in the store.

The tool holds functions and other runtime authority, so it is never recorded
and never restored: the session records module tools by name, and a struct
has none. A host passes it again when resuming. `lmx` re-equips a new
session with the scout and its workspace agents; a resumed session gets the
tool back only with `--delegate`. Authority beyond read-only remains an
explicit embedder decision.

## Calling the API directly

Hosts may delegate without giving the model the tool:

```elixir
task =
  Lemieux.Subagent.Task.new(
    objective: "Find every path that can mutate session provider state",
    non_goals: ["Do not propose or make edits"],
    expected_evidence: ["Exact module and function locations"],
    acceptance_criteria: ["Account for CLI and embedding entry points"],
    branch: "provider mutation",
    snapshot: %{"kind" => "git", "revision" => current_commit}
  )

request = Lemieux.Subagent.Request.new(scout, task)

{:ok, group} =
  Lemieux.Subagent.spawn_many(parent, [request], max_cost_usd: 0.75)

{:ok, [child]} = Lemieux.Subagent.children(group)
{:ok, snapshot} = Lemieux.Subagent.inspect(child)
snapshot.input["task"]          # the exact host-owned brief
snapshot.input["system_prompt"] # the effective child system prompt
snapshot.input["user_prompt"]   # the rendered fresh-context prompt
:ok = Lemieux.Subagent.steer(child, "Also inspect resume precedence")
{:ok, result} = Lemieux.Subagent.await(group, :infinity)
```

`spawn/4` is the one-child convenience. `cancel/2` accepts either a child or a
group ref and a reason, and the reason reaches the cancelled child's own
envelope. Children are cancelled concurrently rather than one behind another,
given a bounded grace interval (`:cancel_grace_ms`, five seconds by default) to
checkpoint their work, and terminated after it; `cancel/2` returns when the
last one is terminal or when that interval expires. Cancelling one child waits
for that child, not for its siblings.

Group results preserve request order even when children finish out of order,
and one timeout, cancellation, provider error, budget stop, or unstructured
answer does not discard successful siblings. Nor does a malformed provider:
one that a host's `:providers` map or `:provider_factory` hands a child and
that is not a `{module, state}` pair fails only that child, with
`{:start_failed, {:invalid_session_options, :provider}}` and never the
provider's value in its envelope. A factory that raises still takes the
whole group down.

### The result envelope keeps what a child found

A child's body is read leniently and labelled honestly. A fenced code block is
unwrapped before parsing; everything but `answer` defaults; an artifact or
evidence digest is optional, because a `read`-only child has no tool that
computes one. An answer that is not JSON at all is kept as the answer with
`format: :prose` and an uncertainty naming the schema error.

`format` is the part to read: a `:prose` envelope was never validated against
the schema, so its `answer` is an unstructured claim. That is different from
pretending the child complied, and different again from discarding what it
found, which a strict envelope would do to a child that read the right files
and answered in prose.

### Optional host authorization

The unforgeable control token in a ref remains the boundary. A host whose
contract distinguishes *inspecting* a child from *cancelling* it can pass
`authorize: fn action, context -> :ok | {:error, reason} end`, consulted after
the token on every control call. `Lemieux.Subagent.Group.authorized_actions/0`
is the closed vocabulary; the context carries ids only, never the brief or the
transcript. A callback that raises or answers anything else denies.

Inspection deliberately exposes the effective model input rather than only the
model-authored result. The parent transcript persists the JSON-shaped task on
the child's `subagent_spawn` entry; the child transcript persists its system,
user, and canonical request snapshots. The inspection view joins those safe,
provider-neutral records without exposing the live control token or provider
HTTP credentials.

Refs contain a live control capability as well as public transcript ids. Do
not serialize or disclose the control token. A pid or transcript id alone is
not authorization to steer or cancel work.

## Context and durability

A child receives four explicit layers and no arbitrary parent transcript:

1. the definition's role, model, read-only tools, and limits;
2. runtime lineage and inherited host policy;
3. the versioned snapshot and content-addressed references;
4. the task objective, non-goals, branch, evidence request, and acceptance
   criteria.

The parent transcript records `subagent_spawn`, `subagent_steer`,
`subagent_result`, and `subagent_group_result` entries. A child has a normal
session transcript under its own id. `Lemieux.Subagent.Replay.tree/2`
reconstructs lineage and distinguishes live-work crashes from terminal work
whose parent reconciliation was interrupted. `Lemieux.Subagent.Artifact`
rejects a file result after its recorded digest becomes stale.

Live subscribers receive nested events shaped as:

```elixir
{:lemieux, parent_id,
 {:subagent, [root_id, child_id], {:tool_call, call}}}

{:lemieux, parent_id,
 {:subagent, [root_id], {:group_finished, payload}}}
```

Lifecycle events cover group start/finish and child queue/start/progress,
steering, cancellation, and finish. They are observational only; durable
entries remain the replay source of truth.

Three `:telemetry` events measure the coordinator rather than the work:
`[:lemieux, :subagent, :admission, :start | :stop]` (how long a child waited
for a runtime slot), `[:lemieux, :subagent, :cancel, :start | :stop]` (how long
a cancellation took and how many children had to be terminated after the
grace), and `[:lemieux, :subagent, :group, :pressure]` (the coordinator's own
mailbox and memory). These are the measurements any wider tree would need
first. The terminal UI renders these as nested status and tool rows. Another
front end can use the transcript ids to open a child detail view without
changing the runtime protocol.

Every nested child `{:usage, usage}` contributes to the root TUI's per-prompt
request/token/cost summary and to the always-visible session total, request by
request as the children report it. The parent snapshot also folds each durable
`subagent_result` exactly once into direct, delegated and total usage; the
group result repeats child usage and is deliberately not counted again —
`Lemieux.Context.delegated_usages/1` is the one selector both the snapshot and
the context accounting use, so that rule cannot drift apart. Parent
`spent_usd` remains direct for its established budget, while
`inclusive_spent_usd` is the amount a person watching the whole run paid.

A cancellation is accounted for like any other ending. Each child's result
envelope is written whatever stopped it, appending one to the parent publishes
the parent's position again, and the cancel itself publishes it too — so the
tokens a cancelled fan-out burned reach the status line instead of staying on
the transcript where nobody looks.

The terminal UI draws one row per child — name, status, brief, and the call it is
making now indented underneath — and increments a repeat count for the same
tool and target. The full child transcript still records every call;
coalescing prevents a struggling scout from replacing useful parent scrollback
with dozens of indistinguishable `read` rows. `child_queued` carries the
definition id and the objective alongside the child id so that row can be
drawn without reading the parent's transcript back for facts the coordinator
had in hand.

A child's session is an ordinary session in the parent's store, which is what
makes `lmx log` and replay work on one without a second mechanism. It also
means a session picker would offer it: `Lemieux.Transcript.delegated?/2`
answers that question from the child's own result envelope, and
`Lemieux.CLI.SessionIndex` leaves delegated transcripts out of what `/resume`
offers. Out of the offer and nothing else — resuming a child by id still
works, which is how you go and read what one actually did.

## Limits and expansion seams

Delegation is fixed at depth one, the model's fan-out defaults to three, and
the API enforces a hard ceiling of four. The group's hard deadline defaults
to one hour and its children are assessed every two minutes, each standard
answer is limited to 32 KiB, and the parent insertion is bounded by the
call's `tool_output_bytes` (120,000 by default): a group result over that
budget shortens its longest answers first, each with a note and a pointer to
the child transcript, and is always a complete JSON document. Duplicate live
work over the same definition, brief, and snapshot is rejected. Parent
cancellation propagates to the foreground group, and monitored leases and
admission reservations are released after crashes. When a finished parent
goes away, the group stops with `{:shutdown, {:parent_down, reason}}` rather
than a logged crash.

The types deliberately keep role definition, task brief, topology, admission,
result schema, provider rate domain, and presentation separate. That leaves
room for verifier roles, deterministic pipelines, richer artifact stores,
external definition authoring, and new front ends without silently enabling
recursive delegates, writers, sibling messaging, or distributed ownership.
Those broader patterns wait until the narrow facility clears the
[evaluation gate](#evaluation-gate).

## Host-selected context and acceptance

A fresh child can receive a bounded, source-attributed evidence packet without
inheriting the parent's entire conversation or authority:

```elixir
{:ok, packet} = Lemieux.Subagent.Context.select(parent_id, entries, selected_entry_ids)
task = Lemieux.Subagent.Task.new(
  objective: "Inspect cancellation", snapshot: snapshot, context: packet,
  acceptance_criteria: ["Source identifies the cancellation owner"]
)
```

Packets reject missing IDs, duplicate IDs, altered payload digests and more than
32 KiB. The host chooses entries and excludes secrets. `Delegate.new/2` also
accepts `context: packet`; the model cannot replace it through tool arguments.
Packet content participates in the task digest and is retained in spawn facts.

After awaiting the child, a host can assess evidence independently of execution
status and output format:

```elixir
assessed = Lemieux.Subagent.Acceptance.assess(result, task, %{
  "Source identifies the cancellation owner" => fn result ->
    MyChecks.cancellation_owner(result) # {:pass, [evidence_ref]} or {:fail, reason}
  end
})
```

The assessment is passed, failed or unverified and binds the brief, snapshot and
result digests. Missing/invalid/crashing checks stay unverified; findings survive
failed checks. This returns a new envelope for the host to retain as a separate
artifact, without rewriting the original result. Model-backed checks must run
through bounded sessions with their usage included in the host's budget.

## Evaluation gate

Delegation has not shown that it makes the parent better, and a working child
lifecycle is not evidence that it does. The measurement so far: on the thirty
read-heavy cases of `eval/corpus/investigators-v1`, run on two models, the
parent alone and the parent with `delegate` both solved 30 of 30, and
delegation spent 4.6 to 5.1 times the tokens. That is why the tool's
description tells the model the cost.

Wider delegation waits on this gate: compared with the same parent alone,
under matched models and total allowances, one to three read-only
investigators must give at least **15 percentage points** more grounded
correctness or recall, or **30% less wall time at equal quality**, with at
most **3× total tokens**, **zero unauthorized writes**, and critical child
facts lost in **fewer than 5% of runs**. A pattern that misses the gate is a
reason to reconsider it, not to relax the threshold.

The experiment is `examples/experiments/investigators.exs`, run through the
experimental `mix lemieux.extension.eval` task. Every attempt is a live,
billed or quota-consuming call, so it requires the model to be named and
picks none for you:

```sh
LMX_INVESTIGATORS_MODEL=anthropic:claude-sonnet-5 \
  mise exec -- mix lemieux.extension.eval examples/experiments/investigators.exs --allow-live
```

`examples/experiments/delegate_budget.exs`, which measures whether a child
finishes inside the budget it is given, likewise requires
`LMX_DELEGATE_BUDGET_MODEL`. [Evaluation gates](evaluations.md) describes
the method.

Recursive delegates, sibling negotiation, consensus voting, parallel writers
and distributed or background peers are outside the current scope.
Long-lived or remote workers use separate top-level sessions or the
[A2A](a2a.md) boundary. The [roadmap](roadmap.md) lists the open directions.
