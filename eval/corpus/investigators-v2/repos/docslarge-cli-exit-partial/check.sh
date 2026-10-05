#!/bin/sh
# Grader for docslarge-cli-exit-partial: every fixture file must be unchanged and the
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
verify README.md 1423032614
verify changelog/2026-01.md 1475177843
verify changelog/2026-02.md 3772389210
verify changelog/2026-03.md 3743191213
verify changelog/2026-04.md 2168382281
verify changelog/2026-05.md 1947742008
verify changelog/2026-06.md 3325699236
verify changelog/2026-07.md 163375330
verify changelog/2026-08.md 2144213476
verify config/cli.conf 3112688022
verify config/cli.conf.example 1988615259
verify docs/accounts.md 3869619477
verify docs/adr/001-arbor.md 62630407
verify docs/adr/002-timber.md 11998422
verify docs/adr/003-cedar.md 1213029629
verify docs/adr/004-marrow.md 643037482
verify docs/adr/005-raven.md 2038758646
verify docs/adr/006-granite.md 1342213138
verify docs/adr/007-kelp.md 2397853917
verify docs/adr/008-osprey.md 2535680192
verify docs/authentication.md 553219326
verify docs/changelog-policy.md 2549999853
verify docs/cli.md 2441667155
verify docs/errors.md 2829724575
verify docs/exports.md 3834916523
verify docs/glossary.md 2228830798
verify docs/guides/backups.md 3140572147
verify docs/guides/deploying.md 1457990340
verify docs/guides/faq.md 284270700
verify docs/guides/observability.md 3505184269
verify docs/guides/quickstart.md 1213132350
verify docs/guides/security.md 1328499646
verify docs/guides/troubleshooting.md 3510842124
verify docs/guides/upgrading.md 375402088
verify docs/health.md 2721257183
verify docs/orders.md 1078990332
verify docs/overview.md 2713031419
verify docs/pagination.md 1926325163
verify docs/rate-limits.md 106954015
verify docs/reference/config-keys.md 529623944
verify docs/reference/endpoints.md 3660678540
verify docs/sessions.md 3669069346
verify docs/sync.md 2316365456
verify docs/versioning.md 1228784318
verify docs/webhooks.md 1826975270
verify src/__init__.py 4294967295
verify src/api/__init__.py 4294967295
verify src/api/accounts.py 3983613000
verify src/api/health.py 4088569444
verify src/api/listing.py 2293901934
verify src/api/orders.py 2820604383
verify src/api/sessions.py 2878001340
verify src/api/webhooks_api.py 4192762859
verify src/cli/__init__.py 4294967295
verify src/cli/compat.py 1251443915
verify src/cli/exit_codes.py 2361074399
verify src/cli/main.py 1714763458
verify src/cli/output.py 2982766116
verify src/cli/sync.py 235978789
verify src/cli/tables/__init__.py 4294967295
verify src/cli/tables/default.py 462617113
verify src/cli/tables/lenient.py 875862179
verify src/cli/tables/strict.py 166349151
verify src/core/__init__.py 4294967295
verify src/core/clock.py 2924119507
verify src/core/ids.py 3385014464
verify src/core/settings.py 3419779834
verify src/core/validation.py 23928922
verify src/errors/__init__.py 4294967295
verify src/errors/classes.py 2354838436
verify src/errors/legacy_codes.py 3163677416
verify src/errors/mapping.py 2684324336
verify src/errors/render.py 3302153612
verify src/http/__init__.py 4294967295
verify src/http/headers.py 416305488
verify src/http/middleware/__init__.py 4294967295
verify src/http/middleware/auth.py 1811346609
verify src/http/middleware/compression.py 3515002516
verify src/http/middleware/ratelimit.py 4201754816
verify src/http/middleware/ratelimit_legacy.py 3783491273
verify src/http/middleware/tracing.py 1881732820
verify src/http/responses.py 1593564209
verify src/http/routing.py 997086287
verify src/http/server.py 2289378951
verify src/storage/__init__.py 4294967295
verify src/storage/accounts.py 2999738901
verify src/storage/events.py 2811208915
verify src/storage/items.py 4095267062
verify src/webhooks/__init__.py 4294967295
verify src/webhooks/dispatch.py 1095591577
verify src/webhooks/queue.py 2377065952
verify src/webhooks/retry.py 3198512579
verify src/webhooks/signers/__init__.py 4294967295
verify src/webhooks/signers/none.py 1076840089
verify src/webhooks/signers/v1.py 4258097386
verify src/webhooks/signers/v2.py 3959284867
verify src/webhooks/signers_legacy.py 2463283777
verify tests/test_bramble.py4 1853138717
verify tests/test_cobalt.py6 3853578049
verify tests/test_glacier.py2 363240109
verify tests/test_heron.py1 3058766183
verify tests/test_hollow.py9 3995736350
verify tests/test_kestrel.py3 569626631
verify tests/test_onyx.py0 4017937805
verify tests/test_osprey.py5 3072391593
verify tests/test_pine.py7 184330120
verify tests/test_rowan.py11 1639407843
verify tests/test_timber.py10 2699942740
verify tests/test_verdant.py8 2221334639
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\064'
echo "report ok"
