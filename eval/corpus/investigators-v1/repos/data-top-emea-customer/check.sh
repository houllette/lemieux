#!/bin/sh
# Grader for data-top-emea-customer: every fixture file must be unchanged and the
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
verify data/README.md 201392051
verify data/customers.csv 1934932867
verify data/orders.csv 2521824613
verify data/refunds.csv 285888360
verify data/regions.json 2820026499
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\150\141\154\166\157\162\163\145\156'
echo "report ok"
