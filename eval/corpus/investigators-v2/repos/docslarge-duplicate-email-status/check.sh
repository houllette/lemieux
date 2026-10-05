#!/bin/sh
# Grader for docslarge-duplicate-email-status: every fixture file must be unchanged and the
# reported answer (argv 1) must contain each expected fact.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
expect() {
  label=$1; shift
  for enc in "$@"; do
    tok=$(printf "$enc")
    case "$answer" in *"$tok"*) return 0 ;; esac
  done
  fail "answer is missing expected fact $label"
}
verify README.md 3508683879
verify changelog/2026-01.md 3949547183
verify changelog/2026-02.md 2196061820
verify changelog/2026-03.md 1198702718
verify changelog/2026-04.md 2298382418
verify changelog/2026-05.md 3170278142
verify changelog/2026-06.md 441372517
verify changelog/2026-07.md 554028466
verify changelog/2026-08.md 2651468330
verify config/error-codes.tsv 2193068978
verify docs/accounts.md 2485528838
verify docs/adr/001-fennel.md 2169624986
verify docs/adr/002-plover.md 2733117801
verify docs/adr/003-shale.md 1280099141
verify docs/adr/004-saffron.md 2465870824
verify docs/adr/005-comet.md 2862103974
verify docs/adr/006-spruce.md 3477859377
verify docs/adr/007-amber.md 187571188
verify docs/adr/008-spruce.md 2655926152
verify docs/authentication.md 3601321996
verify docs/changelog-policy.md 4065496143
verify docs/cli.md 3925075433
verify docs/errors.md 2748333574
verify docs/exports.md 3942297174
verify docs/glossary.md 2830894950
verify docs/guides/backups.md 1786817463
verify docs/guides/deploying.md 4018972551
verify docs/guides/faq.md 29726249
verify docs/guides/observability.md 3581897351
verify docs/guides/quickstart.md 1480894190
verify docs/guides/security.md 2162248154
verify docs/guides/troubleshooting.md 1464093191
verify docs/guides/upgrading.md 715044679
verify docs/health.md 4195657895
verify docs/orders.md 891535259
verify docs/overview.md 815665729
verify docs/pagination.md 3701057430
verify docs/rate-limits.md 340226723
verify docs/reference/config-keys.md 880802861
verify docs/reference/endpoints.md 1720141971
verify docs/sessions.md 2507900092
verify docs/sync.md 2112952512
verify docs/versioning.md 3161139851
verify docs/webhooks.md 944924247
verify src/__init__.py 4294967295
verify src/api/__init__.py 4294967295
verify src/api/accounts.py 3403250273
verify src/api/health.py 3482845445
verify src/api/listing.py 2007770703
verify src/api/orders.py 3598693035
verify src/api/sessions.py 2095651804
verify src/api/webhooks_api.py 1762322527
verify src/cli/__init__.py 4294967295
verify src/cli/compat.py 3515144878
verify src/cli/exit_codes.py 3327377364
verify src/cli/main.py 2290619896
verify src/cli/output.py 191340587
verify src/cli/sync.py 4235982651
verify src/cli/tables/__init__.py 4294967295
verify src/cli/tables/default.py 1440503691
verify src/cli/tables/lenient.py 1688612691
verify src/cli/tables/strict.py 2347425564
verify src/core/__init__.py 4294967295
verify src/core/clock.py 3251453179
verify src/core/ids.py 600085954
verify src/core/settings.py 4160614666
verify src/core/validation.py 4096383438
verify src/errors/__init__.py 4294967295
verify src/errors/classes.py 2774339322
verify src/errors/legacy_codes.py 2649302732
verify src/errors/mapping.py 2528268502
verify src/errors/render.py 1317199514
verify src/http/__init__.py 4294967295
verify src/http/headers.py 1296094428
verify src/http/middleware/__init__.py 4294967295
verify src/http/middleware/auth.py 727707122
verify src/http/middleware/compression.py 2313818429
verify src/http/middleware/ratelimit.py 4049433036
verify src/http/middleware/ratelimit_legacy.py 4019415951
verify src/http/middleware/tracing.py 3492188596
verify src/http/responses.py 3449592381
verify src/http/routing.py 2247993992
verify src/http/server.py 1377860586
verify src/storage/__init__.py 4294967295
verify src/storage/accounts.py 473298966
verify src/storage/events.py 810607453
verify src/storage/items.py 1731423071
verify src/webhooks/__init__.py 4294967295
verify src/webhooks/dispatch.py 1761434194
verify src/webhooks/queue.py 3211175255
verify src/webhooks/retry.py 1123001109
verify src/webhooks/signers/__init__.py 4294967295
verify src/webhooks/signers/none.py 900348788
verify src/webhooks/signers/v1.py 2997663833
verify src/webhooks/signers/v2.py 3231825586
verify src/webhooks/signers_legacy.py 207181548
verify tests/test_atlas.py7 1812104825
verify tests/test_birch.py1 1579760453
verify tests/test_brine.py2 786975514
verify tests/test_brine.py4 1923735890
verify tests/test_fennel.py6 3015225069
verify tests/test_ferric.py3 1328786740
verify tests/test_flint.py5 2958233811
verify tests/test_lantern.py8 868639167
verify tests/test_pebble.py0 3713815013
verify tests/test_pine.py11 2794933458
verify tests/test_tallow.py10 86997943
verify tests/test_vellum.py9 88923854
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\064\062\062'
echo "report ok"
