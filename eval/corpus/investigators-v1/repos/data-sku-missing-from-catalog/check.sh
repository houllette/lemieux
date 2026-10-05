#!/bin/sh
# Grader for data-sku-missing-from-catalog: every fixture file must be unchanged and the
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
verify data/README.md 140167464
verify data/catalog.json 3547495940
verify data/discontinued.json 1350057743
verify data/inventory-eu.csv 3092323510
verify data/inventory-us.csv 2215951447
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\163\153\165\055\064\064\067\061'
echo "report ok"
