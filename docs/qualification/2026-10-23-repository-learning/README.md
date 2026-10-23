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

The next protocol must freeze a normal 48-request horizon before execution,
disable interpreter/test cache writes in the prepared image, and disclose the
large immutable verification list on demand. The complete file list remains
checked. These changes reduce incidental context and filesystem work; they do
not establish improved task outcomes. A new runtime/image/manifest requires new
controls and calibration. The separately selected editor is Astra/high; the
calibrations above did not exercise an improver and do not qualify that model.

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
benchmark evaluator. Function-selector and environment compatibility are
qualification preconditions; unsupported instances are retained as apparatus
failures before hosted work.

All four selected issues are previously exposed SymPy development cases. Shared
repository history cannot supply four independent streams. A causal ordering
can test retention and reuse, while uncertainty and generalization remain
limited by the single repository domain. Independent material must be frozen
and exposure-audited separately before confirmation.
