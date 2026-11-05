# RSI 1.1 implementation qualification

This change advances [#47](https://github.com/houllette/lemieux/issues/47)
and its remaining children [#79](https://github.com/houllette/lemieux/issues/79),
[#80](https://github.com/houllette/lemieux/issues/80) and
[#81](https://github.com/houllette/lemieux/issues/81). It does not establish
independent efficacy or authorize new asset kinds in the default controller.

The implementation closes three observable gaps: a mechanism receipt could be
reused after changing task images or generation settings; a typed asset could
validate against tools absent from the eventual harness; and a source export
could omit files named by an embedded immutable asset. The new protocol also
requires use of every declared asset kind, rather than allowing profile-search
activity alone to supply its mechanism gate.

| Boundary | Verification |
| --- | --- |
| Frozen execution | v7/v2 mechanism tests reject changed images, isolation, request horizons, token limits, models, editor, transport and historical receipts. |
| Planning | The actual runner accepts a hosted model scope while Docker is deliberately unavailable; it creates registration/review documents and no credentials, allowance ledger, sessions or episode evidence. |
| Learned asset use | Scripted ordinary-harness integration proposes and reviews a procedure and tool description, loads their exact bytes, records actual use per kind and restores the baseline. A separate setting fixture exercises changed tool disclosure. |
| Unavailable authority | Assembly rejects stale required/affected tool lists; descriptions preserve schemas and apply to authorized host tools. Stored approval cannot authorize another scope. |
| Export closure | Incomplete or altered portable trees and missing graph edges refuse export. Existing confirmation, fresh Mix-consumer loading, CodeGate/human-review refusal and exact rollback tests remain in the gate. |
| Stock product path | Four CLI/TUI container-replay tests pass, including causal reuse, bounded refinement and cleanup. |
| Benchmark host | The [eight scripted canaries](benchmark-host.json) pass against the target checkout. They exercise actual disposable containers, without hosted inference. |
| Grader controls | The [cross-file fixture controls](benchmark-controls.json) retain a passing reference repair and failing untouched baseline. This is one development fixture, not a real-repository population. |

The local `lemieux-bench` checkout contains substantial unrelated changes. Its
working source was copied into an ignored task-local snapshot, and its dependency
lock aligned with the target library before execution. The primary checkout was
not changed. Current public fixture files and an existing immutable cached image
supplied the reference/no-op controls; no benchmark result was relabeled as
independent learning evidence.

The existing benchmark development manifests and exposure ledger remain
exposed. They cannot supply independent confirmation merely by repartitioning
their tasks. Fresh coding-task streams, preregistered power and separate execution
authorization remain necessary for #79. A combined arm also cannot establish
each contained asset kind's independent contribution; use isolated per-kind
studies before considering default enablement.

Initial failing regressions and intermediate apparatus failures were retained in
local test/Temper history. The frozen-consumer fixture needed the newly required
source-integrity module in its deliberately minimal runtime. The provider-free
planning test also caught atom-keyed allowance metadata whose digest changed
after JSON persistence; registration now stores string keys. These were fixed
before the final gate. Earlier dirty-tree observations are development records,
not independent flake or efficacy evidence.

## Final offline gate

The [validation record](validation.json) retains the passing `mix precommit.full`
gate and hashes of the earlier failed attempts. Ordinary and coverage runs each
passed 6,055 cases (12 doctests and 6,043 tests), with 11 skipped and 47 excluded;
coverage was 86.69%. Dialyzer reported zero errors. The release host passed 123
tests, the distributed suite passed 25, all eleven examples checked successfully,
the fresh packaged consumer passed, and all 80 Python tests passed. Four stock
CLI/TUI container replays and six bounded observations of the two new integration
tests also passed. Those seeded observations used a dirty development tree and
do not erase its earlier deliberate failures.

The [benchmark apparatus identity](benchmark-apparatus.json) records the copied
host's source-file hashes, aligned dependency lock, pinned control image and
receipt hashes. Its eight canaries were rerun against the clean committed library;
their receipt matches [benchmark-host.json](benchmark-host.json) byte for byte.
The first PR secret scan flagged a source-file SHA-256 stored under a filename
containing `auth`. The [scan review](ci-scan-review.json) retains that failed
attempt and verification against the copied bytes. The inventory now uses
separate path and digest fields, with no scanner-rule or ignore-list change.

## Approved hosted pilot

The executor was `openai_codex:gpt-6-luna` at low effort; proposal, review and
reflection used `openai_codex:gpt-6-sol` at high effort through Codex subscription
authentication. The user separately approved one seed plus twelve comparison
episodes, capped at 800 shared requests, 8 million tokens and two hours. The
[registration](registration.json) froze a maximum envelope of 2,496 requests;
the smaller outer cap did not interrupt this sample. It tested skills only,
without executable helpers or profile search, on one developer-visible synthetic
graph stream with two repetitions. No independent confirmation was dispatched.

The [plan](plan.json) binds source commit
`601bdd31b8fb78c94d2406f108acf85e02ff0161`, registered from a clean tree with
Elixir 1.20.4 and Erlang/OTP 29.1.1. No source or build artifact changed during
execution. The subsequent evidence commit changes documentation only. This
receipt retains its exact original revision binding.

The [report](report.json) records complete execution and accounting, with quality
and efficiency both **inconclusive**. The [mechanism receipt](mechanism.json) is
**not demonstrated**: the updating arm never loaded its selected skill. Its
required lesson-to-execution and procedure-use checks both fail. Checks marked
unrequired are not observations of helpers, settings, profiles or descriptions.
This receipt refuses admission to a larger hosted research stage.

| Arm | Passed targets | Physical requests | Tokens | Episode wall time, seconds | Selected skill applied / restored | Actual skill use |
| --- | ---: | ---: | ---: | --- | ---: | ---: |
| Disabled | 2/2 | 23 | 115,761 | 45.961; 47.201 | 0 / 0 | 0 |
| Retrieval | 1/2 | 23 | 168,073 | 55.977; 44.796 | 0 / 0 | 0 |
| Retry | 2/2 | 17 | 82,537 | 41.048; 32.233 | 0 / 0 | 0 |
| Frozen | 2/2 | 150 | 1,102,924 | 371.234; 314.375 | 2 / 2 | 0 |
| Updating | 2/2 | 153 | 1,149,608 | 338.332; 310.226 | 2 / 2 | 0 |
| Experience withheld | 2/2 | 172 | 1,292,517 | 355.843; 359.105 | 2 / 2 | 2 |

The passing seed added nine requests and 67,472 tokens. Total usage was **547
physical requests and 3,978,892 tokens** over 39 minutes 26.742 seconds. The
registered efficiency comparison charges acquisition to updating: 162 requests,
or 9.53 times retry and 7.04 times disabled. Its 5.81% request saving versus the
experience-withheld improver is below the registered 20% threshold. One related
stream cannot identify an effect from earlier experience or establish transfer.
Subscription dollar values in the raw accounting are informational, not measured
API billing.

The failed retrieval output is retained. A disabled final execution reached its
task request limit while leaving a verified passing artifact. The report also
retains the experience-withheld original's budget stop and seven budget-stopped
probes. Passing artifact grades do not imply that those agent turns completed.
The [audit](audit.json) includes every episode's outcome, latency, stops, selected
digest, observed use, restoration, meter totals and original evidence-byte hash.
Native verification recomputed the plan/report seals, ordinary report, registered
endpoints, transcript evidence for all thirteen episodes and the mechanism from
private raw evidence.
An independent sum reconciled per-episode physical meters and per-role totals
with the durable shared ledger. Unknown usage and active calls at close were
both zero. The access-only OAuth loan and allowance owner lock were removed;
no task-mounted containers remained, and unrelated containers were preserved.

## Remaining qualification

| Tracker | Established here | Remaining gate |
| --- | --- | --- |
| #79 | Provider-free planning, complete bounded six-arm development execution, full accounting and an honestly refused mechanism receipt. | Reliable lesson-to-execution behavior, lower search overhead, then a fresh separately authorized mechanism and adequately powered independent coding-task study. |
| #80 | Actual-loader/catalog checks, exact per-kind use evidence, scripted skills/configuration/description coverage and hosted skill use in the experience-withheld arm. | An updating skill mechanism and separate per-kind outcome qualification before default enablement; no hosted configuration or description claim is made. |
| #81 | Complete transitive portable source closure, fresh host approval, source-preserving export and consumer/rollback gates. | An independently qualified reusable improvement and its reviewed release; this pilot exported no independently confirmed asset. |

Concrete tuning should first test whether a workflow needs and actually loads a
procedure, and whether selective search can justify its full cost when a baseline
already finishes cheaply. Freeze those hypotheses and stopping rules before a
new run. Increasing repetitions of this graph task or repartitioning the exposed
benchmark pools cannot supply independent efficacy. The present findings leave
the parent and remaining children open, with no new default asset-kind authority.

Plan, registration, report and mechanism are copied byte for byte from this scope.
Raw transcripts, generated task solutions, grader source and the durable ledger
remain private under ignored `tmp/`. Public projections retain their original
byte hashes without credentials or solution text. `SHA256SUMS` binds this packet;
verify it from the repository root with:

```sh
cd docs/qualification/2026-11-05-rsi-v1.1
shasum -a 256 -c SHA256SUMS
```
