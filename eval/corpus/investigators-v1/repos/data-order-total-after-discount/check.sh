#!/bin/sh
# Grader for data-order-total-after-discount: every fixture file must be unchanged and the
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
verify data/README.md 2483652735
verify data/customers.csv 2990128150
verify data/discounts.json 2589241391
verify data/orders.csv 675800269
verify data/prices.csv 1075557139
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\062\062\071\062\056\064' '\062\054\062\071\062\056\064'
echo "report ok"
