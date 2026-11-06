# Selective RSI calibration after PR #122

[PR #122](https://github.com/houllette/lemieux/pull/122) passed source review
and merged with an exact-head guard as
`404737075f022d0384d41742c66cb2eca7832f3a`. The
[review record](review.json) binds all changed files at reviewed head
`dd76e15b6e5db4ac690bfc252526139c43a47103`, its identical merged tree,
61 passing targeted tests and 25 successful PR checks. This was an agent source
review with no blocking findings; it was not independent peer review.

The subsequent qualification found a public-feedback gap. The synthetic sample
had no failing task outcomes. Pint had genuine private failures, but its two
later baseline tasks passed the public checks that the selective controller can
use. The frozen selection rules therefore admitted no mechanism trial. Hosted
skill use, improvement and independent efficacy remain unqualified.

## Frozen execution and accounting

The user's request authorized further qualification. Before dispatch, the
executor declared a new cumulative ceiling of 1,200 requests, 8 million tokens
and two hours, using the existing Codex subscription route. This was a new
allowance; the earlier pilot's consumed authorization and historical ledgers
were not reused or reset.

Task execution used `openai_codex:gpt-6-luna` at low effort. Sol/high was
registered for improvement work, but no improver was dispatched. Both stages
ran from the clean merged source above, with Elixir 1.20.4 and OTP 29.1.1,
fresh HTTP/1 connections and disabled transport retries. Tasks ran in
unprivileged, networkless containers. The two scopes retain separate reports:

| Fixed sample | Episodes | Physical requests | Tokens | Result |
| --- | ---: | ---: | ---: | --- |
| Eight synthetic development families; disabled/reference pairs; 12 turns | 16 | 139 | 655,315 | Every artifact passed both graders; no eligible failed-public-verification stream. |
| Three retained Pint cases; disabled/reference pairs; 48 turns | 6 | 127 | 2,841,802 | Baseline private success 1/3; no eligible later target under the public-only rule. |
| Shared allowance | 22 | 266 | 3,497,117 | Complete accounting; neither shared request nor token ceiling stopped a sample. |

The last report was written 21 minutes 19.497 seconds after the original shared
allowance clock started. The [synthetic protocol](synthetic-protocol.json) stopped after
its fixed sample. A [separately registered Pint diagnostic](pint-protocol.json)
then used the same remaining allowance and original deadline. Its three fixtures
first passed fresh [positive and negative grader controls](pint-controls.json).
Pint's established 48-turn horizon was frozen before those model calls.

Both [synthetic](synthetic-selection.json) and [Pint](pint-selection.json)
selection records retain their empty eligible sets. Pint-652 was reserved as the
earlier seed; only Pint-920 or Pint-948 could become the later mechanism target.
Eligibility required a completed, safe, accounted baseline with failed public
verification and a completed reference with passing public verification.
Private grades never selected a target. No seed acquisition, six-arm mechanism,
larger efficacy study or independent confirmation followed these refusals.

## Pint outcomes and stopping

| Case | Arm | Public | Private | Requests | Tokens | Seconds |
| --- | --- | --- | --- | ---: | ---: | ---: |
| 652 | Disabled | Fail | Fail | 18 | 205,690 | 79.089 |
| 652 | Reference | Pass | Fail | 6 | 39,586 | 39.105 |
| 920 | Disabled | Pass | Pass | 25 | 405,502 | 118.626 |
| 920 | Reference | Fail | Fail | 48 | 1,881,022 | 245.932 |
| 948 | Disabled | Pass | Fail | 13 | 125,449 | 45.761 |
| 948 | Reference | Pass | Fail | 17 | 184,553 | 70.343 |

The reference is fixed developer-authored workflow guidance. These single pairs
are difficulty and cost observations, with no learned intervention or causal
benefit estimate. The Pint adapter grades a SWE-rebench-derived pytest subset;
these are exposed development cases from one repository, not an official
benchmark score or three independent streams.

Each Pint public check contains one test; its private grader contains 43, 51
or 6 tests. Public passes on cases 652 and 948 did not establish private success.
There is private outcome headroom, while the registered later tasks supplied no
public failure signal for selective refinement. Feeding those private verdicts
back into the same trial would change the frozen information boundary.

A [retrospective diagnostic](public-feedback.json) reconstructed the exact retained
Pint-948 baseline filesystem change and reran its original public check, then
added the already model-visible `pint/testsuite/test_definitions.py`. Original
public test bytes and helpers were preserved in the model and reference copies;
no private grader was mounted. The untouched control failed 1 of 7 checks, the
reference passed 7 of 7, and the captured model artifact also passed 7 of 7.
The [executed driver](public-feedback-driver-v2.ex.txt) and log hashes are retained.
This negative result shows that adding this existing regression file does not
expose the missing correctness case. It used no model request, changed no frozen
outcome and supplies no new independent or learned-mechanism observation.

Two episodes reached their task ceilings: synthetic Cache/disabled at 12 turns
left a passing artifact; Pint-920/reference at 48 turns left a failing artifact.
Both retain failed agent status and explicit `max_turns` harness errors. Complete
artifact evidence does not imply that the agent completed its turn. Original
and selected fields overlap and do not count as additional executions.

The [observation projection](observations.json), [synthetic audit](synthetic-audit.json)
and [Pint audit](pint-audit.json) bind every episode to private raw evidence.
Native verification rebuilt both calibration reports, verified original/selected
run transcripts and reconciled physical meters with the shared ledger. Unknown
usage, provider failures, retries, cancellations and active calls at close were
zero. All workspace evidence was complete and no safety failure was observed.
The first closed ledger prefix was recovered exactly from its report snapshot;
its bytes match the digest observed before the second stage began.

Access-only credential loans and the allowance owner lock were removed.
[Ownership reconciliation](cleanup.json) found no campaign workspace container
remaining. A pre-existing October 20 qualification container and unrelated
workloads were preserved. Subscription dollar estimates are informational;
this packet reports quota consumption rather than measured API billing.

## Offline mechanics and CI

All [eight benchmark canaries](benchmark-host.json) passed against the merged
library. The task-local apparatus matched all 69 source hashes in the
[earlier inventory](../2026-11-05-rsi-v1.1/benchmark-apparatus.json), with a
matching library lock. No benchmark-labelled container remained. The primary
benchmark checkout's status fingerprint was unchanged.

The [portable export rehearsal](portable-export.json) passed through an actual
fresh Mix consumer. The complete [exported tree](portable-package/lemieux-extension-export.json)
is retained byte for byte. It preserved the exact resolved identity and dependencies,
loaded `references/rules.json` through the real skill tool, produced the expected changed
artifact and restored the baseline on undo. The core library retained no
application callback. This is the fixed owner-written example with a data asset;
no hosted learned improvement was selected in this campaign. The export remains
**unassessed**, with independent confirmation and reviewed CodeGate evidence still
required. A receiving host supplies fresh approval; the package carries none.

All [post-merge workflows](merge-verification.json) passed. CI attempt one failed
the unchanged transport test's pooled-socket equality assertion, seed 952647.
That seed passed both local tests; seeds 101, 102 and 103 added six passing
observations. The unchanged commit's second CI attempt passed 6,072 ordinary
cases, 25 distributed tests and 39 sandbox tests. The original failure and log
hash remain in [validation](validation.json); no cause or source fix is attributed.

The final `mix precommit.full` gate passed. Ordinary and coverage runs each
passed 6,078 cases (12 doctests and 6,066 tests), with 11 skipped and 47 excluded.
Coverage was 86.72%; Dialyzer reported zero errors. The standalone host passed
123 tests, distributed tests passed 25, and the packaged consumer preserved
9/17/25 entries through seed, resume and tightening. All eleven examples checked
successfully and all 80 Python release-helper tests passed. The command and
complete log hash are recorded in validation. This packet adds evidence and
documentation without changing the measured runtime.

The library and release-host dependency audits passed. Example resolution also
emitted existing advisory notices: `computer_use` resolved Hackney 4.8.5,
JSV 0.21.2 and `ssl_verify_fun` 1.1.7; `hello` and `research` resolved JSV 0.26.0.
The `ssl_verify_fun` notice was classified critical. The gate compiles/tests those
examples; their dependency-review findings remain unresolved. A passing gate
does not qualify every example graph as free of advisories. These notices and
their scope are retained in validation, with no lock or constraint changes.

## Remaining gates

| Issue | Established in this follow-up | Still required |
| --- | --- | --- |
| [#79](https://github.com/houllette/lemieux/issues/79) | Frozen provider-free plans, complete model/runtime-scoped calibration, grader controls, full usage and honest stopping. | A warranted observable failure stream, a matching observed mechanism, then adequately powered fresh coding-task comparisons. |
| [#80](https://github.com/houllette/lemieux/issues/80) | Review and offline checks of complete skill loading, selective probes and host authority preservation. | Hosted use and outcome qualification of each new kind before default selection. |
| [#81](https://github.com/houllette/lemieux/issues/81) | Exact native export identity, complete source, fresh consumer and rollback mechanics. | An independently qualified improvement and its reviewed release evidence. |
| [#47](https://github.com/houllette/lemieux/issues/47) | Preserved implementation and concrete empirical limits. | Completion of those remaining children; all four issues stay open. |

The next development work should strengthen public checks from reported
requirements and reviewed ordinary-use feedback (roadmap V2), retaining exposure
and causality. A later calibration needs an earlier seed and a genuinely observed
failed target before another mechanism run is warranted. Repeating passing toy
cases or revealing private confirmation answers does not supply that signal.

The [prospective power grid](power-planning.json) uses the unchanged registered
assumptions: the 128-independent-stream example clears the 0.8 quality-power
threshold; the 96-stream example does not. This is planning, not a universal
minimum sample size or observed power. Repetitions and related Pint cases do not
create independent streams. Its request-envelope column uses the 12-turn
single-skill budget, not a cost forecast for the 48-turn Pint scope.
Fresh source, image and grader closures, per-model
qualification and confirmation remain roadmap V9 work. Neither a larger campaign
nor additional asset kinds were enabled to bypass these gates.

Verify public bytes and report consistency without provider calls:

```sh
mix run --no-start docs/qualification/2026-11-06-rsi-selective/verify.exs
```

The verifier checks this packet's seals and cross-file consistency. Digests do
not authenticate private grader correctness or replace the raw-evidence audit.
