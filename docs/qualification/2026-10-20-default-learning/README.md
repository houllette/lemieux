# Hosted learning qualification — 2026-10-20

Stock ordinary-use recall worked in both hosted streams. Neither five-arm sample
established a quality gain. Luna completed its mechanical gate; Sol retained a
passing original answer after one incomplete refinement requiring recovery.
Automatic typed-asset selection and independently qualified persistent promotion
remain gated.

Hosted runs used clean revision
[`6301f82`](https://github.com/houllette/lemieux/commit/6301f82c2ee1dac457fe0e77cff5959e9f73bfac).
The later asset catalog-collision guard was validated offline and is outside these
hosted results; typed assets were not selected in these runs. Each model/effort
pair has its own frozen plans and reports. Inference used local Codex subscription
access. Provider USD estimates in usage records are informational, not API charges.

## Method and decision

The [qualification guide](../../learning-qualification.md) describes execution.
Each five-arm sample used two seed tasks, then two developer-visible task families
with two repetitions: four observations per arm, twenty target episodes per model.
Related cases count as two clusters, not four independent samples. This is neither
an independent holdout nor evidence of transfer between models.

Each target had an equal outer allowance of 160 requests, 3,000,000 normalized
tokens and 2,000,000 ms. Task, failed attempts, retries and improver work fit inside
that allowance. Refinement reservations and physical dispatches are reported
separately. SDK transport retries were disabled and frozen as
`transport_max_retries: 0`; session/controller retries remained accounted.
Every completed target ledger matches its dispatch meter; none has unknown usage.

The stock-path supplement used ordinary CLI assembly and the real private store,
without evaluator-supplied learning hooks or injected lessons. Each task had 32
requests and 480,000 ms, with zero additional learning inference calls. Tools ran
in the pinned non-root, networkless Python container. The host kept credentials
and independent grading outside task workspaces. Runs overlapped on one host;
latencies describe that observed load, not production performance.

Benefit required complete/safe execution, no paired regressions and a positive
conservative paired-cluster lower bound against both disabled and retry controls,
with Bonferroni correction across seven preregistered contrasts. Zero selected
quality effect and two clusters leave intervals spanning [-1, 1].

## Five-arm results

| Model / effort | Arm | Passed | Requests | Normalized tokens | p50 / p95 seconds |
| --- | --- | --- | ---: | ---: | ---: |
| GPT-6 Luna / low | disabled | 4/4 | 23 | 84,963 | 16.28 / 20.28 |
| GPT-6 Luna / low | retrieval | 4/4 | 27 | 113,287 | 15.83 / 23.28 |
| GPT-6 Luna / low | retry | 4/4 | 25 | 96,353 | 14.84 / 26.85 |
| GPT-6 Luna / low | frozen | 4/4 | 85 | 400,447 | 56.51 / 102.71 |
| GPT-6 Luna / low | updating | 4/4 | 69 | 318,246 | 54.05 / 61.20 |
| GPT-6.1 Sol / medium | disabled | 4/4 | 30 | 119,985 | 47.45 / 54.51 |
| GPT-6.1 Sol / medium | retrieval | 4/4 | 29 | 126,736 | 46.67 / 49.09 |
| GPT-6.1 Sol / medium | retry | 4/4 | 30 | 120,365 | 47.59 / 68.23 |
| GPT-6.1 Sol / medium | frozen | 4/4 | 116 | 577,531 | 171.64 / 207.69 |
| GPT-6.1 Sol / medium | updating | 4/4 | 99 | 509,444 | 166.51 / 253.50 |

Normalized tokens include input, output and cache token categories under the
runtime's usage contract; they are not a claim about billed API units. The target
comparison excludes the separately retained seed warmup:

- GPT-6 Luna / low: mechanics `passed`, benefit `inconclusive`; 229 target requests, 1,013,296 normalized tokens. Warmup separately used 9 requests and 31,855 tokens. The audit records 34 graded attempts, 0 unsuccessful attempts, 12 control probes, 0 candidates and 0 promotions.
- GPT-6.1 Sol / medium: mechanics `incomplete_execution`, benefit `inconclusive`; 304 target requests, 1,454,061 normalized tokens. Warmup separately used 15 requests and 59,397 tokens. The audit records 34 graded attempts, 0 unsuccessful attempts, 14 control probes, 0 candidates and 0 promotions.

Sol episode `2-paths-2-updating` returned
`{:requires_recovery, "refinement"}` before any probe dispatch. Its ten original
task calls were fully reported and its passing output was retained. The experiment
reservation lasted about five seconds; the generic checkpoint result does not
establish the underlying cause. The incomplete intent was preserved and not
replayed. A passing task therefore did not qualify complete learning execution.

No candidate qualified for a promoted live execution. Baseline retention and
abstention were observed; live candidate composition, canary activation and rollback
remain unexercised by this sample. Offline tests cover those contracts. Audit
projections retain unsuccessful intermediate attempts as well as selected results.

## Stock CLI path

All sixteen stock-path episodes passed. Both later-task episodes for each model
received earlier experience; disabled streams received none.

| Model / effort | Arm | Passed | Requests | Experience received |
| --- | --- | --- | ---: | ---: |
| GPT-6 Luna / low | disabled | 4/4 | 27 | 0 |
| GPT-6 Luna / low | ordinary | 4/4 | 21 | 2 |
| GPT-6.1 Sol / medium | disabled | 4/4 | 26 | 0 |
| GPT-6.1 Sol / medium | ordinary | 4/4 | 31 | 2 |

Request-count differences vary across these small samples. This demonstrates
retrieval/application mechanics and observed non-regression, not an efficiency
or quality benefit. Offline tests cover shared TUI assembly, immediate opt-out,
exact next-request undo, derived-lesson invalidation and provider-free inspection.

## Concrete follow-up

- Preserve the underlying pre-dispatch refinement failure cause in durable
  evidence. Reproduce slow lease acquisition offline under the existing bounds,
  then preregister a host-specific acquisition policy and fresh qualification;
  do not relabel this incomplete checkpoint as a successful abstention.
- Add independent task families with reproducible unresolved baseline failures.
  More repeats of these same families do not supply additional independent
  clusters or overcome the ceiling-limited selected outcomes.
- Measure a probe-selection rule for already resolved verification recoveries
  against the same retry control, retaining expensive or unsuccessful attempts.
- Add candidate-producing cases for each typed representation, apply the same
  controlled protocol, then fresh independent confirmation and host-authorized
  canary/package/rollback qualification before automatic selection.

The default remains bounded scoped recall with explicit probe abstention; it
does not start the separately authorized isolated refinement host. The unmet
requirements in #47 and #78–#81 remain open. V2's feedback-to-case curation and
V9's independent-confirmation targets in the [roadmap](../../roadmap.md) are not
satisfied by these synthetic tasks.

## Audit and validation

The [superseded initial pilot](initial-pilot/README.md) remains separate because
SDK retry accounting was unproven. One interrupted Sol intent has unknown usage.
Those observations are not pooled into the revised results, and total quota
consumption across abandoned work is not claimed known.

Final source revision `18de03e` passed `mix precommit.full`: 5,824 ordinary checks,
86.80% coverage, zero Dialyzer errors, 119 release-host tests, 25 distributed tests,
package-consumer checks, examples and 60 Python helper tests. Seven stock-loop
tests passed timing observations at seeds 101/102/103 with concurrency four; the
first included only runner output-parent edits and later observations were clean.
Earlier dirty development failures remain separate Temper suspects.

CI observed a five-second observer-install timeout in the existing fake-session
initial-prompt test on Elixir 1.19. Its failure evidence was retained. Three local
repetitions at seeds 40247/40248/40249 and concurrency two passed without changing
the test or its timeout. The unchanged floor job was rerun; final PR checks are
reported separately. No signing, release, package publication or merge occurred.

Portable records:

- Luna: [plan](luna-low-plan.json), [report](luna-low-qualification-report.json),
  [audit projection](luna-low-audit.json), [stock plan](luna-low-stream-plan.json)
  and [stock report](luna-low-stream-report.json).
- Sol: [plan](sol-medium-plan.json), [report](sol-medium-qualification-report.json),
  [audit projection](sol-medium-audit.json), [stock plan](sol-medium-stream-plan.json)
  and [stock report](sol-medium-stream-report.json).

Warmup plans/results sit beside these files. Receipts preserve exact original
bytes and embedded contract digests. [SHA256SUMS](SHA256SUMS) covers portable JSON,
including the superseded pilot. Full private transcripts, model-visible evidence
text, credentials, callbacks and restored authority are excluded. Hashes establish
identity, not a signature or activation permission.
