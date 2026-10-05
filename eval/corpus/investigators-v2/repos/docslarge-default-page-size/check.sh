#!/bin/sh
# Grader for docslarge-default-page-size: every fixture file must be unchanged and the
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
verify README.md 941085825
verify changelog/2026-01.md 3124640449
verify changelog/2026-02.md 1979432356
verify changelog/2026-03.md 2822740807
verify changelog/2026-04.md 1714237806
verify changelog/2026-05.md 1443177831
verify changelog/2026-06.md 3563116328
verify changelog/2026-07.md 731871580
verify changelog/2026-08.md 2389912499
verify config/api.conf 3846994512
verify config/limits.conf 3364622522
verify config/limits.conf.dist 213965383
verify docs/accounts.md 3844490822
verify docs/adr/001-linden.md 3048032154
verify docs/adr/002-balsa.md 17639238
verify docs/adr/003-mica.md 1386531067
verify docs/adr/004-fennel.md 3162452093
verify docs/adr/005-arbor.md 1782417214
verify docs/adr/006-glacier.md 1251910262
verify docs/adr/007-aurora.md 3758955630
verify docs/adr/008-juniper.md 3944209152
verify docs/authentication.md 2695902661
verify docs/changelog-policy.md 4264084177
verify docs/cli.md 163858931
verify docs/errors.md 4171783041
verify docs/exports.md 2716210378
verify docs/glossary.md 2254940265
verify docs/guides/backups.md 952860007
verify docs/guides/deploying.md 1691853287
verify docs/guides/faq.md 3953369203
verify docs/guides/observability.md 3448283080
verify docs/guides/quickstart.md 2074578033
verify docs/guides/security.md 2942925554
verify docs/guides/troubleshooting.md 938082740
verify docs/guides/upgrading.md 4237833241
verify docs/health.md 3134715628
verify docs/orders.md 3540700513
verify docs/overview.md 175119711
verify docs/pagination.md 3513483095
verify docs/rate-limits.md 1081118393
verify docs/reference/config-keys.md 1954667713
verify docs/reference/endpoints.md 293104866
verify docs/sessions.md 1159128686
verify docs/sync.md 2884656984
verify docs/versioning.md 2352140630
verify docs/webhooks.md 4154884178
verify src/__init__.py 4294967295
verify src/api/__init__.py 4294967295
verify src/api/accounts.py 1283462675
verify src/api/defaults.py 3173951678
verify src/api/health.py 221448128
verify src/api/listing.py 494970032
verify src/api/orders.py 895093426
verify src/api/sessions.py 1900311291
verify src/api/webhooks_api.py 2091811806
verify src/cli/__init__.py 4294967295
verify src/cli/compat.py 4192724028
verify src/cli/exit_codes.py 1419420943
verify src/cli/main.py 3622466589
verify src/cli/output.py 3634360030
verify src/cli/sync.py 4141472615
verify src/cli/tables/__init__.py 4294967295
verify src/cli/tables/default.py 523288388
verify src/cli/tables/lenient.py 818411284
verify src/cli/tables/strict.py 1341039095
verify src/core/__init__.py 4294967295
verify src/core/clock.py 4037724614
verify src/core/ids.py 2845891493
verify src/core/settings.py 4151778535
verify src/core/validation.py 3319741166
verify src/errors/__init__.py 4294967295
verify src/errors/classes.py 1867845649
verify src/errors/legacy_codes.py 690748263
verify src/errors/mapping.py 2254036423
verify src/errors/render.py 2996864684
verify src/http/__init__.py 4294967295
verify src/http/headers.py 1246464886
verify src/http/middleware/__init__.py 4294967295
verify src/http/middleware/auth.py 1175931202
verify src/http/middleware/compression.py 4124932972
verify src/http/middleware/ratelimit.py 3518720120
verify src/http/middleware/ratelimit_legacy.py 1081576968
verify src/http/middleware/tracing.py 3874384648
verify src/http/responses.py 4189159673
verify src/http/routing.py 2077665631
verify src/http/server.py 3071541405
verify src/storage/__init__.py 4294967295
verify src/storage/accounts.py 370466427
verify src/storage/events.py 1933874444
verify src/storage/items.py 1596230039
verify src/webhooks/__init__.py 4294967295
verify src/webhooks/dispatch.py 1959833898
verify src/webhooks/queue.py 3755425466
verify src/webhooks/retry.py 1094703118
verify src/webhooks/signers/__init__.py 4294967295
verify src/webhooks/signers/none.py 3101988083
verify src/webhooks/signers/v1.py 399586132
verify src/webhooks/signers/v2.py 4115551491
verify src/webhooks/signers_legacy.py 207230341
verify tests/test_atlas.py1 4026705381
verify tests/test_auger.py11 2401964002
verify tests/test_balsa.py10 2879036829
verify tests/test_comet.py6 506605787
verify tests/test_fathom.py4 3213667784
verify tests/test_flint.py9 1207537827
verify tests/test_moss.py7 2649295610
verify tests/test_onyx.py5 2569750631
verify tests/test_pebble.py0 2315617764
verify tests/test_russet.py8 4145760471
verify tests/test_saffron.py2 4021516510
verify tests/test_willow.py3 149771515
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\062\065'
echo "report ok"
