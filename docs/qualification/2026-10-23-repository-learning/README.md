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
image, the existing local SWE-bench task snapshot and Python 3.13 or newer.
The image build installs the grader before freezing its immutable identity.

```sh
docker build --platform linux/amd64 -f priv/qualification/sympy.Dockerfile \
  -t lemieux-learning-swe-sympy:review priv/qualification
docker image inspect lemieux-learning-swe-sympy:review --format '{{.Id}}'

# Use that exact sha256:image ID. The output directory must be new.
python3 scripts/prepare_learning_repository.py \
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
metadata for the first 120. No source/evaluator controls or transitive history
and exposure qualification are established by that screening. The number of
qualified independent streams remains zero; no confirmation request has run.


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
