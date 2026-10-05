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

The [capture extension](https://github.com/houllette/lemieux/blob/main/examples/extensions/capture/README.md)
writes the first draft itself: a `session_end` hook that turns a verification
command left failing, or a correction from the person, into a feedback record
and a bounded draft under `.lmx/drafts/` for exactly this review. That
directory carries a `.gitignore` of `*`, so `git add -A` never stages a
draft, and the snapshot skips the same secret-shaped files plus `lmx`'s own
`.lmx/config.json`.

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
