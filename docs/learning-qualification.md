# Qualifying learning before release

## Whole-record research sequence

`--research` selects a separate experimental protocol. It does not change the
strict ordinary refinement policy or grant persistent activation. Freeze the
executor and editor separately: for example, GPT-6 Luna/low executes every task
and probe while GPT-6 Sol/high proposes and reflects. Reflection receives the
whole public task/probe record, including unsuccessful and rejected experiments.
Its positive, negative and uncertain lessons retain source pointers and remain
unconfirmed. One metered structural repair may correct malformed reflection;
it cannot retry an experiment or select a better outcome.

The research search reviews successful as well as failed tasks, proposes general
and domain changes, and probes their composition. `experimental_mean/v2` admits
repeated mean gains or repeated fully verified ties for **task-local research**.
A tie is a search choice, never evidence of improvement. Strict dominance and
fresh host authority remain required by the existing persistent policy.

The `whole_record_research/v3` protocol defines success as the independently
verified file outcome for every arm. With complete, matching usage and transcript
evidence, reaching the task turn limit does not erase a passing artifact grade
only for refinement. Earlier protocols did erase it for probes while ordinary
arms retained credit for the same files. Budget stops remain explicit in probe
records and the report's `budget_stops` views; artifact success does not imply
that the agent completed its final report. Provider failures, cancellations,
timeouts and unknown usage still refuse complete qualification. The ordinary
refinement default continues to require a completed task. Historical plans and
results retain their original scoring rules.

Version 4 adds `no_experience`: the same improver, probes and retention work with
all earlier experience withheld from every subsequent proposal. Frozen,
updating and withheld arms share the same per-episode allowance. Retrieval-only,
disabled and equal-allowance retry controls remain. Related variants and repeated
executions still count as one independent stream.

First rehearse offline, then run a fresh hosted mechanism canary after explicit
authorization. These examples use separate output directories; never reuse or
quietly replay an incomplete intent:

```sh
mix run scripts/qualify_learning_study.exs --research --stage mechanism \
  --output tmp/research-offline
mix run scripts/qualify_learning_study.exs --research --stage mechanism --allow-live \
  --model openai_codex:gpt-6-luna --effort low \
  --editor-model openai_codex:gpt-6-sol --editor-effort high \
  --output tmp/research-mechanism
mix run scripts/qualify_learning_study.exs --research --stage development --allow-live \
  --model openai_codex:gpt-6-luna --effort low \
  --editor-model openai_codex:gpt-6-sol --editor-effort high \
  --mechanism tmp/research-mechanism/mechanism.json \
  --output tmp/research-development
```

The canary collects one seed task and executes one later task in six arms, twice.
`mechanism.json` audits retained lessons, proposer exposure, a changed effective
runtime, actual changed actions and the experience-withheld control. A larger
hosted research run requires a passing receipt for the same source revision,
models, efforts, inference route and research policy. An offline receipt cannot
unlock hosted work. This is observed dataflow, not causal efficacy.

`--assets` additionally searches one procedure tree and one allowlisted shipped
setting. `--assets --asset-only` isolates that lane. Before review, an invalid
draft may receive one tool-less, metered structural repair against the actual
loader. The original answer is preserved; the repair receives no probe feedback
and may not invent a different hypothesis or add components. A second invalid
draft is rejected. This format repair is part of the frozen asset protocol and
request allowance. Exact bytes receive a separate
model review and fresh host digest approval before isolated probes. The actual
skill loader, asset identities and request catalogues are verified. A personal
research policy can admit UTF-8 `.py` files under `helpers/`; the loader never
imports or executes them. The task must read and execute them through its normal
confined tools. The canary requires observed procedure loading, helper execution
and changed tool visibility before that asset policy can enter a larger study.
Repository assets and default selection gain no such permission. These reviewed
experiments do not qualify native exports or general automatic helper execution.

Research task horizons support 8–200 requests. The frozen allowance funds each
complete profile/asset experiment, originals, final executions and reflection;
token and deadline bounds scale with the horizon. Retry receives the same full
outer allowance. Reservations and actual physical dispatches are reported
separately, and all unsuccessful search, review, acquisition and reflection work
counts. A larger allowance is an upper bound, not a commitment to consume it.

Whole-record reflection admits at most 1 MiB of complete public source bytes;
the lesson wire limit remains 2 MiB and retrieval's total disclosure remains
2 MiB. Oversized records refuse retention rather than silently discard evidence.
Subscription qualification suppresses API-dollar admission estimates while
retaining all reported usage and informational dollar values. Token, request,
time and any separately configured outer dollar ceilings remain enforced.

