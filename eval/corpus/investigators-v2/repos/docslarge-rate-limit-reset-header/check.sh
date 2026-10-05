#!/bin/sh
# Grader for docslarge-rate-limit-reset-header: every fixture file must be unchanged and the
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
verify README.md 2416624584
verify changelog/2026-01.md 1591264008
verify changelog/2026-02.md 251903630
verify changelog/2026-03.md 3097349346
verify changelog/2026-04.md 4163460137
verify changelog/2026-05.md 718715238
verify changelog/2026-06.md 1479795790
verify changelog/2026-07.md 4268066259
verify changelog/2026-08.md 2040920254
verify config/headers.conf 3594449177
verify config/headers.conf.dist 937189341
verify docs/accounts.md 3792643681
verify docs/adr/001-bison.md 165182290
verify docs/adr/002-flint.md 3306109592
verify docs/adr/003-kelp.md 2333017145
verify docs/adr/004-russet.md 1432827496
verify docs/adr/005-cinder.md 1663790419
verify docs/adr/006-walnut.md 2618844629
verify docs/adr/007-yarrow.md 3980185102
verify docs/adr/008-russet.md 88418196
verify docs/authentication.md 1273175341
verify docs/changelog-policy.md 3725138719
verify docs/cli.md 4237435182
verify docs/errors.md 2864411498
verify docs/exports.md 3428340058
verify docs/glossary.md 1286620750
verify docs/guides/backups.md 1905941273
verify docs/guides/deploying.md 2958295989
verify docs/guides/faq.md 3596092353
verify docs/guides/observability.md 889270141
verify docs/guides/quickstart.md 2855608372
verify docs/guides/security.md 3214470291
verify docs/guides/troubleshooting.md 1050877878
verify docs/guides/upgrading.md 4256181907
verify docs/health.md 2647551533
verify docs/orders.md 2281123990
verify docs/overview.md 3383134456
verify docs/pagination.md 1343001846
verify docs/rate-limits.md 2958709923
verify docs/reference/config-keys.md 895931121
verify docs/reference/endpoints.md 1730285699
verify docs/sessions.md 3503784458
verify docs/sync.md 3190461467
verify docs/versioning.md 4200340211
verify docs/webhooks.md 363368115
verify src/__init__.py 4294967295
verify src/api/__init__.py 4294967295
verify src/api/accounts.py 3425759476
verify src/api/health.py 2471217528
verify src/api/listing.py 1260237093
verify src/api/orders.py 3294689518
verify src/api/sessions.py 3338864211
verify src/api/webhooks_api.py 929298792
verify src/cli/__init__.py 4294967295
verify src/cli/compat.py 670386593
verify src/cli/exit_codes.py 3374299640
verify src/cli/main.py 2021934128
verify src/cli/output.py 612794695
verify src/cli/sync.py 3793599068
verify src/cli/tables/__init__.py 4294967295
verify src/cli/tables/default.py 570382690
verify src/cli/tables/lenient.py 3657932417
verify src/cli/tables/strict.py 2973923428
verify src/core/__init__.py 4294967295
verify src/core/clock.py 2002898522
verify src/core/ids.py 1586701277
verify src/core/settings.py 425736277
verify src/core/validation.py 111026461
verify src/errors/__init__.py 4294967295
verify src/errors/classes.py 4285975145
verify src/errors/legacy_codes.py 3058955468
verify src/errors/mapping.py 147081439
verify src/errors/render.py 2198862904
verify src/http/__init__.py 4294967295
verify src/http/headers.py 3635679538
verify src/http/middleware/__init__.py 4294967295
verify src/http/middleware/auth.py 900598377
verify src/http/middleware/compression.py 3818271436
verify src/http/middleware/ratelimit.py 2224641679
verify src/http/middleware/ratelimit_legacy.py 2605044826
verify src/http/middleware/tracing.py 1162461694
verify src/http/responses.py 3400200427
verify src/http/routing.py 174069573
verify src/http/server.py 2758107066
verify src/storage/__init__.py 4294967295
verify src/storage/accounts.py 246396110
verify src/storage/events.py 3937850615
verify src/storage/items.py 2948857717
verify src/webhooks/__init__.py 4294967295
verify src/webhooks/dispatch.py 2303482145
verify src/webhooks/queue.py 420696598
verify src/webhooks/retry.py 3533042579
verify src/webhooks/signers/__init__.py 4294967295
verify src/webhooks/signers/none.py 306048674
verify src/webhooks/signers/v1.py 2822540250
verify src/webhooks/signers/v2.py 2706678138
verify src/webhooks/signers_legacy.py 3010419540
verify tests/test_cypress.py10 3589650292
verify tests/test_harbor.py3 73689342
verify tests/test_harbor.py4 3589566942
verify tests/test_hazel.py2 3617472762
verify tests/test_hazel.py9 3212189976
verify tests/test_larch.py6 3011657040
verify tests/test_lumen.py0 3966027328
verify tests/test_plover.py7 3785062595
verify tests/test_quartz.py11 3818539720
verify tests/test_quill.py1 2171766511
verify tests/test_spruce.py8 1917442114
verify tests/test_vale.py5 1033206523
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\170\055\161\165\157\164\141\055\162\145\163\145\164'
expect 2 '\155\151\154\154\151\163\145\143\157\156\144' '\040\155\163'
echo "report ok"
