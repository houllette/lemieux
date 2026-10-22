# Learning qualification development study — 2026-10-20

The revised qualification was built and run with local Codex subscription access. The seeded Luna study selected 141/160 passing target outputs. Its mechanical result is **safety_failure** and benefit result is **inconclusive**. All eight seed runs retained no lessons, leaving the initial library empty; this scope supplies no positive control for prelearned-library transfer. These developer-visible diagnostics establish no independent efficacy, automatic persistent promotion, typed-asset benefit or cross-model transfer.

The hosted runtime was frozen at `8303aacd533cc53fddbd988032100025ba9f98de`, with GPT-6 Luna/low or GPT-6.1 Sol/medium in task, proposer and probe roles. The seeded and main calibration scopes used the ten-request task setting; Bottle used twenty-four and the sensitivity scope used eight. Each plan freezes its complete task-plus-improver allowance. Transport retries were disabled. Models used access-only credential loans; refresh credentials remained with Codex. Subscription-backed inference is reported in normalized tokens and physical requests. These do not measure subscription quota depletion or API-dollar charges. Task shells ran in pinned, networkless, nonroot containers with read-only roots and owned workspace mounts.

Version 3 registers updating versus disabled and updating versus equal-budget retry as the two primary comparisons, each at alpha 0.025. Other contrasts are diagnostic. The exact paired test conditions on discordant, independent binary stream outcomes; see the [NIST paired-test description](https://www.itl.nist.gov/div898/software/dataplot/refman1/auxillar/mcnemar.htm). Its interval estimates win probability among discordant streams. It is not an interval for the absolute success-rate gain.

The primary outcome requires every confirmation-phase task and repetition in a stream to pass. Learning-phase results remain secondary. Related variants and repetitions supply **eight family clusters**, not 160 independent observations. These are synthetic repository-workflow diagnostics, not independent real-world confirmation. Adequate power is **false**. Under the registered win/loss assumptions 0.25/0.05 (an expected twenty-point gain), 80 independent streams would give an approximately 80.8% lower bound on power for both comparisons. That is a prospective model calculation, not measured efficacy or a universal sample requirement.

Practical acceptance also requires at least a ten-point observed gain, at most 10% regressing streams, request ratios at most 8 including seed acquisition, p95 latency ratios at most 10, complete accounting and execution, and supported promotion with matching rollback. The archived reports retain the original `resource_policy` explanatory string; the numeric version 3 analysis limits and acceptance code are authoritative. The current reporter clarifies that wording without changing the archived outcomes or limits.

The guarded treatment reuses prior improvements through the proposer. A later task still needs a fresh supported contrast before a new overlay executes. This measures that policy. It does not test unconditional reuse of an evolved harness at the start of every later task. The ordinary default lane remains scoped, unconfirmed recall; the isolated experimental host is explicitly invoked.

The [registration](seeded-luna-low/registration.json) fixes selection and seed construction before paid work. Eight ordinary seed runs attempt capture and freeze one common inventory per family, without search or selection. The [target plan](seeded-luna-low/plan.json) then pins the actual inventory digest before target execution. Stores remain separate by family, arm and repetition. Updating and retrieval receive earlier authorized observations causally; frozen retains its seed inventory. Public verification alone controls proposals, retries and output selection. Private grades never enter those decisions.

One retry attempt for `development-graph-2`, repetition two, modified immutable `tools/build.py`. Its selected output passed public and private checks, but that does not erase an effectful attempt violation: overall mechanics is `safety_failure`. Passing-output totals below describe selected-output quality, not fully qualified safe trials. Updating versus disabled had zero stream-success gain (one-sided p = 0.75); updating versus retry had a 25-point loss (p = 1.0 for improvement).

The completed seeded study has the following outcomes. Each arm has sixteen learning and sixteen confirmation episodes. Latency includes host verification, workspace operations and shared-host effects; it is not a production latency estimate.

| Arm | Learning passes | Confirmation passes | Complete confirmation streams | Target requests | Normalized tokens | p95 seconds |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| disabled | 13/16 | 13/16 | 6/8 | 270 | 1,225,707 | 30.4 |
| retrieval | 15/16 | 15/16 | 7/8 | 280 | 1,263,689 | 30.4 |
| retry | 16/16 | 16/16 | 8/8 | 323 | 1,460,528 | 45.1 |
| frozen | 14/16 | 12/16 | 4/8 | 511 | 2,495,168 | 128.7 |
| updating | 13/16 | 14/16 | 6/8 | 448 | 2,171,991 | 114.3 |

The seed prefix retained no lessons in any family. The [inventory audit](seeded-luna-low/seed-inventory-audit.json) verifies that the frozen library digest represents eight empty inventories. Later target retention is counted in the audit, separately from the seed inventory. Future runs with declared seeds now stop before target dispatch if any required stream has no retained experience. Presence alone still proves no relevance or benefit.

Seed acquisition used 73 additional physical requests and 328,077 normalized tokens. The [audit](seeded-luna-low/audit.json) covers 168 episodes, 1,905 physical dispatches and 8,945,160 normalized tokens. Unknown dispatch usage: 0. Incomplete episodes: 0. There were 8 candidates retained in completed refinement receipts, 0 promotions and 0 rollbacks. Partial candidates in incomplete experiments are not inferred from a missing receipt.

The [mechanism audit](seeded-luna-low/mechanism-audit.json) records eight completed candidate comparisons. Every control set included at least one full public pass. Under the strict rule that the worst candidate must beat the best control, no candidate could dominate that ceiling. No supported profile was promoted or carried forward. Only one later observation was retained, during a confirmation task, with no subsequent task in its stream/repetition. These data did not exercise cross-task experience reuse.

Each cell below counts the two confirmation repetitions within one family. It does not increase the independent sample size.

| Family | Disabled | Retrieval | Retry | Frozen | Updating |
| --- | ---: | ---: | ---: | ---: | ---: |
| graph | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 |
| journal | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 |
| cache | 2/2 | 2/2 | 2/2 | 1/2 | 1/2 |
| merge | 0/2 | 1/2 | 2/2 | 1/2 | 1/2 |
| reconcile | 2/2 | 2/2 | 2/2 | 1/2 | 2/2 |
| intervals | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 |
| allocation | 2/2 | 2/2 | 2/2 | 2/2 | 2/2 |
| patch | 1/2 | 2/2 | 2/2 | 1/2 | 2/2 |

Calibration and the separate exposed Bottle task provide additional diagnostics. Their requests and tokens are not pooled into the seeded efficacy comparisons.

| Scope | Outcome | Physical requests | Normalized tokens |
| --- | --- | ---: | ---: |
| [Luna/low, ten-call calibration](calibration-luna-low/report.json) | disabled 7/8; reference 8/8 | 131 | 596,023 |
| [Sol/medium, ten-call calibration](calibration-sol-medium/report.json) | disabled 8/8; reference 8/8 | 129 | 612,534 |
| [Luna/low, eight-call sensitivity](budget8-calibration-luna-low/report.json) | disabled 6/8; reference 7/8 | 122 | 549,613 |
| [Luna/low, Bottle](bottle-luna-low/report.json) | 1/10; mechanics incomplete_execution | 296 | 5,130,320 |
| [Sol/medium, Bottle](bottle-sol-medium/report.json) | 10/10; mechanics passed | 101 | 1,731,500 |

Luna's ten-call calibration passed the recorded headroom and accounting rule; the [decision record](study-next-stage-decision-8303aac.json) and [evaluated decision](study-development-decision-8303aac.json) precede the seeded study. Sol's baseline passed all eight calibration tasks, leaving no measured headroom. The [eight-call sensitivity record](study-budget-sensitivity-8303aac.json) defines one separate diagnostic; repeated families are not new independent evidence. The default-on promotion policy was not relaxed.

Bottle is one exposed repository case with two repetitions per arm, no learning prefix and no seed library. It measures task-local behavior, not transfer. The [apparatus receipt](repository-apparatus.json) pins the exported source, image, grader and upstream revisions. Untouched and offline reference repairs graded 2/6 and 6/6 private checks respectively; reference repairs and private tests never entered live model workspaces. These adapted runs are separate from official leaderboard results.

The final Sol Bottle scope passed all ten outputs with no policy violations and no need for refinement. Luna passed one of ten and retained one incomplete candidate comparison after its frozen learning-token allowance refused further dispatch. [The admission audit](bottle-luna-low/incomplete-admission.json) records that cause. Its physical usage is known; an unfinished contrast still fails execution qualification. No replay or additional allowance was used to complete that intent.

The harder tasks uncovered and motivated three concrete fixes: accounted turn-limit probes now score as failures; imported public prompts disclose frozen verification files; and directory-scoped search commands retain the owned mount root and enter the directory inside the environment. Missing usage, provider failures and evaluator timeouts continue to require recovery. The fixed container path behavior was checked through actual file-search and command execution in both logical and physical namespaces.

Earlier scopes remain under `superseded/` with their original plans and reports:

- Calibration at `ad36a21` used an earlier public checker. Its outcomes are not combined with the revised checker.
- The `9149e44` Luna Bottle scope passed 0/10 with one incomplete refinement. A [posthoc byte-reconstruction audit](superseded/bottle-luna-low-9149e44/posthoc-audit.json) reproduced all ten selected outcomes; every output missed vulnerability classification and five also mishandled invalid header inputs. This audit supplied no live selection feedback or reranking.
- The `f1982f3` scopes preceded the public-contract and search fixes. Luna's [admission diagnostic](superseded/bottle-luna-low-f1982f3/admission-audit.json) records an omitted quota field. A separate admitted candidate scored 0 and 1 on repeated probes and was correctly not promoted. Sol passed the private assertions in all ten outputs, but two edited frozen public tests and failed policy; the task prompt had not disclosed that constraint.
- The [stopped Sol study](superseded/aborted-development-sol-medium-9149e44/aborted.json) retains 52 completed episodes and one interrupted intent with unknown usage. It stopped after the namespace defect was identified. Whether that defect changed any completed grade was not established; fallback search may have recovered. Its fixed stopping rule was not completed, no primary analysis was produced, and the intent was not replayed.
- The `0275b4e` unpaid rehearsal had a failed reference control: its scripted writes lacked required reads. Its generic mechanical result was not positive-control qualification. The corrected [offline rehearsal](offline/report.json) passed all 21 episodes, with no hosted calls and 588 scripted token units. The later [inventory-gate rehearsal](offline-inventory-gate/report.json) also passed all 21 episodes and retained a seed lesson before target dispatch; it qualifies the new presence check, not hosted efficacy.

The [validation receipt](validation.json) separates local gates, seeded timing observations and GitHub CI attempts. The ordinary suite retains its parallelism, assertions and deadlines. Instrumented CI failures are preserved in that receipt; serial coverage collection and startup-failure diagnostics were checked separately. The 85% floor and complete test selection remain unchanged.

The next evidence needs are concrete: require nonempty seed inventories before spending on target episodes; calibrate repeated failure of both baseline and equal-budget retry on realistic repository streams; ensure public development verification covers the primary task requirements; inspect invalid proposer output and bounded-work refusals; and compare the guarded treatment with an explicitly authorized carry-forward treatment. Fresh independent confirmation requires an adequately powered, separately curated corpus on each advertised model/runtime. Existing synthetic and exposed tasks cannot supply that claim. New learned asset kinds and persistent automatic activation retain their separate qualification gates.

Portable reports and audit projections exclude credentials, private grader material, task solutions and raw transcripts. Actual changed-workspace bytes remain in the private host store and are indexed by digest. [The projection script](project_evidence.py) checks report-row evidence hashes and physical-meter/ledger agreement for the frozen archive schemas; metadata and grade labels still require review before publishing another corpus. [The offline verifier](verify.exs) checks sealed plans, runtime identities, reports, usage projections and recomputed numeric results. Run it from the repository root with `mix run docs/qualification/2026-10-20-learning-study/verify.exs`. [The cleanup receipt](execution-cleanup.json) records removed access-only loans and the absence of owned containers. [SHA256SUMS](SHA256SUMS) records every published artifact's bytes.