Research quality and efficiency have separate registered endpoints. Each compares
updating with disabled, equal-budget retry and experience-withheld search, sharing
alpha across all six tests. Quality needs a ten-point stream-success gain and at
most 10% observed regressions. Efficiency needs at least 20% fewer **total** physical
requests including acquisition, at least 80% paired-success streams, and a
one-sided upper bound of at most 10% on quality regression. A cheap failure cannot
qualify efficiency. Evidence must be complete, safe and actually exercise the
mechanism. Legacy two-comparison statistics are diagnostic in version 4;
`research_endpoints` owns its decisions and prospective quality power. Efficiency
power is not inferred from quality power.

After reviewing development feedback, freeze a new, separately curated unexposed
manifest for `--stage confirmation`. Three quality comparisons must meet the
prospective power requirement at alpha/6 before dispatch. More synthetic variants
cannot satisfy independence. Underpowered or inconclusive results remain so;
neither endpoint authorizes persistent activation or broader model/task claims.

## Historical five-arm study

The staged runner is `scripts/qualify_learning_study.exs`. Start with
`--stage calibration`: it compares the ordinary harness with explicitly
developer-authored workflow guidance on eight repository-shaped development
families. This diagnoses whether the permitted harness surface can help; the
reference guidance contains no implementation or private checks. After reviewing
headroom, use a fresh output directory and `--stage development` for all five arms.
Both stages default to Scripted. Hosted execution requires explicit authorization
and `--allow-live`; model/effort/output switches follow the subscription rules below.

The development corpus covers dependency layers, nested transactions, TTL/LRU,
configuration overlays, event reconciliation, weighted intervals, integer
apportionment and atomic patches. Each repository has source modules, a generated
runtime, build tooling, public checks and private checks. Both source and generated
runtime must pass. These are synthetic developer-visible diagnostics, not real
GitHub issues or independent confirmation. Additional variants remain in their
original family; eight families cannot be relabeled as eighty independent cases.
Public checks cover the contract categories using different parameters from
private checks. The initial calibration's smaller checker is retained as prior
development evidence; it is not pooled with the strengthened corpus.

`--manifest PATH` imports pinned external repositories instead of generated cases.
The private JSON manifest has `schema_version: 1`, `metadata` (including `id`,
`exposure: developer_exposed | unexposed`, and upstream revision/provenance), and
`tasks`. Each task supplies `id`, `cluster`, `phase: seed | learning | confirmation`,
`source`, `source_sha256`, an immutable local `image: sha256:...`, `prompt`,
`public_pytest_args`, `immutable_paths`, `private_tests` and
`private_tests_sha256`. Source and private test digests use
`Lemieux.CLI.Learning.Leases.source_digest/1`. Remove Git history and credentials
before freezing sources. Private tests must be outside the source tree and never
enter model containers; separate grader containers receive a read-only `/tests`
mount. File tools and shell commands share the logical `/app` workspace.
The imported public prompt lists frozen verification paths and permits regression
tests in separate new files. The same declared constraint applies to every arm;
private test paths and contents stay outside that prompt.
Directory-scoped search helpers keep the owned workspace mount and change
directory inside the command environment, including absolute logical paths.
Qualify each image/grader with an untouched baseline and a known reference repair
before hosted work. This adapter runs pytest already installed in the image and
does not install packages or enable network access. Adapted benchmark runtimes
must be reported separately from official leaderboard results.

`--stage confirmation --manifest PATH` requires an unexposed corpus attestation
and adequate prospective power. Exposed repository tasks remain development
evidence. The runner cannot prove the curator's independence or absence of
training contamination from an exposure label.

