#!/bin/sh
# Grader for datajoin-sku-missing-from-catalog: every fixture file must be unchanged and the
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
verify README.md 459298515
verify data/archive/orders-2025-flat.ndjson 4282967071
verify data/catalog/current-00.csv 3561170434
verify data/catalog/current-01.csv 2265841417
verify data/catalog/current-02.csv 2673624265
verify data/catalog/current-03.csv 145948598
verify data/catalog/current-04.csv 2015912701
verify data/catalog/current-05.csv 1060014841
verify data/catalog/current-06.csv 2577815329
verify data/catalog/current-07.csv 4052658448
verify data/catalog/current-08.csv 234833340
verify data/catalog/current-09.csv 1736584325
verify data/catalog/pending/proposals.csv 2728262049
verify data/orders/2026-04/orders-00.ndjson 2781636473
verify data/orders/2026-04/orders-01.ndjson 360306139
verify data/orders/2026-04/orders-02.ndjson 1653428856
verify data/orders/2026-04/orders-03.ndjson 876345989
verify data/orders/2026-04/orders-04.ndjson 1201885378
verify data/orders/2026-04/orders-05.ndjson 775513774
verify data/orders/2026-04/orders-06.ndjson 3977331671
verify data/orders/2026-04/orders-07.ndjson 2017241496
verify data/orders/2026-04/orders-08.ndjson 1172024945
verify data/orders/2026-04/orders-09.ndjson 1897929359
verify data/orders/2026-04/orders-10.ndjson 2175007421
verify data/orders/2026-05/orders-00.ndjson 249522245
verify data/orders/2026-05/orders-01.ndjson 4137145268
verify data/orders/2026-05/orders-02.ndjson 2568381834
verify data/orders/2026-05/orders-03.ndjson 1879806357
verify data/orders/2026-05/orders-04.ndjson 425608287
verify data/orders/2026-05/orders-05.ndjson 3764135324
verify data/orders/2026-05/orders-06.ndjson 3538954815
verify data/orders/2026-05/orders-07.ndjson 4260365102
verify data/orders/2026-05/orders-08.ndjson 999115843
verify data/orders/2026-05/orders-09.ndjson 3645311408
verify data/orders/2026-05/orders-10.ndjson 4282395292
verify data/orders/2026-06/orders-00.ndjson 1709470273
verify data/orders/2026-06/orders-01.ndjson 2898745981
verify data/orders/2026-06/orders-02.ndjson 4220832855
verify data/orders/2026-06/orders-03.ndjson 278317400
verify data/orders/2026-06/orders-04.ndjson 776791417
verify data/orders/2026-06/orders-05.ndjson 833886414
verify data/orders/2026-06/orders-06.ndjson 3137648838
verify data/orders/2026-06/orders-07.ndjson 2651057320
verify data/orders/2026-06/orders-08.ndjson 719930072
verify data/orders/2026-06/orders-09.ndjson 2097763376
verify data/orders/2026-06/orders-10.ndjson 459342752
verify data/shipments/shipments-00.csv 3734408801
verify data/shipments/shipments-01.csv 2716447440
verify data/shipments/shipments-02.csv 3169329785
verify data/shipments/shipments-03.csv 3672212343
verify data/shipments/shipments-04.csv 1530718008
verify data/shipments/shipments-05.csv 2726923366
verify data/shipments/shipments-06.csv 402192468
verify data/shipments/shipments-07.csv 2001701523
verify data/shipments/shipments-08.csv 4112567979
verify data/shipments/shipments-09.csv 790117047
verify data/shipments/shipments-10.csv 1556538031
verify data/shipments/shipments-11.csv 4087335957
verify data/shipments/shipments-12.csv 1969779647
verify data/shipments/shipments-13.csv 4255539062
verify data/shipments/shipments-14.csv 459243909
verify data/shipments/shipments-15.csv 2038264417
verify data/shipments/shipments-16.csv 3890782596
verify data/shipments/shipments-17.csv 730119863
verify data/shipments/shipments-18.csv 302767720
verify data/shipments/shipments-19.csv 547218083
verify data/shipments/shipments-20.csv 1059138975
verify data/shipments/shipments-21.csv 176715400
verify docs/glossary.md 3295486542
verify docs/reports/catalog-audit.md 1744466364
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\163\153\165\055\070\145\060\067\070'
echo "report ok"
