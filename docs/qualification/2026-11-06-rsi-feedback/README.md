# Reviewed public feedback for RSI

The [preceding calibration](https://github.com/houllette/lemieux/pull/123)
admitted no selective mechanism trial: its later baselines passed public checks
despite private failures. This follow-up implements matched verifier review and
tests additive public checks against the retained Pint-948 artifact. It does not
change the original scores, establish a learning benefit or close #47, #79, #80
or #81.

## Implemented case review

`lmx corpus review DRAFT_DIR --reference REPAIRED_DIR --allow SOURCE_PATH`
runs the same verifier on separate scratch copies of a frozen draft and repaired
reference, without changing the corpus. Only explicitly named implementation
files may differ. It requires the declared failure status on the untouched copy and a
passing reference, with no timeout or verifier writes. It rejects stale drafts,
changed verification files, linked inputs and unavailable executables. The
default failure status is 1; another verifier protocol must explicitly select
its status with `--failure-exit-status`, which is retained in the receipt. Input
changes during review invalidate the result.

`lmx corpus promote ... --reference REPAIRED_DIR` reruns those controls and binds
the copied fixture to the passing receipt before updating the manifest. Existing
promotion without a reference stays available, with verification marked
`unassessed`. A reviewer still inspects requirements, public checks, allowed
paths, secrets and provenance. The receipt grants no asset activation authority.
Benchmark snapshots exclude Git metadata, editor state, build output and installed
dependencies. Command graders retain the host's authority; these Pint controls
use a pinned image and networkless, non-root containers.

## Public regression diagnostic

The additive checks were frozen before evaluating the artifact. They cover both
reported definition entry points and safe numeric expressions from the existing
source and public documentation/tests. No private test supplied a check. The
unchanged arithmetic expression `273.15 - 32 * 5 / 9` works on the original
implementation but fails in the retained model artifact.

| Filesystem | Checks passed | Result |
| --- | ---: | --- |
| Original source | 7/12 | Rejects the negative control: unsafe function calls still have effects. |
| Retained model artifact | 11/12 | Detects a public arithmetic regression. |
| Historical reference | 11/12 | Also fails the arithmetic regression; not accepted as a positive control. |
| Reviewed owner-written reference | 12/12 | Passes the matched positive control. |

All four receive the same original public check plus the same eleven additive
checks. The owner-written reference changes only `pint/definitions.py`; it uses
bounded numeric AST evaluation in both reported entry points. It is a development
control, not a learned asset or a production security certification. Its first
attempt used an AST interface absent from the pinned Python runtime; that failed
control remains recorded. The checks were unchanged when correcting the reference.
An earlier review also refused an extra changelog change in the historical
reference; the later matched copies restore every non-implementation file.

The diagnostic uses zero hosted requests. No private grader is mounted, the model
is not rerun, and the captured artifact is bound to its retained evidence and
workspace snapshot. The public regression is real; whether it caused the original
private failure is **not established**. The reference and captured artifact's
failures are development findings, not a new benchmark improvement score.

A later pilot preflight also requires the older private control. The first
owner reference passed 12/12 public checks but only 4/6 private checks, so the
fixture freezer refused it before any hosted request. Inspection found an
exception-type contract for nonnumeric prefix/offset values. The retained
[curation record](pilot-curation.json) explicitly marks this private-feedback
exposure. A **new case version** makes the `ValueError` requirement public,
adds two representative public checks and normalizes the reference's parse
errors. The original twelve checks, private test bytes, historical outcomes
and [refused control](pilot-controls-refused.json) remain unchanged. This
development curation does not create independent confirmation material.
The revised controls pass 14/14 public checks and 6/6 private checks; the
untouched source fails both. All old private test bytes are unchanged.

The [product-command exercise](feedback-workflow.json) anchors model-curated
mechanical feedback to the original session and entry, drafts the retained
artifact through `lmx feedback draft-case`, then runs `corpus review` and
`corpus promote --reference`. The retained artifact passes 11/14 revised public
checks; the repaired reference passes. Promotion adds one case to an owned
private copy of an existing development manifest and reruns the controls. This
is agent review of benchmark feedback, not twenty ordinary-use items or an
independently qualified improvement. The [driver](exercise_feedback.exs) and
source ancestry remain available for inspection.

## Capped hosted calibration

The [protocol](protocol.json), both registrations and the public selection rule
were frozen at clean commit `8f646960f492c66b68ba756c256393d77a4b3e35` before
dispatch. The new shared allowance was 1,200 requests, 8 million tokens and two
hours. Tasks use GPT-6 Luna/low; GPT-6 Sol/high was registered for proposing and
reflection. The route is the Codex subscription. Dollar fields in native records
are informational model price estimates, not API billing or quota charges.

The [calibration](hosted-study.json) completed both registered episodes:

| Arm | Public checks | Private checks | Requests | Tokens |
| --- | ---: | ---: | ---: | ---: |
| Learning disabled | 14/14 | 6/6 | 12 | 144,304 |
| Fixed generic workflow guidance | 14/14 | 6/6 | 15 | 251,312 |

Both originals completed without provider errors or safety failures. The fixed
guidance arm receives no repaired-reference code. These two observations from
one exposed case do not estimate a population success rate or learning benefit.
The private checks are the unchanged exposed development controls, not an
independent holdout. Their results never select a target.

The [frozen selector](select_target.py) requires failed public verification in
the disabled original and a passing reference original. Both passed, so
[selection](calibration-selection.json) admits no target. Hosted work stopped
there, before seed acquisition, proposing, reflection or the conditional twelve
mechanism episodes. The cap did not cause the stop. The unexecuted mechanism
registration remains recorded; its 3,809-request maximum plus calibration's
586-request maximum exceeded the shared cap, so even admission would not have
guaranteed a complete sample. No task-local asset or qualified export resulted.

The [native audit](calibration-audit.json) reconstructs the report, verifies both
original and selected transcripts, and matches unique physical dispatches to
the [durable controller](calibration-controller.json): **27 requests and 395,616
tokens**, with no unknown usage or learning calls. Executed registration bytes
match the frozen registration. [Cleanup](cleanup.json) confirms no active
requests, task-owned containers, credential loan or allowance owner lock. The
original allowance, deadline and consumption remain retained; none were reset.

## Local validation

All eight [benchmark canaries](benchmark.json) passed with scripted providers.
The retained apparatus matches its 69-file inventory plus its required Python
helper; the first incomplete-copy compilation failure is retained as unavailable,
with no scenario executed. Library code trees and dependency/toolchain files are
bound in the receipt. The primary benchmark checkout receives no writes.

The first full gate failed with an experimental-label omission, timing failures
and 33 setup/cleanup invalidations. The complete result remains in
[validation](validation.json). The label was corrected. A seeded isolated run
passed 8/9 cases; the remaining installed-consumer roundtrip hit a ten-second
startup budget. A separate test-only commit uses the existing minute budget,
retaining all loading, identity, artifact and rollback assertions. Seeds 101,
102 and 103 then passed. The other targeted recovery passed all 77 cases.
Dirty-tree divergence remains a suspect, not proof of a clean-SHA flake. The
subsequent full gate runs serially without changing assertions or suite timeouts.
That gate passed 6,089 ordinary and 6,089 coverage cases, with 86.73% coverage,
zero Dialyzer errors and 123 release-host tests. Library and release-host audits,
formatting, Credo, xref and documentation checks passed. The coverage log retains
a reloaded/unloaded test-fixture warning. Four earlier test-first failures are
intentional regression witnesses; they are not intermittent results of one tree.

## Qualification boundary

These fixtures are already exposed development material from one repository.
They do not supply independent streams or satisfy roadmap V2's twenty consecutive
ordinary-use reviews. The implemented path and matched controls pass; the hosted
calibration gives no eligible failure to refine. The next qualification gate is
to curate ordinary-use feedback into reviewed public cases, retain their exposure
and find a genuinely failed baseline before admitting a skill mechanism trial.
Private grades cannot select it. An adequately powered fresh multi-stream corpus
and independent confirmation remain necessary for efficacy, typed-asset and
qualified-export claims. Issues #47, #79, #80 and #81 remain open.

The public packet retains check registrations, failed controls, the executable
reference transform, driver, sealed reports and validation receipts. Integrity
checks do not authenticate private data or replace review of grader correctness.

Verify the public packet without model calls:

```sh
mix run --no-start docs/qualification/2026-11-06-rsi-feedback/verify.exs
```