Plans with an `analysis` field use protocol version 3; version 2 plans and their
historical analysis remain verifiable. Each independent stream owns its library
per arm and repetition. Only earlier tasks in that stream can become experience.
The generated development study first collects one fixed seed task per family
through ordinary capture, with no search or seed selection. Registration freezes
that recipe and every target before paid work; the target plan then pins actual
retained seed bytes. Every learning arm/repetition receives the same initial seed
inventory for its stream. Retrieval accumulates observations without probing;
frozen refinement keeps the seed inventory; updating refinement also retains
later observations and supported profiles. Seed usage is reported separately and
included in the updating arm's request-ratio acceptance check. An external
manifest can declare `phase: seed` tasks; an empty external seed inventory is
explicitly reported and exercises no prior retrieval.
After acquisition, every declared seed stream must contain retained experience
before target episodes can start. An empty stream writes `seed-inventory.json`
and stops; the runner never repeats a seed to force that check to pass. This is
a presence check, not evidence that the lessons help. The archived `8303aac`
study predates this gate and retained no seed lessons; its frozen comparisons
cannot qualify prelearned-library transfer.
Only confirmation-phase outcomes enter the primary endpoint, which is completion
of every confirmation task and repetition in the stream. All episode success,
usage and latency are also reported. Stream independence is a study-design
requirement; grouping labels cannot establish it for overlapping repositories.

The two primary comparisons are updating versus disabled and updating versus
retry. Exact one-sided paired McNemar tests use alpha/2. The reported exact interval
is for win probability conditional on a discordant stream, **not** an interval
for percentage-point improvement. Other contrasts are diagnostic. Practical
acceptance additionally requires a ten-point observed stream-success improvement,
at most 10% regressing streams, total requests at most eight times each control,
p95 latency at most ten times each control, and observed candidate promotion and
rollback. Safety failures, incomplete execution or unknown usage still refuse a
benefit claim. This is bounded efficacy evidence, not a universal no-regression
or release-safety guarantee. See [NIST's paired-test assumptions](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/mcnemar.htm).

Power is computed before dispatch using the actual rejection and practical
acceptance rule. With assumed win/loss probabilities 0.25/0.05, 80 independent
streams give about 90.4% power per primary comparison and an 80.8% lower bound
for detecting both. Those assumptions are predictions, not measured efficacy.
An underpowered version 3 `independent_confirmation` plan is refused before
execution. A small development study remains explicitly underpowered; significance
does not establish representativeness or justify automatic asset activation.

The study host gives task selection, retries and the proposer only public
verification feedback. Private grades stay outside those decisions. Retries can
use the full outer request allowance, stopping on public verification success;
refinement runs only after failed public verification. Supported profiles and
their contrast evidence become source-backed proposer lessons. All task, proposer,
probe, promoted and unsuccessful work is metered. Pre-dispatch acquisition failures
retain a diagnostic category, and the study freezes a 30-second acquisition limit.
Incomplete checkpoints still require explicit recovery and are never replayed.
A terminal `max_turns` probe with verified runtime evidence and complete usage is
scored as a failed probe, allowing refinement to learn from an exhausted control.
It cannot become a successful candidate even when its partial files pass public
checks. Provider failures, missing usage and evaluator timeouts remain incomplete.
The proposer receives the public task request explicitly alongside bounded
transcript evidence; private grading is never included.
Study workspaces hide arm and attempt labels behind opaque paths. Actual changed
file bytes are retained before lease release, including shell-generated files;
bounded or unreadable omissions refuse complete qualification. Private workspace
artifacts remain outside model containers and are indexed by digest in the report.
The request envelope scales with `--task-requests` (8–24): at least eight task
allocations plus sixteen proposer calls, with six task allocations plus sixteen
reserved for refinement. Every arm receives that same outer envelope; retry
attempts can use it fully. The default twelve-call task allowance retains a
160-call outer cap. A twenty-four-call task uses 208 outer slots.

For example, after explicit hosted authorization:

```sh
mix run scripts/qualify_learning_study.exs --allow-live --stage calibration \
  --model openai_codex:gpt-6-luna --effort low --output tmp/study-calibration-luna
mix run scripts/qualify_learning_study.exs --allow-live --stage development \
  --model openai_codex:gpt-6-luna --effort low --output tmp/study-development-luna
```

An inexpensive offline study rehearsal uses reference repairs through Scripted:

```sh
mix run scripts/qualify_learning_study.exs --stage development --offline-smoke \
  --output tmp/study-offline-rehearsal
```

The offline subset cannot select a hosted provider. Reference implementations
stay in the host and are never supplied to a hosted provider or copied into live
task inputs. Its passing outcomes establish mechanics only.

The [staged development study](qualification/2026-10-20-learning-study/README.md)
records the version 3 calibration, seeded comparison, exposed repository
supplement, physical-dispatch audits and excluded earlier scopes. These tasks
remain development evidence; they do not establish independent efficacy or
authorize automatic persistent activation.

The following describes the earlier version 2 pilot runner and its frozen rules.

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
