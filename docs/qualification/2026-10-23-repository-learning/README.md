# Repository learning development qualification

This is development evidence and grader qualification. No efficacy, independent
confirmation, cross-model transfer or default activation of a new asset kind is
established here. The [calibration summary](calibration-summary.json) retains
success, failure, usage and source-report digests without credentials or private
grading material.

The first three hosted calibrations found no headroom: Sol 6.1/high and
Luna/high completed the small coding fixtures, and Luna/high completed the
Bottle repository task. The first harder SymPy calibration reached its
24-request limit in both arms without completing the repair. Python bytecode
and pytest cache writes also exceeded the changed-workspace evidence limit.
Those failed runs remain recorded; incomplete evidence is not a pass.

The subsequent Sol 6.1/high calibration froze a normal 48-request horizon before execution.
Its disabled arm passed two of four previously exposed SymPy cases, with all
eight disabled/reference executions fully accounted for and complete workspace
evidence. The 154 new requests used 4,878,186 tokens. This establishes task
headroom, not improvement; agent finish reasons are retained separately from
artifact correctness. Concurrent local gates/preparation make its latency a
calibration diagnostic rather than a causal performance comparison. The
[summary](calibration-summary.json) preserves successes and failures.

The apparatus disables interpreter/test cache writes in the prepared image and
discloses the large immutable verification list on demand. The complete file list remains
checked. These changes reduce incidental context and filesystem work; they do
not establish improved task outcomes. A new runtime/image/manifest requires new
controls and calibration. The separately selected editor is Astra/high; the
calibrations above did not exercise an improver and do not qualify that model.

The [first hosted mechanism seed](hosted-mechanism-accounting-failure.json)
passed its visible and private checks and Astra produced three pointer-backed
lessons. The driver then stopped before any target execution because its inner
reflection receipt had unknown usage. All twelve physical calls and 119,908
tokens were recorded by the shared allowance. A deterministic regression
identified completion being forwarded before nested controllers settled; the
repair delays only terminal events. The original archive and unknown inner
receipt stay sealed. A new frozen runtime and output are required for another
mechanism run. This seed establishes no learning benefit or new-kind
qualification.

## Grader boundaries

The regression fixture demonstrated that workspace `pytest.py` and `json.py`
could impersonate the framework/parser and fabricate 999 passing checks. The
runner now starts Python in isolated mode, imports the installed framework
before project imports, and parses counts in a separate isolated interpreter.
Its real-Python regression observes the two installed verifier checks and
proves neither workspace module executed. Frozen minimum counts also prevent
skipping a failing check from turning the remaining passes into success.
These checks are scoped defenses, not a proof against every malicious program.

The source-preserving preparer exports the dataset's exact Git commit, not the
image's current `HEAD`. Its patch helper owns a temporary Git repository:
`git apply` below another repository can otherwise skip a patch and exit zero.
It requires changed bytes and removes the temporary metadata. Archives refuse
links, escaped paths and excessive expansion. Oracle and private tests remain
outside agent sources. The serving image removes repository history, installed
SymPy and package caches, and has no network during tasks or grading.

## Reproduce the exposed SymPy fixture

Preparation sends no model requests. It requires Docker, the pinned source
image, the existing local SWE-bench task snapshot and the pinned Elixir toolchain.
The image build installs the grader before freezing its immutable identity.

```sh
docker build --platform linux/amd64 -f priv/qualification/sympy.Dockerfile \
  -t lemieux-learning-swe-sympy:review priv/qualification
docker image inspect lemieux-learning-swe-sympy:review --format '{{.Id}}'

# Use that exact sha256:image ID. The output directory must be new.
mix run scripts/prepare_learning_repository.exs \
  --dataset tmp/swebench/manifest.private-dataset.json \
  --instance sympy__sympy-19040 \
  --source-image swebench/sweb.eval.x86_64.sympy_1776_sympy-19040@sha256:2238ea21e03d1548e7f3e5345fb924aba8459c99f8697270f8e04aa3661136b4 \
  --image sha256:YOUR_PREPARED_IMAGE_ID \
  --public-check priv/qualification/sympy_factorization_public.py \
  --output tmp/sympy-development-review
```

