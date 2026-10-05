#!/bin/sh
# Grader for docslarge-webhook-signature-algo: every fixture file must be unchanged and the
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
verify README.md 4262958395
verify changelog/2026-01.md 196527102
verify changelog/2026-02.md 1372807305
verify changelog/2026-03.md 2130606229
verify changelog/2026-04.md 818492155
verify changelog/2026-05.md 3116506495
verify changelog/2026-06.md 727925264
verify changelog/2026-07.md 523740553
verify changelog/2026-08.md 2061793168
verify config/settings.conf 4064555410
verify config/settings.conf.example 917961164
verify docs/accounts.md 1442337681
verify docs/adr/001-basalt.md 1894066783
verify docs/adr/002-osprey.md 3772836538
verify docs/adr/003-moss.md 2308793363
verify docs/adr/004-topaz.md 3409360574
verify docs/adr/005-zephyr.md 2711222112
verify docs/adr/006-yarrow.md 3125920884
verify docs/adr/007-quartz.md 2938275279
verify docs/adr/008-zephyr.md 1819764831
verify docs/authentication.md 2950928234
verify docs/changelog-policy.md 81334077
verify docs/cli.md 2291592068
verify docs/errors.md 3596119598
verify docs/exports.md 1834800729
verify docs/glossary.md 606564541
verify docs/guides/backups.md 1627416090
verify docs/guides/deploying.md 854734884
verify docs/guides/faq.md 3563656702
verify docs/guides/observability.md 1359951603
verify docs/guides/quickstart.md 3802400574
verify docs/guides/security.md 2588639987
verify docs/guides/troubleshooting.md 2006486958
verify docs/guides/upgrading.md 2323924929
verify docs/health.md 2702006960
verify docs/orders.md 4251009310
verify docs/overview.md 2620943815
verify docs/pagination.md 3191677341
verify docs/rate-limits.md 1265230699
verify docs/reference/config-keys.md 4165118165
verify docs/reference/endpoints.md 3003626123
verify docs/sessions.md 561645131
verify docs/sync.md 986331695
verify docs/versioning.md 2328998913
verify docs/webhooks.md 518081874
verify src/__init__.py 4294967295
verify src/api/__init__.py 4294967295
verify src/api/accounts.py 1109236409
verify src/api/health.py 3675210990
verify src/api/listing.py 3016284622
verify src/api/orders.py 170160977
verify src/api/sessions.py 1610540660
verify src/api/webhooks_api.py 3241050071
verify src/cli/__init__.py 4294967295
verify src/cli/compat.py 3761982666
verify src/cli/exit_codes.py 1195929325
verify src/cli/main.py 2725345093
verify src/cli/output.py 1299057595
verify src/cli/sync.py 2230556681
verify src/cli/tables/__init__.py 4294967295
verify src/cli/tables/default.py 2741933271
verify src/cli/tables/lenient.py 1210909644
verify src/cli/tables/strict.py 516467966
verify src/core/__init__.py 4294967295
verify src/core/clock.py 1460110586
verify src/core/ids.py 325460364
verify src/core/settings.py 1649158504
verify src/core/validation.py 946271733
verify src/errors/__init__.py 4294967295
verify src/errors/classes.py 3383843233
verify src/errors/legacy_codes.py 1007999450
verify src/errors/mapping.py 1575082045
verify src/errors/render.py 1525824412
verify src/http/__init__.py 4294967295
verify src/http/headers.py 2694606856
verify src/http/middleware/__init__.py 4294967295
verify src/http/middleware/auth.py 1930363854
verify src/http/middleware/compression.py 1042631796
verify src/http/middleware/ratelimit.py 203732080
verify src/http/middleware/ratelimit_legacy.py 431642247
verify src/http/middleware/tracing.py 2468302877
verify src/http/responses.py 926414444
verify src/http/routing.py 1061809102
verify src/http/server.py 319821578
verify src/storage/__init__.py 4294967295
verify src/storage/accounts.py 3976436010
verify src/storage/events.py 1852296103
verify src/storage/items.py 3103167249
verify src/webhooks/__init__.py 4294967295
verify src/webhooks/dispatch.py 4040767722
verify src/webhooks/queue.py 2327464279
verify src/webhooks/retry.py 4182916539
verify src/webhooks/signers/__init__.py 3838793415
verify src/webhooks/signers/none.py 1026339801
verify src/webhooks/signers/v1.py 2064910110
verify src/webhooks/signers/v2.py 2849515705
verify src/webhooks/signers_legacy.py 150225925
verify tests/test_alder.py6 806798139
verify tests/test_canvas.py5 3377231688
verify tests/test_comet.py10 2295865718
verify tests/test_comet.py4 3340804
verify tests/test_comet.py7 138518711
verify tests/test_ferric.py0 3482349400
verify tests/test_harbor.py1 1413219954
verify tests/test_iris.py3 2487406798
verify tests/test_lichen.py8 3535018860
verify tests/test_pine.py11 2446413244
verify tests/test_rowan.py2 262128787
verify tests/test_rowan.py9 3353929016
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\163\150\141\065\061\062'
echo "report ok"
