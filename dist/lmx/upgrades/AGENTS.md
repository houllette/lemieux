# Preparing a release decision

Every candidate needs a committed `VERSION.exs` in this directory. CI rejects a
missing or unreviewed decision, a predecessor other than GitHub's latest stable
release, an omitted platform, and unqualified hot artifacts. Do this as part of
the version bump, before tagging. Restart is an explicit supported decision.
Follow [Upgrade decisions](../../../RELEASING.md#upgrade-decisions) in
RELEASING.md.
Every declared hot target must ship a generated relup and both appups;
only initial and reviewed restart decisions may omit relup.

1. Keep `VERSION` and the root `mix.exs` version literal in sync; the release
   host reads `VERSION`. Read `Lmx.UpgradePlan`, `Lmx.Release`, `Lmx.Update`, this directory's README,
   `RELEASING.md` and `docs/support.md`. Fetch the exact prior published archive and its
   SHA256SUMS for each platform; unpack with `mix lmx.upgrade.unpack`.
2. Build a local restart-only candidate first, then run `mix lmx.upgrade.draft
   --from OLD_ROOT --to NEW_ROOT --output upgrades/VERSION.exs`. This produces
   an **unreviewed** draft and a JSON module diff. Keep an existing plan; compare
   subsequent platform reports and merge their decisions deliberately.
3. Inspect each changed module and every process that holds its data or calls
   it. Review structs/map keys, GenServer state, pending messages, captured
   functions, user hooks, ETS/persistent terms, supervision, configuration and
   transcript schema. Inspect callers and old references as well as function
   bodies. A list of changed BEAMs is not compatibility evidence.
   OTP soft purge ignores indirect references through anonymous functions.
   Inventory retained local callbacks in process state, other processes, ETS
   and persistent terms. Use restart when changing their defining module unless
   their safe replacement is explicitly implemented and tested. The runtime
   guard checks TUI/session state and persistent terms; it is not a whole-VM proof.
4. Record a reason for every platform. A hot decision pins `from_build` and
   supplies `state`, `messages`, `closures`, and `rollback` review notes beside
   its exact module list. Describe concrete invariants/functions/tests in those
   notes. Use restart for state/schema migrations, module additions/removals,
   dependency/runtime/native changes, Windows, or uncertain compatibility.
   Do not work around the checks by changing version identities, deleting
   changed modules, using hard purge, or asserting compatibility from the diff.
5. Set `reviewed: true` only after that review. Run `mix lmx.upgrade.check
   --latest PREVIOUS_VERSION`, then build with `LMX_REQUIRE_UPGRADE_PLAN=1
   LMX_UPGRADE_FROM=OLD_ROOT`. Hot assembly verifies exact build/module coverage.
   Verify nonempty `releases/VERSION/relup`,
   `lib/lemieux-VERSION/ebin/lemieux.appup`, and
   `lib/lmx-VERSION/ebin/lmx.appup` in both the build tree and packaged archive.
   Check candidate/predecessor versions in both upgrade and downgrade lists,
   exact reviewed soft-purge instructions, and `release.json` predecessor
   build/module declarations. Generation errors or warnings block the build.
   Maintain the source plan; do not hand-edit generated appups or relup.
   Restart/initial archives must omit relup and declare empty `upgrade_from`
   and `hot_modules`. A missing relup does not qualify as a hot release.
6. Run the actual archive smoke with `--from OLD_ARCHIVE --to NEW_ARCHIVE` and
   `--expect-hot` when declared hot. It must preserve the TUI PID and editor,
   keep an existing session usable after upgrade and downgrade, boot the new
   permanent release, exercise restart fallback and interrupted preparation,
   force a health failure, verify downgrade and rejection of that failed build,
   and resume an old transcript using real packaged tools. Retain the report.
   Run the synthetic three-version fixture too: a second update must preserve
   the live session, retained local callbacks must force restart, and a process
   executing old code must survive a second update that falls back to restart.
   Check stale-session selection, concurrent launch registration,
   complete payload integrity, and installer retry/rollback regressions.
   A synthetic fixture alone does not qualify the candidate.
7. Run root precommit. CI repeats artifact qualification on each matching host,
   binds reports to archive and plan checksums, and includes them in the draft
   release. Human terminal and platform qualification runs on the rehearsal's
   archives before tagging, and the maintainer signs the release only after
   it (RELEASING.md). Record each platform's decision and reason, hot
   predecessor build identity, actual qualification report and final archive
   checksum in a comment on the release pull request; the release notes only
   tell users whether to restart and resume. Repackaging, or operating-system
   code signing, changes the archives' bytes: requalify, regenerate the
   reports and checksums, and sign again.

If no stable release exists, record `from: nil` and `mode: :initial` for each
platform. CI verifies that this exception is still true. Never fabricate a
predecessor or qualification result to get a release through the gate.
