#!/bin/sh
# Grader for datajoin-order-total-after-discount: every fixture file must be unchanged and the
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
verify README.md 3796974860
verify data/archive/orders-2025-flat.ndjson 1253391624
verify data/catalog/prices-00.csv 2897412125
verify data/catalog/prices-01.csv 3779338373
verify data/catalog/prices-02.csv 2409308858
verify data/catalog/prices-03.csv 2414432177
verify data/customers/customers-00.csv 843423469
verify data/customers/customers-01.csv 3096574879
verify data/customers/customers-02.csv 3156910442
verify data/customers/customers-03.csv 501725935
verify data/customers/customers-04.csv 770030121
verify data/customers/customers-05.csv 2725431022
verify data/customers/customers-06.csv 522821248
verify data/customers/customers-07.csv 414435352
verify data/orders/2026-01/orders-00.ndjson 1749995910
verify data/orders/2026-01/orders-01.ndjson 2811461104
verify data/orders/2026-01/orders-02.ndjson 2162254839
verify data/orders/2026-01/orders-03.ndjson 1708540556
verify data/orders/2026-02/orders-00.ndjson 906320299
verify data/orders/2026-02/orders-01.ndjson 230448529
verify data/orders/2026-02/orders-02.ndjson 2674368462
verify data/orders/2026-03/orders-00.ndjson 270331379
verify data/orders/2026-03/orders-01.ndjson 4160881918
verify data/orders/2026-03/orders-02.ndjson 1747556136
verify data/orders/2026-04/orders-00.ndjson 750501077
verify data/orders/2026-04/orders-01.ndjson 2060690668
verify data/orders/2026-04/orders-02.ndjson 3476359801
verify data/orders/2026-05/orders-00.ndjson 2916244418
verify data/orders/2026-05/orders-01.ndjson 3049305438
verify data/orders/2026-05/orders-02.ndjson 1438908657
verify data/orders/2026-06/orders-00.ndjson 2594893858
verify data/orders/2026-06/orders-01.ndjson 3217998685
verify data/orders/2026-06/orders-02.ndjson 1359566779
verify data/orders/2026-06/orders-03.ndjson 3214918221
verify data/orders/2026-07/orders-00.ndjson 3926377642
verify data/orders/2026-07/orders-01.ndjson 1254438388
verify data/orders/2026-07/orders-02.ndjson 2774485859
verify data/orders/2026-08/orders-00.ndjson 3661433016
verify data/orders/2026-08/orders-01.ndjson 2999928974
verify data/orders/2026-08/orders-02.ndjson 1294041793
verify data/refunds/refunds-00.csv 1116302838
verify data/refunds/refunds-01.csv 885001613
verify data/refunds/refunds-02.csv 2208758308
verify data/refunds/refunds-03.csv 3140576329
verify data/refunds/refunds-04.csv 3522647871
verify data/tiers/history-00.csv 2759489798
verify data/tiers/history-01.csv 3006383544
verify data/tiers/history-02.csv 1921525189
verify data/tiers/history-03.csv 1618543859
verify data/tiers/history-04.csv 1338141113
verify data/tiers/history-05.csv 487546385
verify data/tiers/history-06.csv 2820997462
verify data/tiers/history-07.csv 630053353
verify data/tiers/history-08.csv 412173605
verify data/tiers/history-09.csv 2040026852
verify data/tiers/history-10.csv 3335123763
verify data/tiers/history-11.csv 1952367133
verify data/tiers/history-12.csv 4230054262
verify data/tiers/history-13.csv 1876187803
verify data/tiers/history-14.csv 1818338168
verify data/tiers/history-15.csv 1683001587
verify data/tiers/history-16.csv 2195513047
verify data/tiers/history-17.csv 657611527
verify data/tiers/tiers.csv 1559793272
verify docs/glossary.md 2883856539
verify docs/reports/billing-faq.md 4075574339
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\061\061\070\056\063\060'
echo "report ok"