`manifest.json` binds exact source, image, private tests, frozen verification
files and required check counts. `controls.json` retains positive/negative
public/private results. Preparation refuses a passing original or a failing
oracle. Private snapshots and gold patches stay under the private output root;
never point an agent at that root. Each task sees only its copied `source`.
This adapter runs a SWE-derived pytest subset, not the official SWE-bench
benchmark evaluator. Function families include all parameter variants and same-named functions in
the copied selected files. Node IDs also retain unmodified selected test files
and their parent conftest files. This deliberately differs from official
benchmark selection. Function-selector and environment compatibility are
qualification preconditions; unsupported instances are retained as apparatus
failures before hosted work.

All four selected issues are previously exposed SymPy development cases. Shared
repository history cannot supply four independent streams. A causal ordering
can test retention and reuse, while uncertainty and generalization remain
limited by the single repository domain. Independent material must be frozen
and exposure-audited separately before confirmation.


## Fresh development domains

The [selection and exposure record](corpus-selection.json) pins [SWE-rebench](https://huggingface.co/datasets/nebius/SWE-rebench/tree/89cdfbab4ab1bd8f5a658bb212d1b63624f4f881)
revision `89cdfbab4ab1bd8f5a658bb212d1b63624f4f881` and the filtered Parquet
SHA-256 before case text was read. Metadata selection excludes the 18 locally
inspected SWE repositories, ranks eligible repositories by a fixed hash seed,
and takes chronological cases. Before hosted execution, the same rule was
extended from two to three cases per repository: one seed must precede two
targets for frozen and updating libraries to differ causally. This change used
no hosted outcomes. Case text was then disclosed to the curator; private
patches were handled by preparation code and never disclosed to a model.

The two new domains are `encode/typesystem` (16, 65, 122) and `hgrecco/pint`
(652, 920, 948). These are development cases, excluded from independent
confirmation. They were newly selected for this experiment; no claim is made
about model pretraining exposure. The [control summary](fresh-domain-controls.json)
contains exact source, image, private-grader and public-check identities.

`priv/qualification/python_repository.Dockerfile` prepares an immutable serving
image from an explicitly pinned source image, exact compatible pytest version,
distribution and import-module name. Both image interpreters must be unable to
find the target package after removal. Source trees are exported separately
from each exact dataset base. Serving images stay identical within a repository
stream; changing an image requires fresh controls and registration.

The reference implementation is projected onto the same frozen verification
and instruction bytes as every candidate. An oracle's docs/configuration edits
cannot invalidate the apparatus or relax the contract. Symlinks introduced by
a patch are refused before their targets are read. The Pint keyword-argument
reproduction and definitions side-effect check were corrected during provider-free
preparation; their earlier failed controls remain retained. The security check
observes absence of a harmless temporary-file callback, allowing parser-specific
rejection behavior. It does not require a particular exception class.

All six final fixtures pass positive/negative public and private controls.
Those controls establish a usable development apparatus, not learning benefit.
The broader metadata inventory has many more repository names, but fork/history
independence, exposure, source closures, images and grader controls still need
qualification before any independent cohort is claimed.


## Offline learning mechanism

The [mechanics summary](offline-mechanism-summary.json) retains both canaries.
The eight-request combined canary correctly withheld a full demonstration:
its procedure/helper path needs eleven requests, including the normal repair
and verification. The twelve-request canary passes every dataflow check:
retained seed, committed exposure, changed profile, actual procedure and helper
use, setting disclosure, and matched experience withholding. Both retain all
six arms and two repetitions, loader use, fixed verification and rollback.
This is scripted mechanics evidence only. The repository horizon remains 48;
no quality threshold or model output limit was changed to obtain this result.

The shared allowance can also wrap the scripted rehearsal. This exercises the
same admission roles before hosted work: the physical recorder retains
`asset_proposer` and `asset_critic`, while the controller admits their semantic
`proposer` and `critic` roles. The [second hosted scope](hosted-asset-role-failure.json) exposed the missing
mapping before its first asset request could dispatch; its incomplete records
remain unchanged. Its 280 physical calls and 1,919,829 tokens are fully known.
Further learning was opted out after the failure; the intervened sample makes
no efficacy claim. The [shared offline rehearsal](offline-shared-allowance-mechanism.json)
then passed every mechanism check and settled all 1,054 Scripted dispatches,
without borrowing credentials or changing the hosted allowance. Use a separate, new allowance directory for offline work:

```sh
mix run scripts/qualify_learning_study.exs --research --stage mechanism \
  --task-requests 12 --streams graph --assets \
  --allowance-dir tmp/new-scripted-allowance \
  --max-total-requests 5000 --max-total-tokens 50000000 \
  --max-total-time-ms 43200000 --output tmp/new-scripted-mechanism
```

Without `--allow-live`, this selects only Scripted providers and borrows no
Codex credentials. It validates routing and accounting, not model capability.

The [confirmation preparation status](confirmation-preparation-status.json)
records metadata screening of 483 candidate repository names and GitHub fork
metadata for the first 120. The [pinned ancestry audit](confirmation-history-audit.json)
then fetched complete, non-shallow commit ancestry for the three selected bases
in each of those 120 repositories. Its 204,461 distinct ancestor commits form
120 history groups with no shared-ancestry pair. This screens shared Git history;
it does not establish task independence or model pretraining novelty.

The [object inventory](confirmation-object-inventory.json) records zero file
blobs and nine unexpected tree metadata objects despite the requested `tree:0`
filter. The stricter zero-tree assertion failed and remains recorded. No source
worktree was created or case text, patches, commit messages or tree contents
disclosed to the model by this audit. Transitive exposure, source/evaluator and
image closures, positive/negative controls and a powered budget-feasible study
remain pending. The number of qualified independent streams remains zero; no
confirmation request has run.


## Complete reflection records

The [next hosted scope](hosted-source-bound-failure.json) completed an actual
profile and skill application with restoration, but its 1,261,606-byte complete
reflection source exceeded the preregistered 1 MiB source bound. Its 395 physical
requests and 2,972,660 tokens remain fully accounted for. The requested learning
opt-out took effect after the admitted experiment finished; the intervened
sample is not efficacy evidence. Its source, report and failed receipt remain
unchanged.

The [lossless component check](lossless-source-component.json) encodes that
record in 969,181 bytes and reconstructs its exact original digest. Complete
repeated observations and text are stored once, with every occurrence retained
in place through references. Citations resolve to real entries or shared-text
pointers. Canonical reconstruction rejects altered, missing, unused or cyclic
references and bounds expansion separately at 8 MiB. The existing 1 MiB source
wire limit, lesson wire limit and quality/verification thresholds stay fixed.
The host retains both original and encoded source files. Unrepeated oversized
sources still abstain before a provider call.

Research protocol v4 registers this encoding before any new hosted work. Earlier
scopes are not rescored or continued, and a new matching hosted mechanism receipt
is required before a larger study can advance.


## Actual learned skill for review

The [complete skill](learned-skill-review/SKILL.md), [asset record](learned-skill-review/asset-record.json)
and [provenance](learned-skill-review/provenance.json) preserve a real Astra/high
proposal from the source-bound failure above. Its original asset ID, digest and
all non-executable file bytes remain intact. The experimental critic approved
only an isolated trial; that is not human release review or independent
confirmation. The host applied the skill through its actual loader and restored
the harness. The surrounding incomplete learning scope prevents a qualification
claim even though the selected task artifact passed.

The archive's wire record did not retain the version's creation timestamp. This
packet records that omission; it does not invent a timestamp or reconstruct a
complete historical Version value. It exports no sessions, callbacks,
credentials, approval or active pointer. A receiving host still needs current
scope/runtime validation and fresh exact-digest approval. New-kind default
activation and qualified native packaging remain gated.

After compiling the checkout, verify the public records without credentials or
model requests:

```sh
mix run docs/qualification/2026-10-23-repository-learning/verify.exs
```

This check reconstructs the archived content digest and checks complete skill
bytes, linked history-report hashes and the explicit unassessed boundaries. It
does not run the source study again or establish provenance from a checksum.


The [provider-free archival rehearsal](offline-selected-source-archival.json)
passes all seven mechanism checks across six arms and two repetitions. It retains
twelve selected source trees, verifies their IDs, digests and complete files,
and observes twelve changed-scope refusals and twelve unapproved-activation
refusals. All 1,054 Scripted dispatches settle with 4,216 synthetic tokens. It
uses a separate simulation allowance and borrows no credentials. This tests
archival mechanics for future trials; it does not repair the earlier missing
timestamp, establish efficacy, or change a running hosted study's source.


## Live stock path and the next bounded source format

The [stock live supplement](stock-live-supplement.json) runs the ordinary host
assembly with Sol 6.1/high, the original shared subscription allowance and two
repetitions. Disabled and ordinary arms each pass four tasks using 35 physical
requests. The ordinary arm receives earlier experience on two later tasks and
performs four learning requests within its inherited job budgets. All eight
rows have complete evidence; the total is 70 requests and 339,816 tokens. These
small exposed fixtures establish live retention, reuse and nonregression, not
benefit or a manual terminal-canvas test.

The [next combined hosted scope](hosted-shared-text-bound-failure.json) retains
364 requests and 2,701,359 tokens with known physical usage. Its first complete
public record is 1,439,787 bytes, or 1,105,017 after version-one sharing. That
still exceeds the frozen 1 MiB bound and refuses before reflection dispatch.
Learning was then opted out; two rows are incomplete and the intervened scope
supports no efficacy claim. Its applied skill was never read through the skill
tool. Application, actual use and causal improvement remain distinct facts.

The [version-two component](shared-values-component.json) shares repeated value
subtrees, object shapes and repeated lines inside otherwise different text.
It retains every byte and position, supports the original version-one decoder,
and selects the smallest canonical supported representation. Both actual failed
records round-trip through lesson storage and complete disclosure in 654,491
and 743,403 source bytes. The source-wire limit remains 1 MiB, lesson-wire limit
2 MiB and expanded-source limit 8 MiB. Changed, missing, cyclic and injected
references are rejected. This is provider-free component evidence.

A deterministic regression also demonstrates a separate host resource problem:
a whole multi-stage experiment can exceed the source-reader worker's heap cap
during valid bounded processing. Whole experiments now have a finite
32-million-word ceiling; individual request and source-reader workers retain
their eight-million-word ceiling. Requests, tokens, time and dollar admission
stay unchanged. The [archival rehearsal above](offline-selected-source-archival.json)
retains its [original tested driver](selected-source-archival-driver-v1.ex.txt)
rather than being silently attributed to later source changes.

Research protocol v5 freezes explicit kind and helper scopes. For example,
`--assets --asset-only --asset-kinds skill --no-asset-helpers` admits only inert
text skills. A matching mechanism receipt cannot qualify configuration,
helper source or a profile search. Required checks and observed checks remain
separate in its receipt; unrequired mechanisms are not reported as observed.
The original combined protocol still requires every declared mechanism.
Empty or rejected candidate sets retain a baseline without paid task probes.
Explicit `file: "SKILL.md"` and the skill tool's default-file invocation both
count as reading the actual procedure. New kinds remain disabled by default.

## Fresh repository calibration and an actual learned native package

The [six-case fresh repository calibration](fresh-repository-calibration-v4.json)
retains 220 calls and 4,459,923 tokens with complete known usage. Typesystem's
three baselines pass, so it is a ceiling for this executor. Pint passes two of
three; both the disabled and reference arms fail the private outcome on case
948. The original metadata ordering selects Pint for a matching-runtime
calibration before a larger study. This is difficulty and cost evidence from
the earlier v4 runtime, without an improver or efficacy claim.

The [actual learned native packet](native-learned-skill-review/README.md)
contains a selected Astra/high text skill from one completed v5 mechanism
episode. It preserves the original source and creation timestamp, explicitly
derives a new unconfirmed receiving-scope identity, exports the native project
and installs it in a fresh Mix consumer. The real skill tool returns all 4,706
bytes to a fixed Scripted witness; removing the adaptation restores the
baseline exactly. Both identities, complete files, provenance, frozen-build
digests and consumer results are retained. The packet remains unassessed:
independent effectiveness, per-kind defaults and CodeGate qualification are
still pending.

## Completed v5 mechanism and interrupted Pint calibration

The [text-skill mechanism](hosted-text-skill-mechanism-v5.json) completed its seed
and twelve target rows across six arms and two repetitions. All 639 physical
calls and 6,602,336 tokens are measured, including proposer, critic, probes and
reflection. Six skills were applied and restored; all six selected executions
read the actual `SKILL.md`. The required seed retention, experience withholding,
lesson reuse and procedure checks were observed. Profile changes, helper
execution and setting changes were neither required nor observed.

This is one exposed synthetic Graph stream at a twelve-request task horizon.
The registered quality and efficiency endpoints remain inconclusive. Updating
used 186 requests including acquisition, versus 21 each for disabled and retry,
and 194 for the experience-withheld improver. Mechanics passing does not show
an improvement in capability or efficiency. The native packet above preserves
one actual selected skill from this completed scope.

The [matching v5 Pint calibration](pint-calibration-v5-incomplete.json) is
incomplete. Four calls report 15,401 tokens; a fifth ended with a server overload
without final usage. The shared allowance then refused dispatch, and five later
rows made no calls. The raw report's zero score is retained as an unusable
historical value. No ability score or headroom decision follows from this run.
The old row-level `qualification_complete` field describes retained artifacts;
it did not establish known token accounting. The corrected driver requires all
declared pairs, measured usage and actual dispatch before scoring a calibration,
retains incomplete reports, and exits unsuccessfully. Future physical records
also retain selected request identifiers and bounded failure categories without
raw provider details or credential headers.

The [approved allowance amendment](allowance-amendment-v2.json) increases the
same accumulated totals to 7,500 requests, 100 million tokens and 24 hours from
the original start. Its deadline is 2026-10-24 16:48:24.112 UTC. The amendment
preserves all 2,323 prior physical requests, 26,773,752 known tokens, one unknown
charge, and the historical checkpoint bytes. It makes no new model call. The
versioned registration atomically stores authority and accounting together;
older readers refuse it. Record capacity is bounded at 8,192 and checkpoint
size at 4 MiB. Unknown usage continues to block admission. No estimate is
substituted for the missing charge.

The [provider-free capacity component](pint-source-capacity-component.json)
also identifies remaining apparatus work before a large Pint study. A composite
of six distinct prior coding observations and two repetitions round-trips
exactly but encodes to 1,154,735 bytes, above the unchanged 1 MiB source bound.
This mixed-case codec stress is not a complete future experiment and does not
predict its exact size. Short tuple and line-body syntax prototypes also remained
above the bound; they are not implemented codecs. No new source format is
qualified by this component.

Project the sealed private v5 runs without editing them or sending requests:

```sh
python3 docs/qualification/2026-10-23-repository-learning/project-v5.py \
  PRIVATE_ARTIFACT_PARENT NEW_PUBLIC_OUTPUT_DIRECTORY
```

The fixed Pint six-arm, two-repetition, 48-request study has not started.
Unknown-charge handling, source capacity, a fresh matching mechanism for any
changed runtime, independent source/evaluator/image closures and controls, and
powered independent confirmation remain outstanding. No per-kind default or
release readiness claim is made.

## Bounded tuple source and a frozen v6 rehearsal

The [tuple component](shared-tuples-component.json) reconstructs the same
2,043,862-byte Pint composite whose v2 encoding exceeded the source bound above.
Short references and shared numbered-line bodies preserve all original numbers,
tabs, newlines, text and trajectory positions. The readable wire representation
is 1,041,756 bytes. The original digest remains
`b399e180e346235ae4816d5bb33d6124fc314190e32039934844c9c212caac16`.

The real reflection builder stores that complete source in a 1,391,849-byte
unconfirmed lesson. Lesson encode/decode and the actual retrieval reader return
the full artifact without truncation, and expansion reproduces the original
digest. Existing canonical plain, v1 and v2 readers remain unchanged. Tests cover
literal tag escapes, malformed JSON shapes, missing/changed/cyclic/unused tables,
reference amplification, valid citations and a source at the exact 8 MiB
expanded ceiling. A small independently bounded intermediate wrapper permits
that exact-limit source; the expanded-source ceiling remains unchanged.

This is still a mixed-case codec component, not a future complete experiment or
capability result. Its successful wire size does not guarantee that every future
source will fit. Larger unshared records still refuse retention. The source,
lesson and expanded limits remain 1 MiB, 2 MiB and 8 MiB respectively.

The [retained provider-free driver](shared-tuples-component-driver-v1.ex.txt)
accepts an existing complete public source JSON and a new summary filename. Its
fixture context constructs unconfirmed data for archival testing; it grants no
receiving-host authority and invokes no provider:

```sh
MIX_ENV=test mix run \
  docs/qualification/2026-10-23-repository-learning/shared-tuples-component-driver-v1.ex.txt \
  PRIVATE_PUBLIC_RECORD_JSON NEW_COMPONENT_SUMMARY_JSON
```

The [v6 Scripted rehearsal](offline-shared-tuples-mechanism-v6.json) ran on clean
source revision `19b6b815c693ab5c157c2b5a1985811c5ab1d36f`, with twelve target
rows and one seed across six arms and two repetitions. Its isolated simulation
allowance recorded 436 completed Scripted calls and 1,744 synthetic tokens.
Six source trees were archived, six skills applied and six restored. All declared
text-skill mechanisms passed; profile, helper and setting mechanisms were neither
required nor observed. No credentials were borrowed or hosted allowance used.
This tests apparatus and dataflow, with no effectiveness inference.

Protocol v6 registers the new format before hosted work. It requires a new
matching hosted mechanism and calibration before the larger study. The previous
v5 hosted receipt cannot satisfy its changed binding. No complete v6 hosted mechanism or
independent confirmation is included in this packet.

## Explicit reserve for the interrupted task

The [approved reserve](approved-usage-reserve.json) records the user's explicit
authorization to charge 2,000,000 tokens from the existing 100-million-token
allowance for the single unmeasured Pint task call. Its actual usage and original
record remain unknown and unchanged. The 26,773,752 known tokens plus this
reserve produce a separate 28,773,752-token admission charge. All 2,323 request
charges, the original checkpoint bytes, limits and October 24 16:48:24.112 UTC
deadline remain intact. Applying the reserve sent no hosted request and did not
qualify or rescore the failed calibration.

The receipt binds that exact unknown task record. A future unmeasured call has
no reserve and closes admission again. Checkpoint version two separates actual
usage from the conservative budget charge and refuses older readers. Tests cover
restart, unchanged history, expired deadlines, existing token limits, stale or
duplicate approval, record tampering, wrong roles and a subsequent unknown call.


## Interrupted v6 mechanism and isolated-host transport

The [fresh mechanism audit](fresh-mechanism-transport-failure.json) retains the
October 28 attempt at `95988bd04b3d533effe246b41b902c3a01a433a0`. Its first
repetition completed, including three skill applications and three restorations.
A socket closure during the second repetition left one task request without
usage. All thirteen rows remain retained; four are unusable, including rows
that made no physical request after admission closed. The mechanism gate refused
this incomplete archive. It supplies no efficacy or qualification result.

The attempt made 360 physical requests. The 359 measured calls used 3,609,095
tokens, including 2,778 known tokens from an incomplete row. Summing only complete
rows would omit that spend. The raw plan, report, episode evidence and process
log remain locally retained under
`tmp/learning-text-skill-sol-astra-mechanism12-v6-reserved-retry-2026-10-28`;
the audit publishes their digests without publishing credentials or transcripts.

The [fixed-window receipt](approved-fixed-window.json) records the separately
approved deadline of October 30 00:28:26.914 UTC, preserving the original start,
all elapsed time, and the 7,500-request / 100-million-token accumulated caps.
The [third exact reserve](approved-task-reserve-3.json) charges 2,000,000 tokens
from that cap for the socket-closed task, using the previously authorized bounded
reserve policy. It changes no original request or measured usage. At that
snapshot there were 2,689 requests, 30,401,276 known tokens, three unknown task
calls, and a separate 36,401,276-token admission charge. One further exact
2-million-token task reserve remains authorized; unknown improver usage remains
uncovered. These receipts describe historical authorization, not transferable
host authority. The original one-off snapshot wrappers used atom-keyed limit
maps when computing their outer digests. The public snapshots normalize those
wrappers to canonical string-keyed JSON and bind the original local bytes and
recorded wrapper digest. Their nested sealed authorization receipts and the
actual allowance checkpoint remain unchanged.

The isolated qualification host now configures req_llm's supported HTTP/1 pool
with a zero connection idle lifetime before starting work. A returned socket is
closed at its next checkout. A local socket test exercises the real streaming
provider: default pooling reuses a connection, while this policy opens distinct
connections for the two requests without adding a hidden dispatch. Pool
destinations, TLS options and sizing are preserved, and repeated preparation is
a no-op. Ordinary `lmx` and embedded hosts retain their own pool settings.

The socket closure's remote cause remains unknown. Fresh connections remove a
reuse failure mode; they do not establish provider reliability. Models, task
selection, verification, repetitions and unknown-usage rules remain fixed. The
registered transport policy is part of the mechanism binding, so the next
hosted mechanism must complete on the new revision before a larger study.
