# Consecutive feedback and provenance qualification

The next qualification step after [the public-feedback calibration](../2026-11-06-rsi-feedback/README.md)
is to obtain credible cases from use and establish a supported skill mechanism
before attempting independent efficacy. This audit reviews the first twenty
records in a frozen 42-record local feedback ledger. It finds and reproduces a
provenance defect, adds a source-membership gate, and retains the nonpassing
curation result. Issues #47, #79, #80 and #81 remain open.

## Consecutive review

The complete inventory was frozen before inspecting its contents. The formal
[review protocol](review-protocol.json) follows initial text inspection; this is
a retrospective consecutive census, not a blinded prospective experiment.
Selection uses original creation time and ID, with no substitution from later
records. The first twenty records have nine original human actor labels and
eleven model actor labels, from three historical sessions in one project.
The reviewer is a model curator. Neither authorship nor review is relabelled as
independent human approval. Raw feedback and transcripts remain private.

The [audit](audit.json) resolves every primary anchor and every model citation
against its source transcript. One primary anchor is absent. A second record
has a present primary anchor but two absent supporting citations. Thus two of
the eleven mined records cite entries absent from their own source session.
The remaining entries' existence does not establish their claims' truth.

Every record retains an individual [decision](decisions.json). Follow-ups,
revised diagnoses and repetitions remain related evidence. Missing provider
state, runtime/source pins, original input bytes or outcome controls are not
filled with inferred values. No new case passes this review. Historical
per-item curation times are unavailable; the median endpoint is unavailable.
This does **not** satisfy V2's ordinary-use qualification: at least ten approved
cases, measured curation time and regression controls remain required. It also
does not supply independent learning streams for V9 or #79.

## Reproduced defect and correction

The [native driver](audit_feedback.exs) replays the defective record's actual
citation list with neutral probe wording into owned stores. The baseline
`Opportunities.record/4` from commit `76cea61` accepts the missing entry. The
corrected implementation refuses it before writing any feedback. A separate
synthetic valid-citation control passes. No provider is invoked, no historical
claim is repaired or reattributed, and the original record is untouched.

`mine/2` now checks every cited ID against the bounded evidence actually shown
to its model. An ID from an omitted event is refused too. CLI mining and
interactive harvesting pass host-resolved `source_entries:` into recording.
Direct callers of the experimental `record/4` must supply them for nonempty
batches. Every citation and any fallback must belong to that source before the
first append. A later storage error can still leave a partially written batch.

New records bind to canonical source-entry bytes and count, and distinguish
`citation` from `fallback`. A host anchor does not turn an uncited finding into
a model citation. The gate establishes membership, not entailment, correctness,
case approval, an improvement or activation authority. Existing records keep
their original bytes. Invalid raw mining answers remain in their reflection
transcripts; the refusal makes no format-repair or other hosted request.

## Legacy grader controls

Two related promoted fixtures already exist. On owned copies, each legacy
answer grader rejects a wrong value and accepts its correct value, but also
accepts a refusal that mentions both the correct value and a wrong alternative.
These are deliberately constructed diagnostic answers, not historical model
outputs. Substring acceptance does not establish an unambiguous answer or use
of the required tool. Neither grader earns a new approval from this audit.

The experiments manifest also lacks a version and is refused by the current
manifest reader. The audit retains that refusal. Its trusted isolated task
grader is inspected through the native task parser solely to diagnose the
grader; this does not import or qualify the rejected manifest. No historical
scores, verification files, source fixtures or manifest bytes are changed.

## Validation and remaining gates

The focused reflection, CLI, feedback, flow and boundary checks pass. The
[validation record](validation.json) retains the initial test-first and audit
failures as well as final results. No hosted request is needed to reproduce or
qualify this provenance correction.

All eight [scripted benchmark canaries](benchmark.json) also execute and pass in
fresh containers against the corrected library. The task-owned apparatus and
library files are pinned in the receipt; the primary benchmark checkout receives
no writes. The intentional scripted retry is retained in its log. These host
contracts do not establish a learning benefit.

Fresh repository preparation also exposed an apparatus defect: `git archive`
on a commit adds a global metadata entry that the strict extractor refuses.
The preparer now archives that exact commit's tree. A real-Git regression
advances HEAD and adds uncommitted edits before preparation; the extracted
source still matches the pinned commit. [Paired controls](archive-controls.json)
on two actual repository archives preserve every source-file byte, reject both
original commit archives and accept both tree archives. Accepted member types,
path checks and no-overwrite rules remain unchanged.

The actual [source-image transport control](platform-control.json) finds a
second archive problem on the ARM host: Docker emits an architecture warning
into the bounded runner's merged output. That corrupts the tar checksum. The
preparer now resolves the immutable source image's platform before execution.
The same source-image smoke check then produces a valid archive and passes
strict extraction, with all 1,761 regular files' bytes preserved. Malformed
platform metadata refuses before private output or archive execution. Other
unexpected archive output continues to fail closed.

Further efficacy requires cases with pinned pre-effect inputs and runtime,
public baseline/repair controls, source exposure retained, and a genuinely
failed public baseline to admit selective refinement. Freeze the complete
mechanism protocol, model/effort and shared allowance before dispatch. Fresh
independent confirmation and qualified export remain separate later gates.

Reproduce the private-input audit into a new output path:

```sh
mix run --no-start docs/qualification/2026-11-06-rsi-provenance/audit_feedback.exs \
  PRIVATE_SNAPSHOT NEW_OUTPUT.json
```

The public packet can be checked without private content, models or graders:

```sh
mix run --no-start docs/qualification/2026-11-06-rsi-provenance/verify.exs
```
