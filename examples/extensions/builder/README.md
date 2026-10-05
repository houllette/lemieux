# First-party builder as an ordinary extension

- **What it shows:** the guided extension builder that ships in Lemieux,
  driven through the same Agent, Workbench, Build and Confirmation interfaces
  an outside extension would use.
- **Runs offline?** Partly. `mix compile` needs nothing, and the root test
  suite runs this package's graders offline. Every bench here is a live run.
- **Needs:** `LMX_MODEL` and that provider's key, plus either dollar caps
  (metered) or request bounds (a quota subscription), as below.

This package exercises the shipped `Lemieux.Learning.Builder` through the same
Agent, Workbench, Build and Confirmation interfaces as an external extension.
The implementation lives in the base library; its exact BEAM bytes are captured
as a dependency when this adapter is frozen. This is an integration fixture,
not evidence that the guided prompt beats a general coding agent.

Set `LEMIEUX_EXTENSION_BASE` to the current Lemieux checkout, run `mix deps.get`,
then set `LMX_MODEL` and choose either:

- Metered: `BUILDER_BENCH_CAP_USD` and `BUILDER_ATTEMPT_CAP_USD` (decimal dollars).
- Subscription: `BUILDER_USAGE_MODE=quota`, optionally
  `BUILDER_MAX_ATTEMPTS` (default 12) and `BUILDER_REQUESTS_PER_ATTEMPT` (default 12).

For Z.AI Coding Plan use the `zai_coding_plan` provider. These are host inputs;
never put keys in this package. Request bounds do not measure remaining provider
quota. The freeze config preserves the chosen quota or metered session bound.

Run `mix lemieux.extension.workbench bench/workbench.exs` and review the plan
before `run`. The two arms differ only in their system instructions; both get
the same deterministic workflow tool. The exposed development cases check
artifact creation and handling an incomplete brief. Their mechanical graders
are intentionally narrow and need expansion for code quality, question quality,
preservation of existing work, unsupported model selections and refinement skill.

For model/effort search, create a `tmp/models.json` shortlist and use
`mix lemieux.extension.compare bench/workbench.exs tmp/models.json`. That command
uses the first configured arm (`plain`) as its base; change the order to search
the guided agent. Review a plan before adding `--allow-live`. Compare one surface
at a time so a model change is not mistaken for a prompting improvement.

Update `bench/freeze.exs` with the exact chosen profile before freezing. The
default builder profile is only a starting point. Independent confirmation
requires new cases and a separate evaluator/host exposure ledger. These public
starter cases have already been seen and cannot become hidden evidence.

Installed entry points:

    lmx --build-ext
    lmx run "Review my extension plan" --build-ext

For quota subscriptions add `--quota` to the builder entry points above. From a
source checkout without an installed `lmx`, run them from the Lemieux root as
`mise exec -- mix lmx -C /path/to/your/project --build-ext`: `-C` makes your
project, not the Lemieux checkout, the directory the builder works in.

## Refinement checks

`bench/refinement.exs` compares default and low effort on four development cases,
with two repetitions each. It checks a seeded quota defect, a clean source audit,
repair of an existing profile, and preservation of interrupted work. Related
cases share two family IDs; repetitions do not create independent samples.

Set `LMX_MODEL` (the recorded runs used `zai_coding_plan:glm-5.3`),
`LEMIEUX_EXTENSION_BASE`, and optionally `BUILDER_REFINEMENT_DIR` (default
`tmp/refinement`), then run:

    mix lemieux.extension.workbench bench/refinement.exs

The plan allows 16 attempts, two concurrent workers, and at most 12 direct
requests per attempt. This is quota execution, without a dollar cap. The model
must advertise both selected effort values on the configured connection. Live
execution still requires authorization. Reopening verifies the original input
snapshot; use a new directory to evaluate new source inputs. These cases
have been seen during development; do not reuse them as hidden confirmation
cases.

This configuration compares effort on the current builder instructions. To
compare instruction changes, retain the old full profile as the control and
construct a candidate profile through the same Agent/Workbench contracts. Keep
both arms' cases and resource limits identical. A correct artifact, a completed
run and a general quality claim are different outcomes.

## Confirmation checks

`bench/confirmation.exs` independently confirms the builder recipe tuned on
GLM-5.3, on four case clusters its tuning never saw: a budget/admission
source audit (clean and seeded), native-tool authoring and registration, a
path dependency with a consistent export manifest, and two maintenance tasks,
with two cases each. The control arm is
the archived original profile (`bench/confirmation_control_profile.json`,
byte for byte); the candidate is `Builder.profile/1` piped through
`Profile.quota/2`, exactly as `bench/refinement.exs` builds its arms.

Set `LMX_MODEL=zai_coding_plan:glm-5.3`, `LMX_ROUTER=direct`,
`LEMIEUX_EXTENSION_BASE`, `BUILDER_CONFIRMATION_DIR` and
`BUILDER_AUTHORING_ITERATIONS`, then freeze before anything runs:

    mix run bench/confirmation_freeze.exs
    mix lemieux.extension.workbench bench/confirmation.exs

The freeze seals the fixture inputs and writes `frozen.json` (both profiles,
every bench and input digest, the sample, budget, runtime, grader digest,
predeclared decision rule and authoring cost). The workbench configuration
refuses to open unless that plan matches the files it loads, and refuses an
Ixway-routed provider because only the direct Z.AI connection is authorized.
The grader compiles the native-tool cases offline against the checkout's
`_build/dev` ebin directories, so compile the base checkout first. Once
dispatched, these eight cases are exposed development material; they cannot
be relabeled as hidden confirmation evidence.
