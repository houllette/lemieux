# Qualifying learning before release

The [2026-10-20 hosted pilot](qualification/2026-10-20-default-learning/README.md)
records separate GPT-6 subscription scopes, stock-path reuse, five-arm outcomes,
complete usage projections and the remaining qualification work. It preserves
the superseded pilot and an interrupted intent separately.

Lemieux's learning APIs remain experimental and opt-in. The qualification host in
`Lemieux.CLI.Learning.QualificationHost` is an explicit development harness; ordinary
`lmx` starts none of it. It exercises the ordinary CLI assembly, capture, source-backed
lessons, exposure-gated retrieval, the first-party proposer, isolated refinement,
host-approved task-local promotion, execution and exact undo. A passing task is
task-local evidence. It does not qualify default-on learning or transfer to another
model or task family.

Run the offline protocol rehearsal with a locally cached Docker image:

```sh
mix run scripts/qualify_learning.exs --variants 1 --repetitions 2 --output tmp/learning-offline
```

It uses `Lemieux.Providers.Scripted`, makes no hosted request, and checks mechanics.
Its answers deliberately make no quality claim. Docker is an optional qualification
dependency, not a library dependency. The runner freezes a local immutable Python
image and never pulls an image implicitly. Container lifecycle checks run separately:

```sh
LEMIEUX_TEST_CONTAINERS=1 mix test test/lemieux/cli/learning/container_test.exs
```

Only after explicit authorization to use the local Codex subscription, run:

```sh
mix run scripts/qualify_learning.exs --allow-live --variants 2 --repetitions 2 --output tmp/learning-live
```

The live route is `openai_codex:gpt-6.1-sol`, with medium reasoning effort in task,
proposer and probe sessions. Credentials stay in the host. The access-only loan from
the local Codex sign-in is private and removed on exit; the runner neither copies
nor consumes its refresh token. The subscription route is quota-funded: any provider
USD estimate is informational, not a claim of API billing.

Use `--model openai_codex:gpt-6-luna --effort low` to freeze another explicitly
authorized subscription model/effort pair. Each pair needs a separate fresh
output directory and report; do not pool different model or effort scopes.
Non-subscription routes are refused by this runner. Reports include direct
frozen/updating comparisons with the equal-budget retry control and updating
versus frozen experience, as well as the ordinary disabled comparison.
The runners disable SDK transport retries (`max_retries: 0`) and freeze that
setting in the plan. Only session/controller retries may create another call,
so a failed transport cannot silently add attempts below the dispatch counter.

`scripts/qualify_learning_stream.exs` supplements that protocol with the actual
stock ordinary-use experience lane. It runs paired disabled/default streams in
fixed workspace identities, through shared CLI assembly and the real private
lesson store, with no learning hook, campaign or prompt injection supplied by
the evaluator. Each task has 32 request slots and an eight-minute deadline;
learning creates zero additional requests. The same networkless container and
independent host grader apply. Its plan is written before dispatch, and every
episode retains intent, transcript, usage, grading, learning status and digest.
It reports whether subsequent tasks actually received experience. This is
development mechanics/non-regression evidence, not an independent benefit claim.
Use the same model/effort/output switches and explicit `--allow-live` boundary;
without that flag it uses only Scripted.

The protocol writes a fixed warmup plan before collecting two seed tasks, then
freezes their actual retained library, target source digests, model, effort, runtime,
task order, clusters, repetitions, allowance and stopping rule before the target
sample. It refuses an existing output directory. It checkpoints each episode's
intent before effects and completion afterwards. Interrupted episodes require
explicit inspection; there is no automatic replay or quiet sample reduction.

Five arms receive the same outer per-task allowance: 160 request slots, three million
tokens and 2,000,000 ms, with no dollar cap for subscription quota. The arms are:

| Arm | Behavior |
| --- | --- |
| Disabled | Ordinary task execution, no lesson exposure or refinement |
| Retrieval | Ordinary execution with bounded, explicitly untrusted seed observations |
| Retry | Up to three fresh ordinary attempts, stopping on verified success |
| Frozen | Task-local refinement using the frozen seed inventory |
| Updating | The same refinement, additionally allowing lessons from earlier tasks in that arm and repetition |

Refinement preregisters two fresh controls, at most one real proposer candidate,
two candidate probes and two composition probes if supported. The complete
experiment reserves inside the same job controller. Its 112 request slots are
admission reservations; reports distinguish those slots from recorded physical
dispatches. A request has a 180-second host deadline and a conservative token bound.
All failed, retried and learning work counts. Original output and assessment remain
available, and a weaker final result retains the original. Safety failures in any
probe remain failures even when a different answer is selected.

All shell commands execute as a non-root user in a networkless container with only
one workspace mounted, no host home, credentials, Docker socket, graders or other
arms. It has a read-only root, memory/CPU/PID limits and a bounded temporary directory.
Each command gets a fresh container. File tools use confined paths. The caller's
death removes the owned container and its descendants. These limits are not a total
host disk quota or a production multi-tenant isolation certification.

