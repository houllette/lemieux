#!/bin/sh
# Grader for datajoin-top-emea-customer: every fixture file must be unchanged and the
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
verify README.md 1906510609
verify data/archive/orders-2025-flat.ndjson 231386278
verify data/customers/customers-00.csv 785938361
verify data/customers/customers-01.csv 1602397484
verify data/customers/customers-02.csv 603625170
verify data/customers/customers-03.csv 3795516333
verify data/customers/customers-04.csv 1942169791
verify data/customers/customers-05.csv 759505741
verify data/customers/customers-06.csv 2536951321
verify data/customers/customers-07.csv 2024177601
verify data/customers/customers-08.csv 2016763899
verify data/customers/customers-09.csv 2425309996
verify data/customers/customers-10.csv 2670152744
verify data/customers/customers-11.csv 4206024039
verify data/orders/2026-03/orders-00.ndjson 1257936526
verify data/orders/2026-03/orders-01.ndjson 792492247
verify data/orders/2026-03/orders-02.ndjson 3675917387
verify data/orders/2026-03/orders-03.ndjson 2493221204
verify data/orders/2026-03/orders-04.ndjson 231531906
verify data/orders/2026-03/orders-05.ndjson 1842562664
verify data/orders/2026-03/orders-06.ndjson 827906329
verify data/orders/2026-03/orders-07.ndjson 3712726149
verify data/orders/2026-03/orders-08.ndjson 3929391432
verify data/orders/2026-04/orders-00.ndjson 1299239399
verify data/orders/2026-04/orders-01.ndjson 1719616091
verify data/orders/2026-04/orders-02.ndjson 3764954543
verify data/orders/2026-04/orders-03.ndjson 387720804
verify data/orders/2026-04/orders-04.ndjson 1506064752
verify data/orders/2026-04/orders-05.ndjson 529333532
verify data/orders/2026-04/orders-06.ndjson 3811414916
verify data/orders/2026-04/orders-07.ndjson 1002667713
verify data/orders/2026-04/orders-08.ndjson 786316899
verify data/orders/2026-05/orders-00.ndjson 2753927942
verify data/orders/2026-05/orders-01.ndjson 774825265
verify data/orders/2026-05/orders-02.ndjson 279404530
verify data/orders/2026-05/orders-03.ndjson 1140895926
verify data/orders/2026-05/orders-04.ndjson 2177924799
verify data/orders/2026-05/orders-05.ndjson 1999007315
verify data/orders/2026-05/orders-06.ndjson 384946867
verify data/orders/2026-05/orders-07.ndjson 811259424
verify data/orders/2026-05/orders-08.ndjson 2054415970
verify data/orders/2026-06/orders-00.ndjson 2012498251
verify data/orders/2026-06/orders-01.ndjson 3919466973
verify data/orders/2026-06/orders-02.ndjson 2264965767
verify data/orders/2026-06/orders-03.ndjson 3774554761
verify data/orders/2026-06/orders-04.ndjson 3067461636
verify data/orders/2026-06/orders-05.ndjson 913170663
verify data/orders/2026-06/orders-06.ndjson 4152319503
verify data/orders/2026-06/orders-07.ndjson 3562261785
verify data/orders/2026-06/orders-08.ndjson 775912633
verify data/orders/2026-07/orders-00.ndjson 444897493
verify data/orders/2026-07/orders-01.ndjson 25253808
verify data/orders/2026-07/orders-02.ndjson 2169559615
verify data/orders/2026-07/orders-03.ndjson 281282889
verify data/orders/2026-07/orders-04.ndjson 2261923627
verify data/orders/2026-07/orders-05.ndjson 244468343
verify data/orders/2026-07/orders-06.ndjson 2634976440
verify data/orders/2026-07/orders-07.ndjson 414784317
verify data/orders/2026-07/orders-08.ndjson 1565899381
verify data/rates/rates-2025.json 3118540935
verify data/rates/rates.json 4277489551
verify data/refunds/refunds-00.csv 479879917
verify data/refunds/refunds-01.csv 3112540278
verify data/refunds/refunds-02.csv 2015254769
verify data/refunds/refunds-03.csv 2535485066
verify data/regions/regions.json 2149708963
verify docs/glossary.md 578442761
verify docs/reports/q2-draft.md 2468016470
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\161\165\151\154\154\155\145\162\145\040\146\162\145\151\147\150\164'
echo "report ok"
