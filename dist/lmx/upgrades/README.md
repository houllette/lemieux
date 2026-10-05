# Release upgrade decisions

Every candidate has a committed `upgrades/VERSION.exs` with `schema_version: 1`,
`version`, `from`, `reviewed: true`, and a `targets` map. Every platform needs an
explicit mode and reason, including restart decisions. The predecessor must be
GitHub's latest stable release. `0.8.0.exs` records the first-release exception:
`from: nil` and `mode: :initial`, permitted only while no stable release exists.

Follow [Upgrade decisions](../../../RELEASING.md#upgrade-decisions) in
RELEASING.md before tagging. Every declared hot target must ship
`releases/VERSION/relup`, `lib/lemieux-VERSION/ebin/lemieux.appup`, and
`lib/lmx-VERSION/ebin/lmx.appup`. The generated terms must include the exact
predecessor in both upgrade and downgrade lists. Inspect both the assembled
tree and packaged archive, then qualify those actual bytes with `--expect-hot`.
Initial and explicitly reviewed restart paths omit relup and declare no hot
predecessors. A missing relup cannot be waived for a hot decision.

## Inspect and draft in Elixir

Run from `dist/lmx` on each matching build host:

```sh
mise exec -- mix lmx.upgrade.unpack --archive /tmp/lmx_macos_silicon.tar.gz \
  --checksums /tmp/SHA256SUMS --output /tmp/previous
MIX_ENV=prod mise exec -- mix release --overwrite
mise exec -- mix lmx.upgrade.draft --from /tmp/previous \
  --to _build/prod/rel/lmx --output upgrades/0.1.1.exs
```

The task prints a JSON report of identities and changed/added/removed modules,
and writes an **unreviewed** restart draft. It never overwrites a plan. Compare
each platform's report and merge decisions deliberately. A BEAM diff locates
review work; it does not establish state compatibility. Read the concrete
review procedure in [AGENTS.md](AGENTS.md).

A restart decision has `mode: :restart` and a concrete `reason`. A hot decision
also pins the exact `from_build`, lists changed modules under
`modules: %{lemieux: [...], lmx: [...]}`, and supplies a `review` map with concrete
`state`, `messages`, `closures`, and `rollback` notes. Name affected processes,
invariants, functions and tests. Each module list must exactly cover the diff.

State migrations and new/removed modules are unsupported for hot paths. ERTS,
Elixir, dependency code, static configuration and native assets must match
exactly. The build hashes dependency BEAMs even when their versions are unchanged.
Windows uses restart. Soft purge protects processes executing old code, not
stored anonymous functions: those require a callback inventory and tests.
Uncertainty earns a restart decision and a reason. Placeholder review notes and
unreviewed drafts cannot pass the gate.

## Build and qualify the decision

```sh
mise exec -- mix lmx.upgrade.check --latest 0.8.0
LMX_TARGET=macos_silicon LMX_REQUIRE_UPGRADE_PLAN=1 \
  LMX_UPGRADE_FROM=/tmp/previous MIX_ENV=prod \
  mise exec -- mix release --overwrite
python3 ../../test/release_upgrade_smoke.py \
  --from /tmp/lmx_macos_silicon.tar.gz --to /tmp/candidate/lmx_macos_silicon.tar.gz \
  --expect-hot --report /tmp/upgrade-report-macos_silicon.json
```

The builder writes both appups from the reviewed module lists and calls
`:systools.make_relup` for upgrade and downgrade; errors or warnings fail the
build. Review the source plan instead of hand-editing those generated files.
Check that `release.json` advertises the exact reviewed predecessor/build and
module list, and that restart/initial archives omit relup and advertise empty
`upgrade_from` and `hot_modules`.

Omit `--expect-hot` for a restart decision. Local builds without a predecessor
remain restart-only inspection archives. Candidate CI sets
`LMX_REQUIRE_UPGRADE_PLAN=1`, checks the latest stable predecessor, downloads and
checksums its exact archive, builds the declared platform path, and tests those
actual archives. Hot qualification preserves the TUI/editor, checks live
downgrade and cold boot, keeps the existing session usable for another turn,
forces restart fallback and interrupted preparation, checks failed-health
rollback and quarantine, and resumes an old transcript
using real packaged tools. Windows qualifies manual restart/resume.

The candidate includes the plan and per-platform JSON reports. Assembly checks
their candidate/plan checksums and exact predecessor; a hot archive without
upgrade/downgrade and recovery evidence fails assembly. The synthetic three-version fixture
is an additional regression check and cannot qualify a different artifact.

The outer smoke driver uses Python's standard library to own processes and
archives across VM exits. Plan generation, validation and relup construction
live in Elixir. An LLM review note cannot replace qualification of the published
bytes. Platform and terminal [qualification](../../../RELEASING.md#qualification)
runs before tagging, and the maintainer signs the release only after it.