The host grader keeps expected cases outside model-visible workspaces, checks public
runner/test/contract files have not changed, and evaluates output independently.
Path-validation and quoted-record fixtures include malformed inputs, traversal,
Unicode, empty fields and quote edge cases. Variants belong to their original task
family cluster; additional runs of related cases do not create independent samples.

A host verifier may reject an answer after the agent reports completion and its
own checks pass. `Lemieux.Extensions.Capture` observes in-session signals; it does
not automatically receive that later verdict. Persist authorized external feedback
as source-backed experience with its actual case identity. A failed source outcome
can warrant investigation while its lesson remains unconfirmed. It establishes
neither an improvement nor permission to apply an adaptation.

For a direct `Lemieux.Learning.Proposer.propose/3` call, supply typed development
evaluations, matching retained transcript artifact bytes and a
`Lemieux.Learning.Discovery.Digest.build/4` result. Select primary excerpts through
`context.evidence["evaluation_ids"]`, using `Evaluation.id`; case and session ids
are different identities. An arbitrary operator observation does not populate the
failure digest or transcript directory. Keep feedback from independent confirmation
outside development proposals, and retain the source-case ancestry of reused lessons.

Validate model-facing evidence through the tools the proposer actually receives.
The read tool clips individual long lines, so compact JSON can hide the decisive
fields even when the file was materialized successfully. Generated proposal and
experience manifests put collection members on separate lines. Proposal evidence
views additionally represent long strings as `$text` objects with encoding
`utf8_chunks/v1`, ordered `chunks`, and the projected string's `bytes` and `sha256`.
Concatenate the chunks without separators to recover the projected string; each chunk is bounded
by its escaped JSON byte size so it remains readable through the tool. Upstream
clipping and omissions still apply. Embedders can use
`Lemieux.JSON.encode_readable!(value, strings: :chunks)` for the same display view.
Keep canonical contract digests and exact source artifact bytes separately;
plans and parent profiles retain their original JSON value shapes. A display
projection is untrusted evidence, never activation authority. A model's abstention
is not evidence of insufficient source information when its tools could not
present that information.

Use `Proposer.profile(model, task_local: true, abstain: true)` for a task-local
proposal. A concrete current failure may support a hypothesis for isolated probes;
cross-case evidence is required for transfer claims. Candidates remain subject to
the frozen surface; the effective CLI lane requires preserving the original system
prefix. A proposal still needs the host's matched
controls, candidate probes, executed composition and fresh promotion authority.

A retryable provider failure can lack a terminal usage report. The controller then
refuses further calls with `usage_unknown`, including the session's ordinary retry.
Quota mode does not waive unknown-token accounting. Retain the original result and
the in-doubt checkpoint; explicit host reconciliation needs trustworthy usage facts.
Do not replace unknown usage with zero or replay the experiment automatically.
Whole-experiment admission preserves the same underlying stop/skip reason rather
than reporting every refusal as unaffordable. Distinguish `usage_unknown`,
`untracked_parent_usage`, invalid allocations, exhausted allowances and
`experiment_deadline_exceeded` before choosing recovery. Outer-ledger refusals
also retain their data-only `cause` with kind, spent, estimate and cap. Admission
inspection still reserves nothing and authorizes no child dispatch.
The qualification host records this incomplete learning path without discarding the
ordinary answer. Its row sets `qualification_complete: false`, so finishing the task
does not qualify an incomplete experiment as passed execution or demonstrated benefit.

Prefer the original result on equal verifier scores. A promoted request that fails
before producing output can tie an earlier partial result at zero; selecting the
newer result would discard useful work without establishing an improvement. Exact
runtime undo and result selection are separate responsibilities of the host.

Quality and safety lead the decision. Requests, tokens, latency percentiles and
unknown accounting are reported separately. Extra tokens are not an automatic
disqualifier. A benefit claim requires complete accounting, no safety failure,
no paired regression and a positive conservative paired-cluster interval, with a
Bonferroni correction across all seven preregistered contrasts. Refinement must
beat both the disabled arm and the equal-budget retry arm without regressions.
Small samples or a perfect baseline
remain inconclusive. The script labels all results development qualification.
Independent confirmation still needs fresh, unexposed tasks and any claimed model
scope; a development rerun cannot satisfy that requirement.

`Host.inspect/1` is provider-free; `Host.opt_out/1` persists an opt-out checked before
retrieval, refinement, retention and promotion. Tests also cover caller death inside
session initialization, source drift, revoked authority during installation,
missing or tampered runtime evidence and rollback after the canary history fills.

`Lemieux.CLI.Learning.Installation` is a reference process-crash protocol for a host
that owns an external runtime pointer. Its tests interrupt after intent, after
installation and after commit, then require fresh host authority and exact prior
pointer restoration before serving. Failed or unknown restoration remains blocked.
The journal contains version references and audit data, never executable harnesses
or serialized authority. It assumes one host serializes operations, and file sync
plus rename does not establish power-loss durability. `Promotion.Memory` remains
in-memory; this rehearsal does not turn it into a durable deployment host.

The broader default-on integration in issue #78 and independent qualification in
issue #79 remain release gates. Shared editable assets (#80), exports (#81), durable
production installation and default promotion are not enabled by this runner.
